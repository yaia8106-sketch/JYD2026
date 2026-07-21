#!/bin/bash
# Standalone VCS execution gate for the common cpu_top with the LA32R adapter.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOONGARCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$LOONGARCH_DIR/.." && pwd)"
RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
WORK_DIR="$LOONGARCH_DIR/work/cpu_smoke"
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

echo "[INFO] Compiling LoongArch cpu_top execution smoke test..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_loongarch_cpu_smoke \
    -Mdir="$WORK_DIR/vcs.csrc" \
    -o "$SIM_BIN" \
    -F "$RTL_DIR/filelists/loongarch_cpu.f" \
    "$RTL_DIR/core/cpu_top.sv" \
    "$LOONGARCH_DIR/tb/tb_loongarch_cpu_smoke.sv" \
    "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: LoongArch cpu_top smoke compilation failed"
    head -120 "$COMPILE_LOG"
    exit 1
fi
if grep -Eq 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' "$COMPILE_LOG"; then
    echo "ERROR: LoongArch cpu_top compilation reported a gated RTL/TB warning"
    grep -E 'Warning-\[(TFIPC|ENUMASSIGN|INCLFDV)\]' "$COMPILE_LOG"
    exit 1
fi

echo "[INFO] Running LoongArch cpu_top execution smoke test..."
if ! "$SIM_BIN" >"$SIM_LOG" 2>&1; then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
if ! grep -qF "[PASS] LoongArch cpu_top execution smoke test" \
    "$SIM_LOG"; then
    echo "ERROR: LoongArch cpu_top smoke test did not report PASS"
    exit 1
fi
