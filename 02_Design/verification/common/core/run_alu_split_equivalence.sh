#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFICATION_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
WORK_DIR="$(mktemp -d /tmp/alu_split_equivalence.XXXXXX)"
SEEDS="${ALU_SPLIT_SEEDS:-3 31 20260801}"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! command -v vcs >/dev/null 2>&1 && [ -f "$VCS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$VCS_ENV"
fi
if ! command -v vcs >/dev/null 2>&1; then
    echo "ERROR: vcs not found in PATH. Source Synopsys env or set VCS_ENV=<setup.sh>."
    exit 1
fi

vcs -full64 -sverilog -timescale=1ns/1ps \
    -top tb_alu_split_equivalence \
    -Mdir="$WORK_DIR/csrc" \
    -o "$WORK_DIR/simv" \
    "$RTL_DIR/common/cpu_defs.sv" \
    "$RTL_DIR/core/execute/alu.sv" \
    "$SCRIPT_DIR/tb_alu_split_equivalence.sv" \
    "$VCS_SHIM" >"$WORK_DIR/compile.log" 2>&1

for seed in $SEEDS; do
    echo "[INFO] Running split ALU semantic/equivalence test seed=$seed..."
    "$WORK_DIR/simv" "+seed=$seed" >"$WORK_DIR/sim_${seed}.log" 2>&1
    cat "$WORK_DIR/sim_${seed}.log"
    grep -qF "[PASS] split ALU semantic/equivalence test" \
        "$WORK_DIR/sim_${seed}.log"
done
