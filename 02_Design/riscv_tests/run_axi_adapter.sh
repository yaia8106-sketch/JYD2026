#!/bin/bash
# ============================================================
# run_axi_adapter.sh - Standalone VCS smoke test for AXI adapter
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$SCRIPT_DIR/../rtl" && pwd)"
WORK_DIR="$SCRIPT_DIR/work/axi_adapter"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_SHIM="$SCRIPT_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/axi_adapter_simv"
COMPILE_LOG="$WORK_DIR/axi_adapter_vcs.log"

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

RTL_FILES="
    $RTL_DIR/axi_master_adapter.sv
    $RTL_DIR/dcache_axi_backend.sv
    $SCRIPT_DIR/tb/tb_axi_master_adapter.sv
"

echo "[INFO] Compiling AXI adapter smoke test with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_axi_master_adapter \
    -Mdir="$WORK_DIR/axi_adapter_vcs.csrc" \
    -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -80 "$COMPILE_LOG"
    exit 1
fi

head -20 "$COMPILE_LOG"
echo "[INFO] Running AXI adapter smoke test..."
"$SIM_BIN"
