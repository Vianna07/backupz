const std = @import("std");
const Check = @import("Check.zig");
const Config = @import("Config.zig");
const Compose = @import("Compose.zig");

const Allocator = std.mem.Allocator;

pub const RunError = error{
    CheckFailed,
    DockerNotFound,
    CommandFailed,
};

pub fn execute(
    alloc: Allocator,
    io: std.Io,
    cfg: Config.Config,
    compose: Compose.Compose,
    compose_file: []const u8,
    writer: anytype,
) !void {
    const result = try Check.check(alloc, cfg, compose, io);

    if (!result.ok) {
        try Check.printResult(result, writer);
        return RunError.CheckFailed;
    }

    try Check.printResult(result, writer);

    if (!try dockerAvailable(alloc, io)) {
        try writer.print("error: docker is not installed or not in PATH\n", .{});
        return RunError.DockerNotFound;
    }

    try writer.print("--- RUNNING ---\n\n", .{});

    for (result.plans) |plan| {
        try writer.print("[clean] {s} ({s})\n", .{ plan.name, plan.container_name });
        _ = std.process.run(alloc, io, .{
            .argv = &.{ "docker", "rm", "-f", plan.container_name },
            .stderr_limit = .limited(4096),
            .stdout_limit = .limited(4096),
        }) catch {};
    }

    const override_path = try generateOverride(alloc, io, result.plans);

    try writer.print("[start] bringing up services\n", .{});
    try runCommand(alloc, io, &.{ "docker", "compose", "-f", compose_file, "-f", override_path, "up", "-d" }, writer);

    errdefer {
        for (result.plans) |plan| {
            writer.print("[cleanup] stopping {s} ({s})\n", .{ plan.name, plan.container_name }) catch {};
            runCommand(alloc, io, &.{ "docker", "compose", "-f", compose_file, "stop", plan.name }, writer) catch {};
        }
    }

    for (result.plans) |plan| {
        const script = plan.script orelse continue;
        try writer.print("[wait] {s} ({s})\n", .{ plan.name, plan.container_name });
        try waitForPostgres(alloc, io, compose_file, plan.name);
        try writer.print("[exec] running {s} on {s}\n", .{ script, plan.name });
        try runCommand(alloc, io, &.{
            "docker", "compose", "-f",                                                                                                       compose_file, "exec", "-T", plan.name,
            "sh",     "-c",      try std.fmt.allocPrint(alloc, "psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -f /scripts/{s}", .{script}),
        }, writer);
    }

    for (result.plans) |plan| {
        if (!plan.conflict) continue;

        try writer.print("[stop] {s} ({s})\n", .{ plan.name, plan.container_name });
        try runCommand(alloc, io, &.{ "docker", "compose", "-f", compose_file, "stop", plan.name }, writer);
    }

    try writer.print("\ndone.\n", .{});
}

fn dockerAvailable(alloc: Allocator, io: std.Io) !bool {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "docker", "info" },
        .stderr_limit = .limited(4096),
        .stdout_limit = .limited(4096),
    }) catch return false;

    alloc.free(result.stdout);
    alloc.free(result.stderr);

    return result.term == .exited and result.term.exited == 0;
}

fn runCommand(alloc: Allocator, io: std.Io, argv: []const []const u8, writer: anytype) !void {
    const result = std.process.run(alloc, io, .{
        .argv = argv,
        .stderr_limit = .limited(64 * 1024),
        .stdout_limit = .limited(64 * 1024),
    }) catch |err| {
        return err;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        if (result.stderr.len > 0) {
            try writer.print("  stderr: {s}\n", .{result.stderr});
        }
        return RunError.CommandFailed;
    }
}

fn waitForPostgres(alloc: Allocator, io: std.Io, compose_file: []const u8, service: []const u8) !void {
    const result = std.process.run(alloc, io, .{
        .argv = &.{
            "docker", "compose", "-f",                                                                                         compose_file, "exec", "-T", service,
            "sh",     "-c",      "for i in $(seq 1 30); do pg_isready -U \"$POSTGRES_USER\" && exit 0; sleep 1; done; exit 1",
        },
        .stderr_limit = .limited(4096),
        .stdout_limit = .limited(4096),
    }) catch return RunError.CommandFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return RunError.CommandFailed;
    }
}

fn generateOverride(alloc: Allocator, io: std.Io, plans: []const Check.ServicePlan) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    try buf.print(alloc, "services:\n", .{});

    for (plans) |plan| {
        if (!plan.conflict) continue;

        try buf.print(alloc, "  {s}:\n", .{plan.name});
        try buf.print(alloc, "    ports: !override\n", .{});
        try buf.print(alloc, "      - \"{d}:{d}\"\n", .{ plan.resolved_port, plan.container_port });
        if (plan.script != null) {
            try buf.print(alloc, "    volumes:\n", .{});
            try buf.print(alloc, "      - ./scripts:/scripts\n", .{});
        }
    }

    const override_content = try buf.toOwnedSlice(alloc);
    const override_path = "/tmp/backupz-override.yml";

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, override_path, .{});
    try file.writeStreamingAll(io, override_content);
    file.close(io);

    return override_path;
}
