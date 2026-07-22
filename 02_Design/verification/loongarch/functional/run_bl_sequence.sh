#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_DIR="$ROOT_DIR/verification/loongarch/work/bl_sequence"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if ! command -v vcs >/dev/null 2>&1; then
  source /home/anokyai/synopsys/env.sh
fi

vcs -full64 -sverilog -timescale=1ns/1ps \
  -top tb_loongarch_bl_sequence \
  -Mdir="$WORK_DIR/vcs.csrc" \
  -o "$WORK_DIR/simv" \
  -F "$ROOT_DIR/rtl/filelists/loongarch_cpu.f" \
  "$ROOT_DIR/rtl/core/cpu_top.sv" \
  "$ROOT_DIR/verification/loongarch/tb/tb_loongarch_bl_sequence.sv" \
  "$ROOT_DIR/verification/tools/vcs_pthread_yield.c" \
  >"$WORK_DIR/compile.log" 2>&1

"$WORK_DIR/simv"
