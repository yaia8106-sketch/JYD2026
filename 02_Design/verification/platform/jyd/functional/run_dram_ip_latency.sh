#!/bin/bash
# Verify the generated DRAM IP contract used by DCache direct mode.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFICATION_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RISCV_TESTS_DIR="$VERIFICATION_DIR/riscv"
WORKSPACE="$(cd "$VERIFICATION_DIR/../.." && pwd)"
IP_DIR="$WORKSPACE/JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/ip/DRAM4MyOwn"
WORK_DIR="$RISCV_TESTS_DIR/work/dram_ip_latency"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/dram_ip_latency_simv"
COMPILE_LOG="$WORK_DIR/dram_ip_latency_vcs.log"
SIM_LOG="$WORK_DIR/dram_ip_latency_sim.log"

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

echo "[INFO] Compiling generated DRAM4MyOwn simulation model..."
if ! vcs $VCS_OPTS -top tb_dram_ip_latency \
    -Mdir="$WORK_DIR/dram_ip_latency_vcs.csrc" \
    -o "$SIM_BIN" \
    "$IP_DIR/simulation/blk_mem_gen_v8_4.v" \
    "$IP_DIR/sim/DRAM4MyOwn.v" \
    "$SCRIPT_DIR/../tb/tb_dram_ip_latency.sv" \
    "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -100 "$COMPILE_LOG"
    exit 1
fi

echo "[INFO] Running generated DRAM4MyOwn latency test..."
if ! (
    cd "$IP_DIR"
    "$SIM_BIN" >"$SIM_LOG" 2>&1
); then
    cat "$SIM_LOG"
    exit 1
fi
cat "$SIM_LOG"
grep -qF "[PASS] DRAM4MyOwn IP two-cycle latency and ENB behavior" "$SIM_LOG"
