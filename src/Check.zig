const std = @import("std");
const Compose = @import("Compose.zig");
const Config = @import("Config.zig");

const Allocator = std.mem.Allocator;

pub const ServicePlan = struct {
    name: []const u8,
    image: []const u8,
    container_name: []const u8,
    original_port: u16,
    resolved_port: u16,
    container_port: u16,
    is_primary: bool,
    conflict: bool,
    script: ?[]const u8,
};

pub const CheckResult = struct {
    plans: []ServicePlan,
    errors: []const []const u8,
    ok: bool,
};

pub fn check(alloc: Allocator, cfg: Config.Config, compose: Compose.Compose) !CheckResult {
    var plans: std.ArrayList(ServicePlan) = .empty;
    var errors: std.ArrayList([]const u8) = .empty;

    for (cfg.databases) |db| {
        if (compose.findService(db.service) == null) {
            try errors.append(alloc, try std.fmt.allocPrint(
                alloc,
                "primary service '{s}' not found in compose",
                .{db.service},
            ));
        }
    }

    // Validate script files exist
    if (cfg.compose_file.len > 0) {
        const compose_dir = std.fs.path.dirnamePosix(cfg.compose_file) orelse ".";
        for (cfg.databases) |db| {
            const script_path = try std.fmt.allocPrint(alloc, "{s}/scripts/{s}", .{ compose_dir, db.script });
            const script_z = try alloc.dupeZ(u8, script_path);
            _ = std.posix.openatZ(std.posix.AT.FDCWD, script_z, .{}, 0) catch {
                try errors.append(alloc, try std.fmt.allocPrint(
                    alloc,
                    "script not found: {s}",
                    .{script_path},
                ));
            };
        }
    }

    for (cfg.databases, 0..) |db_a, i| {
        const svc_a = compose.findService(db_a.service) orelse continue;
        for (cfg.databases[i + 1 ..]) |db_b| {
            const svc_b = compose.findService(db_b.service) orelse continue;
            if (svc_a.host_port == svc_b.host_port and svc_a.host_port != 0) {
                try errors.append(alloc, try std.fmt.allocPrint(
                    alloc,
                    "primary services '{s}' and '{s}' share host port {d}",
                    .{ db_a.service, db_b.service, svc_a.host_port },
                ));
            }
        }
    }

    var conflict_count: u16 = 0;
    for (compose.services) |svc| {
        if (cfg.isPrimary(svc.name)) continue;
        if (conflictsWithAnyPrimary(cfg, compose, svc)) {
            conflict_count += 1;
        }
    }

    if (conflict_count > cfg.portRangeSize()) {
        try errors.append(alloc, try std.fmt.allocPrint(
            alloc,
            "port range [{d}-{d}] has {d} available ports but {d} services need remapping",
            .{ cfg.port_range_start, cfg.port_range_end, cfg.portRangeSize(), conflict_count },
        ));
    }

    var next_port: u16 = cfg.port_range_start;

    for (compose.services) |svc| {
        const is_primary = cfg.isPrimary(svc.name);

        if (is_primary) {
            const db = cfg.findDatabase(svc.name).?;
            try plans.append(alloc, .{
                .name = svc.name,
                .image = svc.image,
                .container_name = svc.container_name,
                .original_port = svc.host_port,
                .resolved_port = svc.host_port,
                .container_port = svc.container_port,
                .is_primary = true,
                .conflict = false,
                .script = db.script,
            });
            continue;
        }

        const has_conflict = conflictsWithAnyPrimary(cfg, compose, svc);
        const inherited_script = if (has_conflict and !cfg.shouldSkipScript(svc.name))
            findConflictingPrimaryScript(cfg, compose, svc)
        else
            null;

        var resolved_port = svc.host_port;
        if (has_conflict) {
            if (next_port >= cfg.port_range_end) {
                try errors.append(alloc, try std.fmt.allocPrint(
                    alloc,
                    "no ports available in range [{d}-{d}] for '{s}'",
                    .{ cfg.port_range_start, cfg.port_range_end, svc.name },
                ));
            } else {
                resolved_port = next_port;
                next_port += 1;
            }
        }

        try plans.append(alloc, .{
            .name = svc.name,
            .image = svc.image,
            .container_name = svc.container_name,
            .original_port = svc.host_port,
            .resolved_port = resolved_port,
            .container_port = svc.container_port,
            .is_primary = false,
            .conflict = has_conflict,
            .script = inherited_script,
        });
    }

    const errs = try errors.toOwnedSlice(alloc);

    return .{
        .plans = try plans.toOwnedSlice(alloc),
        .errors = errs,
        .ok = errs.len == 0,
    };
}

