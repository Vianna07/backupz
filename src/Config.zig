const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Database = struct {
    service: []const u8,
    script: []const u8,
};

pub const Config = struct {
    compose_file: []const u8,
    port_range_start: u16,
    port_range_end: u16,
    databases: []const Database,
    skip_scripts: []const []const u8 = &.{},

    pub fn load(alloc: Allocator, source: []const u8) !Config {
        const source_z = try alloc.dupeZ(u8, source);
        const parsed = try std.zon.parse.fromSliceAlloc(Config, alloc, source_z, null, .{});

        if (parsed.port_range_start >= parsed.port_range_end) return error.InvalidPortRange;
        if (parsed.databases.len == 0) return error.NoDatabases;

        return parsed;
    }

    pub fn portRangeSize(self: Config) u16 {
        return self.port_range_end - self.port_range_start;
    }

    pub fn isPrimary(self: Config, service_name: []const u8) bool {
        for (self.databases) |db| {
            if (std.mem.eql(u8, db.service, service_name)) return true;
        }
        return false;
    }

    pub fn findDatabase(self: Config, service_name: []const u8) ?Database {
        for (self.databases) |db| {
            if (std.mem.eql(u8, db.service, service_name)) return db;
        }
        return null;
    }

    pub fn shouldSkipScript(self: Config, service_name: []const u8) bool {
        for (self.skip_scripts) |name| {
            if (std.mem.eql(u8, name, service_name)) return true;
        }
        return false;
    }
};

test "load config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\.{
        \\    .compose_file = "compose.example.yml",
        \\    .port_range_start = 6100,
        \\    .port_range_end = 6200,
        \\    .databases = .{
        \\        .{ .service = "db-hom", .script = "backup.sql" },
        \\    },
        \\}
    ;

    const cfg = try Config.load(alloc, source);

    try std.testing.expectEqualStrings("compose.example.yml", cfg.compose_file);
    try std.testing.expectEqual(@as(u16, 6100), cfg.port_range_start);
    try std.testing.expectEqual(@as(u16, 6200), cfg.port_range_end);
    try std.testing.expectEqual(@as(usize, 1), cfg.databases.len);
    try std.testing.expectEqualStrings("db-hom", cfg.databases[0].service);
    try std.testing.expectEqualStrings("backup.sql", cfg.databases[0].script);
    try std.testing.expectEqual(@as(u16, 100), cfg.portRangeSize());
}

test "reject invalid port range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\.{
        \\    .compose_file = "compose.example.yml",
        \\    .port_range_start = 6200,
        \\    .port_range_end = 6100,
        \\    .databases = .{
        \\        .{ .service = "db-hom", .script = "backup.sql" },
        \\    },
        \\}
    ;

    const result = Config.load(alloc, source);
    try std.testing.expectError(error.InvalidPortRange, result);
}

test "reject empty databases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\.{
        \\    .compose_file = "compose.example.yml",
        \\    .port_range_start = 6100,
        \\    .port_range_end = 6200,
        \\    .databases = .{},
        \\}
    ;

    const result = Config.load(alloc, source);
    try std.testing.expectError(error.NoDatabases, result);
}

test "reject invalid zon syntax" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const result = Config.load(alloc, "this is not valid zon{{{");
    try std.testing.expect(std.meta.isError(result));
}

test "reject missing required fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\.{
        \\    .compose_file = "compose.yml",
        \\}
    ;

    const result = Config.load(alloc, source);
    try std.testing.expect(std.meta.isError(result));
}

test "reject equal port range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\.{
        \\    .compose_file = "compose.yml",
        \\    .port_range_start = 6100,
        \\    .port_range_end = 6100,
        \\    .databases = .{
        \\        .{ .service = "db-hom", .script = "backup.sql" },
        \\    },
        \\}
    ;

    const result = Config.load(alloc, source);
    try std.testing.expectError(error.InvalidPortRange, result);
}

test "load multiple databases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\.{
        \\    .compose_file = "compose.yml",
        \\    .port_range_start = 6100,
        \\    .port_range_end = 6200,
        \\    .databases = .{
        \\        .{ .service = "db-hom", .script = "backup_hom.sql" },
        \\        .{ .service = "db-staging", .script = "backup_staging.sql" },
        \\    },
        \\}
    ;

    const cfg = try Config.load(alloc, source);

    try std.testing.expectEqual(@as(usize, 2), cfg.databases.len);
    try std.testing.expectEqualStrings("db-hom", cfg.databases[0].service);
    try std.testing.expectEqualStrings("db-staging", cfg.databases[1].service);
    try std.testing.expect(cfg.isPrimary("db-hom"));
    try std.testing.expect(cfg.isPrimary("db-staging"));
    try std.testing.expect(!cfg.isPrimary("db-other"));
    try std.testing.expect(cfg.findDatabase("db-hom") != null);
    try std.testing.expect(cfg.findDatabase("nope") == null);
}

test "load config with skip_scripts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\.{
        \\    .compose_file = "compose.yml",
        \\    .port_range_start = 6100,
        \\    .port_range_end = 6200,
        \\    .databases = .{
        \\        .{ .service = "db-hom", .script = "backup.sql" },
        \\    },
        \\    .skip_scripts = .{ "db-analytics", "db-temp" },
        \\}
    ;

    const cfg = try Config.load(alloc, source);
    try std.testing.expect(cfg.shouldSkipScript("db-analytics"));
    try std.testing.expect(cfg.shouldSkipScript("db-temp"));
    try std.testing.expect(!cfg.shouldSkipScript("db-hom"));
    try std.testing.expect(!cfg.shouldSkipScript("db-prod"));
}

test "config without skip_scripts uses empty default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\.{
        \\    .compose_file = "compose.yml",
        \\    .port_range_start = 6100,
        \\    .port_range_end = 6200,
        \\    .databases = .{
        \\        .{ .service = "db-hom", .script = "backup.sql" },
        \\    },
        \\}
    ;

    const cfg = try Config.load(alloc, source);
    try std.testing.expectEqual(@as(usize, 0), cfg.skip_scripts.len);
    try std.testing.expect(!cfg.shouldSkipScript("anything"));
}
