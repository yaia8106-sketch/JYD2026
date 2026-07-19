#!/bin/bash
# Standalone randomized RV32 bit-manipulation decoder/execution test.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$(cd "$RISCV_TESTS_DIR/../rtl" && pwd)"
WORK_DIR="$RISCV_TESTS_DIR/work/bitmanip"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/bitmanip_simv"
COMPILE_LOG="$WORK_DIR/bitmanip_vcs.log"
SIM_LOG="$WORK_DIR/bitmanip_sim.log"

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

echo "[INFO] Compiling bitmanip decoder/unit randomized test with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_bitmanip_unit \
    -Mdir="$WORK_DIR/bitmanip_vcs.csrc" \
    -o "$SIM_BIN" \
    "$RTL_DIR/common/cpu_defs.sv" \
    "$RTL_DIR/core/decode/bitmanip_decoder.sv" \
    "$RTL_DIR/core/frontend/frontend_predecode.sv" \
    "$RTL_DIR/core/execute/bitmanip_fast_unit.sv" \
    "$RTL_DIR/core/execute/bitmanip_unit.sv" \
    "$RISCV_TESTS_DIR/tb/tb_bitmanip_unit.sv" \
    "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -100 "$COMPILE_LOG"
    exit 1
fi

echo "[INFO] Running bitmanip decoder/unit randomized test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
grep -qF "[PASS] bitmanip decoder/unit randomized test" "$SIM_LOG"
