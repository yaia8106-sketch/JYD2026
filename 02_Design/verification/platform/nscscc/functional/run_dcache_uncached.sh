#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NSCSCC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$NSCSCC_DIR/../.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
PLATFORM_RTL_DIR="$(cd "$VERIFICATION_DIR/../platform/nscscc/rtl" && pwd)"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
WORK_DIR="$(mktemp -d /tmp/nscscc_dcache_uncached.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

vcs -full64 -sverilog -timescale=1ns/1ps \
    -top tb_dcache_uncached \
    -Mdir="$WORK_DIR/csrc" \
    -o "$WORK_DIR/simv" \
    "$RTL_DIR/memory/dcache_store_buffer.sv" \
    "$RTL_DIR/memory/dcache.sv" \
    "$PLATFORM_RTL_DIR/dcache_data_ram.sv" \
    "$NSCSCC_DIR/tb/tb_dcache_uncached.sv" \
    "$VCS_SHIM" >"$WORK_DIR/compile.log" 2>&1

(
    cd "$WORK_DIR"
    ./simv
)
