#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFICATION_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$VERIFICATION_DIR/common/work/predictor_update_contract"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/predictor_update_contract_simv"
COMPILE_LOG="$WORK_DIR/predictor_update_contract_vcs.log"
SIM_LOG="$WORK_DIR/predictor_update_contract_sim.log"
PASS_MARKER="[PASS] predictor update contract"

mkdir -p "$WORK_DIR"

if ! command -v vcs >/dev/null 2>&1 && [ -f "$VCS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$VCS_ENV"
fi
if ! command -v vcs >/dev/null 2>&1; then
    echo "ERROR: vcs not found in PATH"
    exit 1
fi

# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_predictor_update_contract \
    -Mdir="$WORK_DIR/predictor_update_contract_vcs.csrc" \
    -o "$SIM_BIN" \
    "$RTL_DIR/common/cpu_defs.sv" \
    "$RTL_DIR/core/frontend/predictor_update_ctrl.sv" \
    "$SCRIPT_DIR/tb_predictor_update_contract.sv" \
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
