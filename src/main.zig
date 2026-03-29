const std = @import("std");
const builtin = @import("builtin");
const Yaml = @import("yaml").Yaml;

const Sample = struct {
    name: []const u8,
    is_student: bool,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const gpa = if (builtin.mode == .Debug)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const stdout_file = std.Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer_instance = stdout_file.writer(init.io, &buf);
    const stdout = &writer_instance.interface;

    const source =
        \\ name: Vianna
        \\ is_student: true
    ;
    var yaml: Yaml = .{ .source = source };
    defer yaml.deinit(gpa);
    try yaml.load(gpa);

    const sample = try yaml.parse(gpa, Sample);

    try stdout.print("\nSample = {any}\n", .{sample});
    try yaml.stringify(stdout);
    try stdout.flush();
}

test "yaml parsing" {
    const alloc = std.testing.allocator;

    const source =
        \\ name: Vianna
        \\ is_student: true
    ;
    var yaml: Yaml = .{ .source = source };
    defer yaml.deinit(alloc);
    try yaml.load(alloc);

    const sample = try yaml.parse(alloc, Sample);
    try std.testing.expectEqualStrings("Vianna", sample.name);
    try std.testing.expectEqual(sample.is_student, true);
}
