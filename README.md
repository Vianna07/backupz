# backupz

PostgreSQL backup manager via Docker Compose.

Reads a `backupz.zon` config, parses your `docker-compose.yml`, detects port conflicts between primary and secondary databases, remaps ports automatically, and executes the backup pipeline.

[Leia em Português](README.pt-BR.md)

## Requirements

- [Zig](https://ziglang.org/) 0.16+
- Docker (for the `run` command)

## Build

```sh
zig build
```

The binary will be at `zig-out/bin/backupz`.

## Usage

```
backupz [options] <command>
```

### Commands

| Command | Description |
|---------|-------------|
| `check` | Validate `backupz.zon` and show the execution plan |
| `run`   | Execute the backup (runs `check` first, then docker compose) |
| `help`  | Show usage information |

### Options

| Option | Description |
|--------|-------------|
| `-d <file>` | Override the compose file path |

### Examples

```sh
backupz check
backupz run
backupz -d docker-compose.prod.yml check
```

## Configuration

Create a `backupz.zon` file in the project root:

```zon
.{
    .compose_file = "examples/compose.yml",
    .port_range_start = 6100,
    .port_range_end = 6200,
    .databases = .{
        .{ .service = "db-hom", .script = "backup.sql" },
    },
}
```

| Field | Description |
|-------|-------------|
| `compose_file` | Path to the Docker Compose file |
| `port_range_start` | Start of the port range for remapping conflicts |
| `port_range_end` | End of the port range |
| `databases` | List of primary databases (service name + SQL script) |
| `skip_scripts` | (optional) List of secondary services that should NOT inherit scripts |

### Multi-primary support

You can define multiple primary databases:

```zon
.{
    .compose_file = "compose.yml",
    .port_range_start = 6100,
    .port_range_end = 6200,
    .databases = .{
        .{ .service = "db-hom", .script = "backup_hom.sql" },
        .{ .service = "db-staging", .script = "backup_staging.sql" },
    },
}
```

### Script inheritance

Secondary databases that conflict with a primary automatically inherit the primary's backup script. To skip script execution on specific secondaries:

```zon
.{
    .compose_file = "compose.yml",
    .port_range_start = 6100,
    .port_range_end = 6200,
    .databases = .{
        .{ .service = "db-hom", .script = "backup.sql" },
    },
    .skip_scripts = .{ "db-analytics" },
}
```

## Project structure

```
backupz/
  backupz.zon              # runtime configuration
  build.zig                # build script
  examples/
    compose.yml            # example Docker Compose file
    scripts/
      backup.sql           # example SQL backup script
      backup_other.sql     # example SQL backup script (secondary primary)
  scripts/                 # CI/CD and test scripts
  src/                     # source code
```

The `examples/` directory contains a working example setup. The compose file mounts `./scripts` into the database containers so that `psql -f /scripts/<script>.sql` works at runtime.

## How it works

1. **check** reads `backupz.zon` and the compose file
2. Identifies which secondary services conflict with primary ports
3. Validates that the port range is sufficient for remapping
4. Generates an execution plan showing port reassignments

The **run** command additionally:

5. Validates that script files exist on disk
6. Verifies Docker is available
7. Removes existing containers to prevent name conflicts
8. Brings up all services with remapped ports and scripts volume (via a generated override file)
9. Waits for PostgreSQL readiness then executes SQL scripts on each database
10. Stops conflict-resolved secondary services (primaries and non-conflicting services stay running)

## Tests

```sh
zig build test
```