fn conflictsWithAnyPrimary(cfg: Config.Config, compose: Compose.Compose, svc: Compose.Service) bool {
    for (cfg.databases) |db| {
        const primary = compose.findService(db.service) orelse continue;
        if (svc.host_port == primary.host_port and primary.host_port != 0) {
            return true;
        }
    }
    return false;
}

fn findConflictingPrimaryScript(cfg: Config.Config, compose: Compose.Compose, svc: Compose.Service) ?[]const u8 {
    for (cfg.databases) |db| {
        const primary = compose.findService(db.service) orelse continue;
        if (svc.host_port == primary.host_port and primary.host_port != 0) {
            return db.script;
        }
    }
    return null;
}

pub fn printResult(result: CheckResult, writer: anytype) !void {
    if (result.errors.len > 0) {
        try writer.print("\n--- ERRORS ---\n", .{});
        for (result.errors) |err| {
            try writer.print("  x {s}\n", .{err});
        }
    }

    try writer.print("\n--- EXECUTION PLAN ---\n", .{});

    for (result.plans) |plan| {
        if (plan.is_primary) {
            try writer.print("\n  * [{s}] (primary)\n", .{plan.name});
        } else if (plan.conflict) {
            try writer.print("\n  ! [{s}] (conflict resolved)\n", .{plan.name});
        } else {
            try writer.print("\n  - [{s}]\n", .{plan.name});
        }

        try writer.print("    image:     {s}\n", .{plan.image});
        try writer.print("    container: {s}\n", .{plan.container_name});

        if (plan.conflict) {
            try writer.print("    port:      {d}:{d} -> {d}:{d}\n", .{
                plan.original_port, plan.container_port,
                plan.resolved_port, plan.container_port,
            });
        } else {
            try writer.print("    port:      {d}:{d}\n", .{
                plan.resolved_port, plan.container_port,
            });
        }

        if (plan.script) |script| {
            try writer.print("    script:    {s}\n", .{script});
        }
    }

    try writer.print("\n", .{});

    if (result.ok) {
        try writer.print("ok: check passed -- {d} services configured\n\n", .{result.plans.len});
    } else {
        try writer.print("error: check failed -- {d} error(s)\n\n", .{result.errors.len});
    }
}

test "detect port conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-hom", .script = "backup.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-hom", .image = "postgres:15", .container_name = "pg_hom", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-prod", .image = "postgres:15", .container_name = "pg_prod", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-other", .image = "postgres:15", .container_name = "pg_other", .host_port = 6000, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 3), result.plans.len);

    try std.testing.expect(result.plans[0].is_primary);
    try std.testing.expectEqual(@as(u16, 5432), result.plans[0].resolved_port);

    try std.testing.expect(result.plans[1].conflict);
    try std.testing.expectEqual(@as(u16, 6100), result.plans[1].resolved_port);

    try std.testing.expect(!result.plans[2].conflict);
    try std.testing.expectEqual(@as(u16, 6000), result.plans[2].resolved_port);
}

test "error when primary service missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "nope", .script = "backup.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-hom", .image = "pg", .container_name = "pg_hom", .host_port = 5432, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "error when primaries share same port" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-a", .script = "a.sql" },
            .{ .service = "db-b", .script = "b.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-a", .image = "pg", .container_name = "pg_a", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-b", .image = "pg", .container_name = "pg_b", .host_port = 5432, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(!result.ok);
}

test "error when port range insufficient" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6101,
        .databases = &[_]Config.Database{
            .{ .service = "db-main", .script = "backup.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-main", .image = "pg", .container_name = "pg_main", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-sec1", .image = "pg", .container_name = "pg_sec1", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-sec2", .image = "pg", .container_name = "pg_sec2", .host_port = 5432, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(!result.ok);
}

test "multi-primary no conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-a", .script = "a.sql" },
            .{ .service = "db-c", .script = "c.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-a", .image = "pg", .container_name = "pg_a", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-b", .image = "pg", .container_name = "pg_b", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-c", .image = "pg", .container_name = "pg_c", .host_port = 5433, .container_port = 5432 },
            .{ .name = "db-d", .image = "pg", .container_name = "pg_d", .host_port = 5433, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 4), result.plans.len);

    try std.testing.expect(result.plans[0].is_primary);
    try std.testing.expectEqual(@as(u16, 5432), result.plans[0].resolved_port);

    try std.testing.expect(result.plans[1].conflict);
    try std.testing.expectEqual(@as(u16, 6100), result.plans[1].resolved_port);

    try std.testing.expect(result.plans[2].is_primary);
    try std.testing.expectEqual(@as(u16, 5433), result.plans[2].resolved_port);

    try std.testing.expect(result.plans[3].conflict);
    try std.testing.expectEqual(@as(u16, 6101), result.plans[3].resolved_port);
}

