#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NSCSCC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$NSCSCC_DIR/../.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
WORK_DIR="$(mktemp -d /tmp/nscscc_variable_irom.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

vcs -full64 -sverilog -timescale=1ns/1ps \
    -top tb_variable_irom_frontend \
    -Mdir="$WORK_DIR/csrc" \
    -o "$WORK_DIR/simv" \
    -F "$RTL_DIR/filelists/loongarch_cpu.f" \
    "$NSCSCC_DIR/tb/tb_variable_irom_frontend.sv" \
    "$VCS_SHIM" >"$WORK_DIR/compile.log" 2>&1

(
    cd "$WORK_DIR"
    ./simv
)
