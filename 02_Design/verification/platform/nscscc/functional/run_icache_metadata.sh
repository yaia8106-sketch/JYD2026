#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NSCSCC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$NSCSCC_DIR/../.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
WORK_DIR="$(mktemp -d /tmp/nscscc_icache_metadata.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! vcs -full64 -sverilog -timescale=1ns/1ps \
    -top tb_icache_metadata \
    -Mdir="$WORK_DIR/csrc" \
    -o "$WORK_DIR/simv" \
    "$RTL_DIR/common/cpu_defs.sv" \
    "$RTL_DIR/isa/loongarch/loongarch_defs.sv" \
    "$RTL_DIR/isa/loongarch/loongarch_predecode.sv" \
    "$RTL_DIR/memory/icache_refill_ctrl.sv" \
    "$RTL_DIR/memory/icache.sv" \
    "$NSCSCC_DIR/tb/tb_icache_metadata.sv" \
    "$VCS_SHIM" >"$WORK_DIR/compile.log" 2>&1; then
    echo "ERROR: ICache metadata test compilation failed"
    head -100 "$WORK_DIR/compile.log"
    exit 1
fi

if grep -Eq 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' \
    "$WORK_DIR/compile.log"; then
    echo "ERROR: ICache metadata compilation reported a gated RTL/TB warning"
    grep -E 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' \
        "$WORK_DIR/compile.log"
    exit 1
fi

(
    cd "$WORK_DIR"
    ./simv
)
