#!/bin/bash
# Standalone state-transition and data-integrity test for dcache_store_buffer.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFICATION_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RISCV_TESTS_DIR="$VERIFICATION_DIR/riscv"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$RISCV_TESTS_DIR/work/store_buffer"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/store_buffer_simv"
COMPILE_LOG="$WORK_DIR/store_buffer_vcs.log"
SIM_LOG="$WORK_DIR/store_buffer_sim.log"

mkdir -p "$WORK_DIR"

if ! command -v vcs >/dev/null 2>&1; then
    if [ -f "$VCS_ENV" ]; then
        # shellcheck disable=SC1090
        source "$VCS_ENV"
    fi
fi
if ! command -v vcs >/dev/null 2>&1; then
    echo "ERROR: vcs not found in PATH. Source Synopsys env or set VCS_ENV=<setup.sh>."
    exit 1
fi

echo "[INFO] Compiling dcache_store_buffer directed/random test..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_dcache_store_buffer \
    -Mdir="$WORK_DIR/store_buffer_vcs.csrc" \
    -o "$SIM_BIN" \
    "$RTL_DIR/memory/dcache_store_buffer.sv" \
    "$SCRIPT_DIR/tb_dcache_store_buffer.sv" \
    "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -100 "$COMPILE_LOG"
    exit 1
fi

echo "[INFO] Running dcache_store_buffer directed/random test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
grep -qF "[PASS] dcache_store_buffer directed/random test" "$SIM_LOG"
