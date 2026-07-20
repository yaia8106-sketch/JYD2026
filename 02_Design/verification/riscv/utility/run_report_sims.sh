#!/bin/bash
# ============================================================
# run_report_sims.sh - 报告补充仿真：应用程序波形
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(dirname "$SCRIPT_DIR")"
VERIFICATION_DIR="$(cd "$RISCV_TESTS_DIR/.." && pwd)"
cd "$RISCV_TESTS_DIR"

RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
HEX_DIR="$RISCV_TESTS_DIR/work/hex"
WORK_DIR="$RISCV_TESTS_DIR/work"
WAVE_DIR="$WORK_DIR/waveforms"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"

mkdir -p "$WAVE_DIR"

# ============================================================
# 应用程序仿真 (simple)
# ============================================================
APP_SIM_BIN="$WORK_DIR/riscv_tests_simv"
APP_COMPILE_LOG="$WORK_DIR/riscv_tests_simv_compile.log"

# Keep this source set aligned with functional/run_all.sh.  The report
# waveform uses the same cpu_top + BRAM DCache harness as the regression.
APP_RTL_FILES="
    -F $RTL_DIR/filelists/cpu_blocks.f
    -F $RTL_DIR/filelists/dcache_bram.f
    $RTL_DIR/core/cpu_top.sv
    $RISCV_TESTS_DIR/work/dcache_data_ram.v
    $RISCV_TESTS_DIR/tb/perf_monitor.sv
    $RISCV_TESTS_DIR/tb/tb_riscv_tests.sv
"

echo ""
echo "[1/1] Compiling riscv_tests for application..."
if ! vcs $VCS_OPTS -top tb_riscv_tests \
    -Mdir="$WORK_DIR/riscv_tests_simv.csrc" \
    -o "$APP_SIM_BIN" $APP_RTL_FILES "$VCS_SHIM" >"$APP_COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -60 "$APP_COMPILE_LOG"
    exit 1
fi
echo "  Compilation OK"

echo ""
echo "  Running simple (application) with VCD dump..."
result=$("$APP_SIM_BIN" \
    "+irom=$HEX_DIR/rv32ui-p-simple.irom.hex" \
    "+dram=$HEX_DIR/rv32ui-p-simple.dram.hex" \
    "+test=simple" "+cycles=100000" "+pc_guard" "+watchdog=10000" \
    "+dump" "+dump_file=$WAVE_DIR/simple.vcd" \
    2>&1 | grep -E "^\[(PASS|FAIL|VCD|TIMEOUT)\]" | head -3)
echo "  $result"

echo ""
echo "========================================================"
echo " VCD files:"
ls -lh "$WAVE_DIR"/simple.vcd 2>/dev/null
echo " 打开应用波形:"
echo "   cd $WAVE_DIR && gtkwave simple.vcd &"
echo "========================================================"
