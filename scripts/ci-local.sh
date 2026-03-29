#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

run_cross=1
if [[ "${1:-}" == "--no-cross" ]]; then
  run_cross=0
fi

echo "== Format check =="
zig fmt --check src/ build.zig build.zig.zon

echo "== Check =="
zig build check

echo "== Test =="
zig build test

if [[ "$run_cross" -eq 1 ]]; then
  echo "== Cross builds =="
  targets=(
    x86_64-linux
    aarch64-linux
    x86_64-windows
    aarch64-macos
  )

  for target in "${targets[@]}"; do
    echo "== Build ($target) =="
    zig build --release=safe -Dtarget="$target"
  done
fi

echo "All local CI checks passed."
