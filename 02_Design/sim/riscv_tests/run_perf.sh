#!/bin/bash
# ============================================================
# run_perf.sh - Run performance profiling on riscv-tests
#
# Usage:
#   ./run_perf.sh              # Profile all tests
#   ./run_perf.sh add sub lw   # Profile specific tests
#
# Output: [PERF] tagged lines with CPI, dual-issue rate, stall
#         breakdown, branch stats, and forwarding distribution.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SIM_DIR="$(cd ".." && pwd)"
RTL_DIR="$(cd "$SIM_DIR/../rtl" && pwd)"
HEX_DIR="work/hex"
WORK_DIR="work"

RTL_FILES="
    $RTL_DIR/cpu_defs.sv
    $RTL_DIR/pc_reg.sv
    $RTL_DIR/next_pc_mux.sv
    $RTL_DIR/if_id_reg.sv
    $RTL_DIR/decoder.sv
    $RTL_DIR/imm_gen.sv
    $RTL_DIR/regfile.sv
    $RTL_DIR/forwarding.sv
    $RTL_DIR/alu_src_mux.sv
    $RTL_DIR/id_ex_reg.sv
    $RTL_DIR/id_ex_reg_s1.sv
    $RTL_DIR/alu.sv
    $RTL_DIR/branch_unit.sv
    $RTL_DIR/branch_predictor.sv
    $RTL_DIR/mem_interface.sv
    $RTL_DIR/ex_mem_reg.sv
    $RTL_DIR/ex_mem_reg_s1.sv
    $RTL_DIR/mem_wb_reg.sv
    $RTL_DIR/mem_wb_reg_s1.sv
    $RTL_DIR/wb_mux.sv
    $RTL_DIR/dcache.sv
    $RTL_DIR/cpu_top.sv
    $SCRIPT_DIR/work/dcache_data_ram.v
    $SCRIPT_DIR/perf_monitor.sv
    $SCRIPT_DIR/tb_riscv_tests.sv
"

# Tests to profile (longer programs give more meaningful data)
if [ $# -gt 0 ]; then
    TESTS="$*"
else
    TESTS="bp_stress dcache_stress counter_stress sb_stress"
fi

# Check hex files
if [ ! -d "$HEX_DIR" ] || [ -z "$(ls $HEX_DIR/*.irom.hex 2>/dev/null)" ]; then
    echo "ERROR: hex not found. Run: bash build_tests.sh"
    exit 1
fi

# Compile
echo "[INFO] Compiling with iverilog..."
SIM_BIN="$WORK_DIR/riscv_perf_sim"
# shellcheck disable=SC2086
iverilog -g2012 -o "$SIM_BIN" $RTL_FILES 2>&1 | head -20
echo "[INFO] Compilation OK"
echo ""

# Run each test with +perf
for test_name in $TESTS; do
    irom_hex="$HEX_DIR/rv32ui-p-${test_name}.irom.hex"
    dram_hex="$HEX_DIR/rv32ui-p-${test_name}.dram.hex"

    if [ ! -f "$irom_hex" ] || [ ! -f "$dram_hex" ]; then
        echo "  [$test_name] SKIP - hex not found"
        continue
    fi

    echo "========================================================"
    echo " Profiling: $test_name"
    echo "========================================================"

    vvp -N "$SIM_BIN" \
        "+irom=$irom_hex" "+dram=$dram_hex" "+test=$test_name" \
        "+cycles=200000" "+perf" 2>&1 | grep -E "^\[(PASS|FAIL|TIMEOUT|PERF)\]"

    echo ""
done

echo "Done."
