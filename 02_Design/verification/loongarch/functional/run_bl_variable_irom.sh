#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOONGARCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$LOONGARCH_DIR/.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$LOONGARCH_DIR/work/bl_variable_irom"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"

mkdir -p "$WORK_DIR"
if ! command -v vcs >/dev/null 2>&1; then
    source /home/anokyai/synopsys/env.sh
fi

vcs -full64 -sverilog -timescale=1ns/1ps \
    -top tb_loongarch_bl_variable_irom \
    -Mdir="$WORK_DIR/vcs.csrc" \
    -o "$WORK_DIR/simv" \
    -F "$RTL_DIR/filelists/loongarch_cpu.f" \
    "$RTL_DIR/core/cpu_top.sv" \
    "$LOONGARCH_DIR/tb/tb_loongarch_bl_variable_irom.sv" \
    "$VCS_SHIM" >"$WORK_DIR/compile.log" 2>&1

"$WORK_DIR/simv"
