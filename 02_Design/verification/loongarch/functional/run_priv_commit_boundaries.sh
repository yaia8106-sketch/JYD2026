#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOONGARCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$LOONGARCH_DIR/.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
WORK_DIR="$(mktemp -d /tmp/loongarch_priv_boundaries.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! command -v vcs >/dev/null 2>&1 && [ -f "$VCS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$VCS_ENV"
fi

vcs -full64 -sverilog -timescale=1ns/1ps \
    -top tb_loongarch_priv_commit_boundaries \
    -Mdir="$WORK_DIR/csrc" \
    -o "$WORK_DIR/simv" \
    "$RTL_DIR/common/cpu_defs.sv" \
    "$RTL_DIR/isa/loongarch/loongarch_priv_unit.sv" \
    "$LOONGARCH_DIR/tb/tb_loongarch_priv_commit_boundaries.sv" \
    "$VCS_SHIM" >"$WORK_DIR/compile.log" 2>&1

"$WORK_DIR/simv" >"$WORK_DIR/sim.log" 2>&1
cat "$WORK_DIR/sim.log"
grep -qF "[PASS] LoongArch privileged commit/alignment boundary test" \
    "$WORK_DIR/sim.log"
