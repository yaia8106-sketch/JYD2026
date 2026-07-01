#!/bin/bash
# Standalone Stage-1 PHT/GHR directed test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$(cd "$RISCV_TESTS_DIR/../rtl" && pwd)"
WORK_DIR="$RISCV_TESTS_DIR/work/frontend_stage1_direction"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/frontend_stage1_direction_simv"
COMPILE_LOG="$WORK_DIR/frontend_stage1_direction_vcs.log"
SIM_LOG="$WORK_DIR/frontend_stage1_direction_sim.log"
PASS_MARKER="[PASS] frontend Stage-1 direction directed test"

mkdir -p "$WORK_DIR"

if ! command -v vcs >/dev/null 2>&1 && [ -f "$VCS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$VCS_ENV"
fi
if ! command -v vcs >/dev/null 2>&1; then
    echo "ERROR: vcs not found in PATH"
    exit 1
fi

if ! vcs $VCS_OPTS -top tb_frontend_stage1_direction \
    -Mdir="$WORK_DIR/frontend_stage1_direction_vcs.csrc" \
    -o "$SIM_BIN" \
    "$RTL_DIR/core/frontend/frontend_stage1_direction.sv" \
    "$RISCV_TESTS_DIR/tb/tb_frontend_stage1_direction.sv" \
    "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    head -120 "$COMPILE_LOG"
    exit 1
fi

if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
grep -qF "$PASS_MARKER" "$SIM_LOG"
