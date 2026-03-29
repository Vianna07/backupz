const std = @import("std");
const Yaml = @import("yaml").Yaml;

const Allocator = std.mem.Allocator;

pub const Service = struct {
    name: []const u8,
    image: []const u8,
    container_name: []const u8,
    host_port: u16,
    container_port: u16,
};

pub const Compose = struct {
    services: []Service,

    pub fn parse(alloc: Allocator, source: []const u8) !Compose {
        const safe_source = stripTopLevelVolumes(source);
        var yaml: Yaml = .{ .source = safe_source };
        defer yaml.deinit(alloc);
        try yaml.load(alloc);

        if (yaml.docs.items.len == 0) return error.EmptyDocument;

        const root = yaml.docs.items[0].asMap() orelse return error.InvalidFormat;
        const services_val = root.get("services") orelse return error.MissingServices;
        const services_map = services_val.asMap() orelse return error.InvalidFormat;

        var services: std.ArrayList(Service) = .empty;

        for (services_map.keys(), services_map.values()) |name, value| {
            const svc = value.asMap() orelse continue;

            var host_port: u16 = 0;
            var container_port: u16 = 0;

            if (svc.get("ports")) |ports_val| {
                if (ports_val.asList()) |ports| {
                    if (ports.len > 0) {
                        const port_str = ports[0].asScalar() orelse continue;
                        const parsed = parsePortMapping(port_str);
                        host_port = parsed.host;
                        container_port = parsed.container;
                    }
                }
            }

            try services.append(alloc, .{
                .name = try alloc.dupe(u8, name),
                .image = try alloc.dupe(u8, if (svc.get("image")) |v| (v.asScalar() orelse "-") else "-"),
                .container_name = try alloc.dupe(u8, if (svc.get("container_name")) |v| (v.asScalar() orelse name) else name),
                .host_port = host_port,
                .container_port = container_port,
            });
        }

        return .{ .services = try services.toOwnedSlice(alloc) };
    }

    pub fn findService(self: Compose, name: []const u8) ?Service {
        for (self.services) |svc| {
            if (std.mem.eql(u8, svc.name, name)) return svc;
        }
        return null;
    }
};

const PortPair = struct { host: u16, container: u16 };

fn parsePortMapping(raw: []const u8) PortPair {
    var str = raw;
    if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"') {
        str = str[1 .. str.len - 1];
    }

    if (std.mem.indexOf(u8, str, ":")) |colon| {
        const host = std.fmt.parseInt(u16, str[0..colon], 10) catch 0;
        const container = std.fmt.parseInt(u16, str[colon + 1 ..], 10) catch 0;
        return .{ .host = host, .container = container };
    }

    const port = std.fmt.parseInt(u16, str, 10) catch 0;
    return .{ .host = port, .container = port };
}

fn stripTopLevelVolumes(source: []const u8) []const u8 {
    if (std.mem.indexOf(u8, source, "\nvolumes:")) |pos| {
        const after = source[pos + 1 ..];
        // Only strip if "volumes:" is at column 0 (top-level key)
        if (after.len >= 8 and after[0] == 'v') {
            // Trim trailing whitespace
            var end = pos;
            while (end > 0 and (source[end - 1] == ' ' or source[end - 1] == '\t' or source[end - 1] == '\n' or source[end - 1] == '\r')) {
                end -= 1;
            }
            return source[0..end];
        }
    }
    return source;
}

test "parse port mapping" {
    const p1 = parsePortMapping("5432:5432");
    try std.testing.expectEqual(@as(u16, 5432), p1.host);
    try std.testing.expectEqual(@as(u16, 5432), p1.container);

    const p2 = parsePortMapping("6000:5432");
    try std.testing.expectEqual(@as(u16, 6000), p2.host);
    try std.testing.expectEqual(@as(u16, 5432), p2.container);
}

test "parse compose services" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\services:
        \\  db-hom:
        \\    image: postgres:15-alpine
        \\    container_name: pg_hom
        \\    ports:
        \\      - "5432:5432"
        \\  db-prod:
        \\    image: postgres:15-alpine
        \\    container_name: pg_prod
        \\    ports:
        \\      - "5432:5432"
        \\  db-other:
        \\    image: postgres:15-alpine
        \\    container_name: pg_other
        \\    ports:
        \\      - "6000:5432"
    ;

    const compose = try Compose.parse(alloc, source);

    try std.testing.expectEqual(@as(usize, 3), compose.services.len);

    const hom = compose.findService("db-hom").?;
    try std.testing.expectEqual(@as(u16, 5432), hom.host_port);

    const other = compose.findService("db-other").?;
    try std.testing.expectEqual(@as(u16, 6000), other.host_port);

    try std.testing.expect(compose.findService("nope") == null);
}

test "error on missing services key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\volumes:
        \\  - pgdata
    ;

    const result = Compose.parse(alloc, source);
    try std.testing.expectError(error.MissingServices, result);
}

test "service without ports defaults to zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\services:
        \\  app:
        \\    image: node:18
        \\    container_name: my_app
    ;

    const compose = try Compose.parse(alloc, source);
    try std.testing.expectEqual(@as(usize, 1), compose.services.len);
    try std.testing.expectEqual(@as(u16, 0), compose.services[0].host_port);
    try std.testing.expectEqual(@as(u16, 0), compose.services[0].container_port);
}

test "service without image or container_name uses defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\services:
        \\  myservice:
        \\    ports:
        \\      - "3000:3000"
    ;

    const compose = try Compose.parse(alloc, source);
    try std.testing.expectEqual(@as(usize, 1), compose.services.len);
    try std.testing.expectEqualStrings("-", compose.services[0].image);
    try std.testing.expectEqualStrings("myservice", compose.services[0].container_name);
}

test "parse single port without colon" {
    const p = parsePortMapping("5432");
    try std.testing.expectEqual(@as(u16, 5432), p.host);
    try std.testing.expectEqual(@as(u16, 5432), p.container);
}

test "parse invalid port string" {
    const p = parsePortMapping("abc:def");
    try std.testing.expectEqual(@as(u16, 0), p.host);
    try std.testing.expectEqual(@as(u16, 0), p.container);
}

test "parse compose with top-level volumes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const source =
        \\services:
        \\  db-hom:
        \\    image: postgres:15-alpine
        \\    container_name: pg_hom
        \\    ports:
        \\      - "5432:5432"
        \\
        \\volumes:
        \\  pgdata_hom:
    ;

    const compose = try Compose.parse(alloc, source);
    try std.testing.expectEqual(@as(usize, 1), compose.services.len);
    try std.testing.expectEqualStrings("db-hom", compose.services[0].name);
}
