#!/bin/bash
# ============================================================
# run_forwarding.sh - Standalone VCS test for forwarding logic
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$(cd "$RISCV_TESTS_DIR/../rtl" && pwd)"
WORK_DIR="$RISCV_TESTS_DIR/work/forwarding"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/forwarding_simv"
COMPILE_LOG="$WORK_DIR/forwarding_vcs.log"
SIM_LOG="$WORK_DIR/forwarding_sim.log"

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

RTL_FILES="
    $RTL_DIR/core/decode/load_hazard_ctrl.sv
    $RTL_DIR/core/decode/forwarding.sv
    $RISCV_TESTS_DIR/tb/tb_forwarding.sv
"

echo "[INFO] Compiling forwarding directed test with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_forwarding \
    -Mdir="$WORK_DIR/forwarding_vcs.csrc" \
    -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -80 "$COMPILE_LOG"
    exit 1
fi

head -20 "$COMPILE_LOG"
echo "[INFO] Running forwarding directed test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
if ! grep -qF "[PASS] forwarding directed test" "$SIM_LOG"; then
    echo "ERROR: forwarding simulation did not report PASS"
    exit 1
fi
