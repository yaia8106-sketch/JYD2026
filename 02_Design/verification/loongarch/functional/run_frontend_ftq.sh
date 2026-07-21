#!/bin/bash
# Standalone VCS gate for LoongArch F0 -> FTQ -> IF/ID semantic metadata.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOONGARCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$LOONGARCH_DIR/.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$LOONGARCH_DIR/work/frontend_ftq"
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

RTL_FILES="
    $RTL_DIR/common/cpu_defs.sv
    $RTL_DIR/isa/loongarch/loongarch_defs.sv
    $RTL_DIR/isa/loongarch/loongarch_predecode.sv
    $RTL_DIR/core/frontend/frontend_f0_packet_builder.sv
    $RTL_DIR/core/frontend/frontend_pair_policy.sv
    $RTL_DIR/core/frontend/frontend_stage1_steer_ctrl.sv
    $RTL_DIR/core/frontend/frontend_fetch_state.sv
    $RTL_DIR/core/frontend/frontend_fetch_queue.sv
    $RTL_DIR/core/frontend/frontend_abtb_sidecar.sv
    $RTL_DIR/core/frontend/frontend_ftq.sv
    $LOONGARCH_DIR/tb/tb_loongarch_frontend_ftq.sv
"

echo "[INFO] Compiling LoongArch frontend FTQ semantic/pairing test..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_loongarch_frontend_ftq \
    -Mdir="$WORK_DIR/vcs.csrc" \
    -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: LoongArch frontend FTQ compilation failed"
    head -100 "$COMPILE_LOG"
    exit 1
fi
if grep -Eq 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' "$COMPILE_LOG"; then
    echo "ERROR: LoongArch frontend compilation reported a gated RTL/TB warning"
    grep -E 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' "$COMPILE_LOG"
    exit 1
fi

echo "[INFO] Running LoongArch frontend FTQ semantic/pairing test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
if ! grep -qF "[PASS] LoongArch frontend FTQ semantic/pairing test" \
    "$SIM_LOG"; then
    echo "ERROR: LoongArch frontend FTQ test did not report PASS"
    exit 1
fi
