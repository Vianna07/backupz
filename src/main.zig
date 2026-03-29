const std = @import("std");
const builtin = @import("builtin");
const Yaml = @import("yaml").Yaml;

const Sample = struct {
    name: []const u8,
    is_student: bool,
};

pub fn main(init: std.process.Init) !void {
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
    defer yaml.deinit(arena);
    try yaml.load(arena);

    const sample = try yaml.parse(arena, Sample);

    try stdout.print("\nSample = {any}\n", .{sample});
    try yaml.stringify(stdout);
    try stdout.flush();
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

    const sample = try yaml.parse(alloc, Sample);
    try std.testing.expectEqualStrings("Vianna", sample.name);
    try std.testing.expectEqual(sample.is_student, true);
}
