#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NSCSCC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$NSCSCC_DIR/../.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
WORK_ROOT="$(mktemp -d /tmp/nscscc_icache_configs.XXXXXX)"
trap 'rm -rf "$WORK_ROOT"' EXIT

for cache_bytes in 8192 16384 32768; do
    for ways in 1 2; do
        work_dir="$WORK_ROOT/${cache_bytes}_${ways}"
        mkdir -p "$work_dir"
        if ! vcs -full64 -sverilog -timescale=1ns/1ps \
            "+define+TEST_ICACHE_BYTES=$cache_bytes" \
            "+define+TEST_ICACHE_WAYS=$ways" \
            -top tb_icache_configurations \
            -Mdir="$work_dir/csrc" \
            -o "$work_dir/simv" \
            "$RTL_DIR/common/cpu_defs.sv" \
            "$RTL_DIR/isa/loongarch/loongarch_defs.sv" \
            "$RTL_DIR/isa/loongarch/loongarch_predecode.sv" \
            "$RTL_DIR/memory/icache.sv" \
            "$NSCSCC_DIR/tb/tb_icache_configurations.sv" \
            "$VCS_SHIM" >"$work_dir/compile.log" 2>&1; then
            echo "ERROR: ICache ${cache_bytes}B/${ways}-way compilation failed"
            tail -100 "$work_dir/compile.log"
            exit 1
        fi
        (cd "$work_dir" && ./simv)
    done
done