test "port range exactly sufficient" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6102,
        .databases = &[_]Config.Database{
            .{ .service = "db-main", .script = "backup.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-main", .image = "pg", .container_name = "pg_main", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-sec1", .image = "pg", .container_name = "pg_sec1", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-sec2", .image = "pg", .container_name = "pg_sec2", .host_port = 5432, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u16, 6100), result.plans[1].resolved_port);
    try std.testing.expectEqual(@as(u16, 6101), result.plans[2].resolved_port);
}

test "all services are primaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-a", .script = "a.sql" },
            .{ .service = "db-b", .script = "b.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-a", .image = "pg", .container_name = "pg_a", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-b", .image = "pg", .container_name = "pg_b", .host_port = 5433, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(result.ok);
    try std.testing.expect(result.plans[0].is_primary);
    try std.testing.expect(result.plans[1].is_primary);
}

test "service with port zero does not conflict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-main", .script = "backup.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-main", .image = "pg", .container_name = "pg_main", .host_port = 5432, .container_port = 5432 },
            .{ .name = "app", .image = "node", .container_name = "app", .host_port = 0, .container_port = 0 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(result.ok);
    try std.testing.expect(!result.plans[1].conflict);
    try std.testing.expectEqual(@as(u16, 0), result.plans[1].resolved_port);
}

test "primary with port zero does not cause false conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-main", .script = "backup.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-main", .image = "pg", .container_name = "pg_main", .host_port = 0, .container_port = 5432 },
            .{ .name = "db-other", .image = "pg", .container_name = "pg_other", .host_port = 0, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(result.ok);
    try std.testing.expect(!result.plans[1].conflict);
}

test "multiple primaries some missing from compose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-a", .script = "a.sql" },
            .{ .service = "db-missing", .script = "m.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-a", .image = "pg", .container_name = "pg_a", .host_port = 5432, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "secondary conflicts with multiple primaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-a", .script = "a.sql" },
            .{ .service = "db-b", .script = "b.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-a", .image = "pg", .container_name = "pg_a", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-b", .image = "pg", .container_name = "pg_b", .host_port = 5433, .container_port = 5432 },
            .{ .name = "db-sec", .image = "pg", .container_name = "pg_sec", .host_port = 5432, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(result.ok);
    try std.testing.expect(result.plans[2].conflict);
    try std.testing.expectEqual(@as(u16, 6100), result.plans[2].resolved_port);
}

test "secondary inherits primary script" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-main", .script = "backup.sql" },
        },
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-main", .image = "pg", .container_name = "pg_main", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-copy", .image = "pg", .container_name = "pg_copy", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-other", .image = "pg", .container_name = "pg_other", .host_port = 6000, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(result.ok);

    // primary has its own script
    try std.testing.expectEqualStrings("backup.sql", result.plans[0].script.?);
    // conflicting secondary inherits primary's script
    try std.testing.expectEqualStrings("backup.sql", result.plans[1].script.?);
    // non-conflicting service has no script
    try std.testing.expect(result.plans[2].script == null);
}

test "skip_scripts prevents script inheritance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cfg = Config.Config{
        .compose_file = "",
        .port_range_start = 6100,
        .port_range_end = 6200,
        .databases = &[_]Config.Database{
            .{ .service = "db-main", .script = "backup.sql" },
        },
        .skip_scripts = &[_][]const u8{"db-skip"},
    };

    const compose = Compose.Compose{
        .services = @constCast(&[_]Compose.Service{
            .{ .name = "db-main", .image = "pg", .container_name = "pg_main", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-copy", .image = "pg", .container_name = "pg_copy", .host_port = 5432, .container_port = 5432 },
            .{ .name = "db-skip", .image = "pg", .container_name = "pg_skip", .host_port = 5432, .container_port = 5432 },
        }),
    };

    const result = try check(alloc, cfg, compose);
    try std.testing.expect(result.ok);

    // primary has script
    try std.testing.expectEqualStrings("backup.sql", result.plans[0].script.?);
    // db-copy inherits script
    try std.testing.expectEqualStrings("backup.sql", result.plans[1].script.?);
    // db-skip is excluded via skip_scripts
    try std.testing.expect(result.plans[2].script == null);
}
