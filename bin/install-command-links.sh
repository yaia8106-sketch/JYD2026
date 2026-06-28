#!/usr/bin/env bash
set -e

THIS="$(readlink -f "${BASH_SOURCE[0]}")"
BIN_DIR="$(cd "$(dirname "$THIS")" && pwd)"
TARGET_DIR="${1:-$HOME/.local/bin}"
COMMANDS=(run-perf coe-perf short-perf)
RETIRED_COMMANDS=(branch-diag)

mkdir -p "$TARGET_DIR"

for cmd in "${COMMANDS[@]}"; do
    chmod +x "$BIN_DIR/$cmd"
    ln -sfn "$BIN_DIR/$cmd" "$TARGET_DIR/$cmd"
    echo "[LINK] $TARGET_DIR/$cmd -> $BIN_DIR/$cmd"
done

for cmd in "${RETIRED_COMMANDS[@]}"; do
    target="$TARGET_DIR/$cmd"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$BIN_DIR/$cmd" ]; then
        rm -f "$target"
        echo "[REMOVE] retired link $target"
    fi
done

echo "[OK] Command links installed."
