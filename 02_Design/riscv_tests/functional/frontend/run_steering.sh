#!/bin/bash
# cpu_top default ABTB/PHT branch steering integration test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$(cd "$RISCV_TESTS_DIR/../rtl" && pwd)"
WORK_DIR="$RISCV_TESTS_DIR/work/frontend_abtb_steering"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/frontend_abtb_steering_simv"
COMPILE_LOG="$WORK_DIR/frontend_abtb_steering_vcs.log"
SIM_LOG="$WORK_DIR/frontend_abtb_steering_sim.log"
PASS_MARKER="[PASS] frontend ABTB/PHT branch steering integration test"

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
    -F $RTL_DIR/filelists/cpu_blocks.f
    $RTL_DIR/core/cpu_top.sv
    $RISCV_TESTS_DIR/tb/tb_frontend_abtb_steering.sv
"

echo "[INFO] Compiling frontend ABTB/PHT branch steering test with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS \
    -top tb_frontend_abtb_steering \
    -Mdir="$WORK_DIR/frontend_abtb_steering_vcs.csrc" \
    -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -120 "$COMPILE_LOG"
    exit 1
fi

echo "[INFO] Running frontend ABTB/PHT branch steering test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
if ! grep -qF "$PASS_MARKER" "$SIM_LOG"; then
    echo "ERROR: branch steering simulation did not report PASS"
    exit 1
fi
