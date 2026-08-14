#!/bin/bash
# ============================================================
# run_forwarding.sh - Standalone VCS test for forwarding logic
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFICATION_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$VERIFICATION_DIR/common/work/forwarding"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/forwarding_simv"
COMPILE_LOG="$WORK_DIR/forwarding_vcs.log"
FORWARDING_SEEDS="${FORWARDING_SEEDS:-1 7 29 20260801}"

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
    $RTL_DIR/core/decode/issue_hazard_ctrl.sv
    $RTL_DIR/core/decode/forwarding.sv
    $RTL_DIR/core/decode/mul_operand_forwarding.sv
    $SCRIPT_DIR/tb_forwarding.sv
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
for seed in $FORWARDING_SEEDS; do
    SIM_LOG="$WORK_DIR/forwarding_sim_${seed}.log"
    echo "[INFO] Running forwarding directed/random test seed=$seed..."
    if ! "$SIM_BIN" "+seed=$seed" >"$SIM_LOG" 2>&1; then
        cat "$SIM_LOG"
        exit 1
    fi
    cat "$SIM_LOG"
    if ! grep -qF "[PASS] forwarding directed test" "$SIM_LOG"; then
        echo "ERROR: forwarding simulation seed=$seed did not report PASS"
        exit 1
    fi
done
