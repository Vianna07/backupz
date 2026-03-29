const std = @import("std");
const Compose = @import("Compose.zig");
const Config = @import("Config.zig");
const Check = @import("Check.zig");
const Run = @import("Run.zig");

const Yaml = @import("yaml").Yaml;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .tokenizer, .level = .warn },
        .{ .scope = .parser, .level = .warn },
        .{ .scope = .yaml, .level = .warn },
    },
};

const default_config_file = "backupz.zon";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const stdout_file = std.Io.File.stdout();
    var buf: [8192]u8 = undefined;
    var writer_instance = stdout_file.writer(init.io, &buf);
    const stdout = &writer_instance.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var compose_override: ?[]const u8 = null;
    var command: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d")) {
            compose_override = args.next();
        } else if (command == null) {
            command = arg;
        }
    }

    const cmd = command orelse {
        try printUsage(stdout);
        try stdout.flush();
        return;
    };

    if (std.mem.eql(u8, cmd, "check")) {
        try runCheck(arena, init.io, stdout, compose_override);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try runExecute(arena, init.io, stdout, compose_override);
    } else if (std.mem.eql(u8, cmd, "help")) {
        try printUsage(stdout);
    } else {
        try stdout.print("unknown command: {s}\n", .{cmd});
        try printUsage(stdout);
    }

    try stdout.flush();
}

fn printUsage(stdout: anytype) !void {
    try stdout.print(
        \\
        \\backupz - PostgreSQL backup manager via Docker Compose
        \\
        \\usage: backupz [options] <command>
        \\
        \\commands:
        \\  check   validate backupz.zon and show execution plan
        \\  run     execute the backup (check + docker compose)
        \\  help    show this message
        \\
        \\options:
        \\  -d <file>   override compose file path
        \\
        \\config example (backupz.zon):
        \\
        \\  .{{
        \\      .compose_file = "examples/compose.yml",
        \\      .port_range_start = 6100,
        \\      .port_range_end = 6200,
        \\      .databases = .{{
        \\          .{{ .service = "db-hom", .script = "backup.sql" }},
        \\      }},
        \\      // optional: skip script on specific secondaries
        \\      // .skip_scripts = .{{ "db-analytics" }},
        \\  }}
        \\
        \\
    , .{});
}

fn loadConfigAndCompose(
    alloc: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    compose_override: ?[]const u8,
) !?struct { cfg: Config.Config, compose: Compose.Compose, compose_file: []const u8 } {
    const zon_source = std.Io.Dir.cwd().readFileAlloc(io, default_config_file, alloc, .limited(64 * 1024)) catch {
        try stdout.print("error: could not read '{s}'\n", .{default_config_file});
        try printUsage(stdout);
        return null;
    };

    const cfg = Config.Config.load(alloc, zon_source) catch |err| {
        try stdout.print("error: failed to parse '{s}': {}\n", .{ default_config_file, err });
        return null;
    };

    const compose_file = compose_override orelse cfg.compose_file;

    try stdout.print("config: {s}\n", .{default_config_file});
    try stdout.print("  compose_file:     {s}\n", .{compose_file});
    try stdout.print("  databases:        {d}\n", .{cfg.databases.len});
    try stdout.print("  port_range:       {d}-{d} ({d} ports)\n", .{ cfg.port_range_start, cfg.port_range_end, cfg.portRangeSize() });

    const compose_source = std.Io.Dir.cwd().readFileAlloc(io, compose_file, alloc, .limited(1024 * 1024)) catch {
        try stdout.print("\nerror: could not read '{s}'\n", .{compose_file});
        return null;
    };

    const compose = Compose.Compose.parse(alloc, compose_source) catch |err| {
        try stdout.print("\nerror: failed to parse compose '{s}': {}\n", .{ compose_file, err });
        return null;
    };

    return .{ .cfg = cfg, .compose = compose, .compose_file = compose_file };
}

fn runCheck(alloc: std.mem.Allocator, io: std.Io, stdout: anytype, compose_override: ?[]const u8) !void {
    const loaded = try loadConfigAndCompose(alloc, io, stdout, compose_override) orelse return;

    const result = try Check.check(alloc, loaded.cfg, loaded.compose);
    try Check.printResult(result, stdout);
}

fn runExecute(alloc: std.mem.Allocator, io: std.Io, stdout: anytype, compose_override: ?[]const u8) !void {
    const loaded = try loadConfigAndCompose(alloc, io, stdout, compose_override) orelse return;

    Run.execute(alloc, io, loaded.cfg, loaded.compose, loaded.compose_file, stdout) catch |err| switch (err) {
        error.CheckFailed => return,
        error.DockerNotFound => return,
        error.CommandFailed => {
            try stdout.print("error: a docker command failed\n", .{});
            return;
        },
        else => return err,
    };
}

test "yaml parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\ name: Vianna
        \\ is_student: true
    ;
    var yaml: Yaml = .{ .source = source };
    defer yaml.deinit(alloc);
    try yaml.load(alloc);

    const Sample = struct { name: []const u8, is_student: bool };
    const sample = try yaml.parse(alloc, Sample);
    try std.testing.expectEqualStrings("Vianna", sample.name);
    try std.testing.expectEqual(sample.is_student, true);
}

comptime {
    _ = Compose;
    _ = Config;
    _ = Check;
    _ = Run;
}
