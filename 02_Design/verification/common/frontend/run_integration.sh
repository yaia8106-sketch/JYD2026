#!/bin/bash
# ============================================================
# run_integration.sh - cpu_top shadow ABTB VCS test
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFICATION_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RISCV_TESTS_DIR="$VERIFICATION_DIR/riscv"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$RISCV_TESTS_DIR/work/frontend_abtb_integration"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/frontend_abtb_integration_simv"
COMPILE_LOG="$WORK_DIR/frontend_abtb_integration_vcs.log"
SIM_LOG="$WORK_DIR/frontend_abtb_integration_sim.log"

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
    $SCRIPT_DIR/tb_frontend_abtb_integration.sv
"

echo "[INFO] Compiling frontend ABTB shadow integration test with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_frontend_abtb_integration \
    -Mdir="$WORK_DIR/frontend_abtb_integration_vcs.csrc" \
    -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -100 "$COMPILE_LOG"
    exit 1
fi

head -20 "$COMPILE_LOG"
echo "[INFO] Running frontend ABTB shadow integration test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
if ! grep -qF "[PASS] frontend ABTB shadow integration test" "$SIM_LOG"; then
    echo "ERROR: frontend ABTB shadow integration simulation did not report PASS"
    exit 1
fi
