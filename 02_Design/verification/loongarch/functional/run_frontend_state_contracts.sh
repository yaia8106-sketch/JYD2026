#!/bin/bash
# Standalone VCS gate for FQ state updates and IF/ID timing copies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOONGARCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$LOONGARCH_DIR/.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$LOONGARCH_DIR/work/frontend_state_contracts"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/simv"
COMPILE_LOG="$WORK_DIR/compile.log"
SIM_LOG="$WORK_DIR/sim.log"

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

echo "[INFO] Compiling LoongArch frontend state contract test..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS \
    -top tb_loongarch_frontend_state_contracts \
    -Mdir="$WORK_DIR/vcs.csrc" \
    -o "$SIM_BIN" \
    "$RTL_DIR/common/cpu_defs.sv" \
    "$RTL_DIR/core/frontend/frontend_fetch_queue.sv" \
    "$RTL_DIR/core/pipeline/if_id_reg.sv" \
    "$LOONGARCH_DIR/tb/tb_loongarch_frontend_state_contracts.sv" \
    "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: LoongArch frontend state contract compilation failed"
    head -120 "$COMPILE_LOG"
    exit 1
fi
if grep -Eq 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' "$COMPILE_LOG"; then
    echo "ERROR: frontend state compilation reported a gated RTL/TB warning"
    grep -E 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' "$COMPILE_LOG"
    exit 1
fi

echo "[INFO] Running LoongArch frontend state contract test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
if ! grep -qF "[PASS] LoongArch frontend state contracts" "$SIM_LOG"; then
    echo "ERROR: LoongArch frontend state contract test did not report PASS"
    exit 1
fi
