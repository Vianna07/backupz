#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TAG_NAME="${1:-v0.0.0-local}"
DIST_DIR="dist/${TAG_NAME}"
mkdir -p "$DIST_DIR"

echo "Creating local release artifacts for tag: $TAG_NAME"

targets=(
  "x86_64-linux:tar.xz"
  "aarch64-linux:tar.xz"
  "x86_64-windows:zip"
  "aarch64-macos:tar.xz"
)

for spec in "${targets[@]}"; do
  target="${spec%%:*}"
  archive="${spec##*:}"

  echo "== Build ($target) =="
  zig build --release=safe -Dtarget="$target"

  if [[ "$archive" == "tar.xz" ]]; then
    out="${DIST_DIR}/backupz-${TAG_NAME}-${target}.tar.xz"
    tar -cJf "$out" -C zig-out/bin backupz
  else
    out="${DIST_DIR}/backupz-${TAG_NAME}-${target}.zip"
    zip -q "$out" zig-out/bin/backupz.exe
  fi

  echo "Created: $out"
done

echo "Local CD artifacts are in: $DIST_DIR"
