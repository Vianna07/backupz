const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addBackupzExecutable(
        b,
        target,
        optimize,
    );
    b.installArtifact(exe);

    addRunStep(b, exe);
    addTestStep(b, exe);
    addCheckStep(b, exe);
}

fn addBackupzExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const zig_yaml = b.dependency("zig_yaml", .{
        .target = target,
        .optimize = optimize,
    });

    return b.addExecutable(.{
        .name = "backupz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaml", .module = zig_yaml.module("yaml") },
            },
        }),
    });
}

fn addRunStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

fn addTestStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const exe_tests = b.addTest(.{
        .name = b.fmt("{s}_tests", .{exe.name}),
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn addCheckStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const exe_check = b.addExecutable(.{
        .name = b.fmt("{s}_check", .{exe.name}),
        .root_module = exe.root_module,
    });
    const check_step = b.step("check", "Check if it compiles");
    check_step.dependOn(&exe_check.step);
}
