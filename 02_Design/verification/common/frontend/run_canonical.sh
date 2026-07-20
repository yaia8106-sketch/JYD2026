#!/bin/bash
# frontend_ftq ABTB/PHT canonical steering VCS test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFICATION_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RISCV_TESTS_DIR="$VERIFICATION_DIR/riscv"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$RISCV_TESTS_DIR/work/frontend_ftq_canonical"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/frontend_ftq_canonical_simv"
COMPILE_LOG="$WORK_DIR/frontend_ftq_canonical_vcs.log"
SIM_LOG="$WORK_DIR/frontend_ftq_canonical_sim.log"
PASS_MARKER="[PASS] frontend FTQ canonical steering test"

mkdir -p "$WORK_DIR"
if ! command -v vcs >/dev/null 2>&1 && [ -f "$VCS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$VCS_ENV"
fi

if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS \
    -top tb_frontend_ftq_canonical \
    -Mdir="$WORK_DIR/frontend_ftq_canonical_vcs.csrc" \
    -o "$SIM_BIN" \
    "$RTL_DIR/common/cpu_defs.sv" \
    "$RTL_DIR/isa/riscv/riscv_defs.sv" \
    "$RTL_DIR/isa/riscv/riscv_predecode.sv" \
    "$RTL_DIR/core/frontend/frontend_f0_packet_builder.sv" \
    "$RTL_DIR/core/frontend/frontend_pair_policy.sv" \
    "$RTL_DIR/core/frontend/frontend_stage1_steer_ctrl.sv" \
    "$RTL_DIR/core/frontend/frontend_fetch_state.sv" \
    "$RTL_DIR/core/frontend/frontend_fetch_queue.sv" \
    "$RTL_DIR/core/frontend/frontend_abtb_sidecar.sv" \
    "$RTL_DIR/core/frontend/frontend_ftq.sv" \
    "$SCRIPT_DIR/tb_frontend_ftq_canonical.sv" \
    "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    head -160 "$COMPILE_LOG"
    exit 1
fi

if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
grep -qF "$PASS_MARKER" "$SIM_LOG"
