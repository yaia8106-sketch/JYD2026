#!/usr/bin/env bash
set -e

THIS="$(readlink -f "${BASH_SOURCE[0]}")"
BIN_DIR="$(cd "$(dirname "$THIS")" && pwd)"
TARGET_DIR="${1:-$HOME/.local/bin}"
COMMANDS=(run-perf coe-perf branch-diag short-perf)

mkdir -p "$TARGET_DIR"

for cmd in "${COMMANDS[@]}"; do
    chmod +x "$BIN_DIR/$cmd"
    ln -sfn "$BIN_DIR/$cmd" "$TARGET_DIR/$cmd"
    echo "[LINK] $TARGET_DIR/$cmd -> $BIN_DIR/$cmd"
done

echo "[OK] Command links installed."
