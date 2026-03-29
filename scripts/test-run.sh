#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$PROJECT_DIR/zig-out/bin"

echo "=== Building ==="
cd "$PROJECT_DIR"
zig build

echo ""
echo "=== Syncing test files ==="
cp "$PROJECT_DIR/examples/compose.yml" "$BIN_DIR/compose.yml"
cp "$PROJECT_DIR/backupz.zon" "$BIN_DIR/backupz.zon"
cp "$PROJECT_DIR/examples/scripts/"*.sql "$BIN_DIR/scripts/"

# The zon in zig-out/bin needs compose_file pointing to local compose.yml
sed -i 's|examples/compose.yml|compose.yml|' "$BIN_DIR/backupz.zon"

echo ""
echo "=== Running check ==="
cd "$BIN_DIR"
./backupz -d compose.yml check

echo ""
echo "=== Running backupz ==="
./backupz -d compose.yml run

echo ""
echo "=== Docker state ==="
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "=== Done ==="
