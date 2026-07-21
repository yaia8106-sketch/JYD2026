#!/bin/bash
# Standalone VCS gate for the LA32R ordinary-integer decode contract.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOONGARCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$LOONGARCH_DIR/.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$LOONGARCH_DIR/work/decode_contract"
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

echo "[INFO] Compiling LoongArch decoded-uop contract test with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_loongarch_decode_contract \
    -Mdir="$WORK_DIR/vcs.csrc" \
    -o "$SIM_BIN" \
    "$RTL_DIR/common/cpu_defs.sv" \
    "$RTL_DIR/isa/loongarch/loongarch_defs.sv" \
    "$RTL_DIR/isa/loongarch/loongarch_decoder.sv" \
    "$RTL_DIR/isa/loongarch/loongarch_predecode.sv" \
    "$RTL_DIR/core/execute/alu.sv" \
    "$LOONGARCH_DIR/tb/tb_loongarch_decode_contract.sv" \
    "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: LoongArch decoded-uop contract compilation failed"
    head -100 "$COMPILE_LOG"
    exit 1
fi
if grep -Eq 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' "$COMPILE_LOG"; then
    echo "ERROR: LoongArch decode compilation reported a gated RTL/TB warning"
    grep -E 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' "$COMPILE_LOG"
    exit 1
fi

echo "[INFO] Running LoongArch decoded-uop contract test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
if ! grep -qF "[PASS] LoongArch decoded-uop contract directed test" \
    "$SIM_LOG"; then
    echo "ERROR: LoongArch decoded-uop contract test did not report PASS"
    exit 1
fi

echo "[INFO] Running LoongArch F0/FTQ semantic metadata gate..."
bash "$SCRIPT_DIR/run_frontend_ftq.sh"

echo "[INFO] Running LoongArch cpu_top execution gate..."
bash "$SCRIPT_DIR/run_cpu_smoke.sh"
