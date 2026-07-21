#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NSCSCC_VERIFY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$NSCSCC_VERIFY_DIR/../.." && pwd)"
PLATFORM_DIR="$(cd "$VERIFICATION_DIR/../platform/nscscc" && pwd)"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
WORK_DIR="$(mktemp -d /tmp/nscscc_core_compile.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

(
    cd "$PLATFORM_DIR"
    vcs -full64 -sverilog -timescale=1ns/1ps \
        -top core_top \
        -Mdir="$WORK_DIR/csrc_single" \
        -o "$WORK_DIR/simv_single" \
        -F filelist.f "$VCS_SHIM" >"$WORK_DIR/compile_single.log" 2>&1

    vcs -full64 -sverilog -timescale=1ns/1ps \
        +define+CPU_2CMT \
        -top core_top \
        -Mdir="$WORK_DIR/csrc_dual" \
        -o "$WORK_DIR/simv_dual" \
        -F filelist.f "$VCS_SHIM" >"$WORK_DIR/compile_dual.log" 2>&1
)

echo "[PASS] NSCSCC LoongArch core_top elaboration (single and CPU_2CMT)"
