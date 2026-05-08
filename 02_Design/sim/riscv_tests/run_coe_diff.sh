#!/bin/bash
# ============================================================
# run_coe_diff.sh - Differential-check COE programs.
#
# This runs a small RV32I software reference on the single_issue COE
# image, runs RTL until the same commit budget, and compares committed
# PC + architectural writeback effects.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RTL_DIR="$(cd "$SIM_DIR/../rtl" && pwd)"
COE_DIR="$WORKSPACE/02_Design/coe/single_issue"
WORK_DIR="$SCRIPT_DIR/work"
SIM_BIN="$WORK_DIR/coe_diff_sim"
COMMITS="${COMMITS:-2000}"
MAX_CYCLES="${MAX_CYCLES:-200000}"
WATCHDOG_CYCLES="${WATCHDOG_CYCLES:-50000}"
PROGRAMS="${*:-current src0 src1 src2}"

cd "$SCRIPT_DIR"
mkdir -p "$WORK_DIR"

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

echo "========================================================"
echo " COE differential trace"
echo " Programs:  $PROGRAMS"
echo " Commits:   $COMMITS"
echo " Cycles:    $MAX_CYCLES"
echo " Watchdog:  $WATCHDOG_CYCLES idle cycles"
echo "========================================================"

echo "[INFO] Compiling with iverilog..."
# shellcheck disable=SC2086
iverilog -g2012 -o "$SIM_BIN" $RTL_FILES 2>&1 | head -30
echo "[INFO] Compilation OK"
echo ""

total=0
passed=0
failed=0

for prog in $PROGRAMS; do
    total=$((total + 1))
    src_dir="$COE_DIR/$prog"
    ref_trace="$WORK_DIR/${prog}.ref.trace"
    rtl_trace_rel="work/${prog}.rtl.trace"
    rtl_trace="$WORK_DIR/${prog}.rtl.trace"
    sim_log="$WORK_DIR/${prog}.diff.sim.log"
    irom_hex_rel="work/coe_hex/$prog.irom.hex"
    dram_hex_rel="work/coe_hex/$prog.dram.hex"

    mkdir -p "$WORK_DIR/coe_hex"
    python3 "$SCRIPT_DIR/coe_to_hex.py" "$src_dir/irom.coe" "$WORK_DIR/coe_hex/$prog.irom.hex" >/dev/null
    python3 "$SCRIPT_DIR/coe_to_hex.py" "$src_dir/dram.coe" "$WORK_DIR/coe_hex/$prog.dram.hex" >/dev/null
    python3 "$SCRIPT_DIR/rv32i_ref.py" \
        --irom-coe "$src_dir/irom.coe" \
        --dram-coe "$src_dir/dram.coe" \
        --commits "$COMMITS" \
        --trace "$ref_trace" >/dev/null

    sim_output=$(vvp -N "$SIM_BIN" \
        "+irom=$irom_hex_rel" \
        "+dram=$dram_hex_rel" \
        "+test=coe_diff_$prog" \
        "+cycles=$MAX_CYCLES" \
        "+commits=$COMMITS" \
        "+watchdog=$WATCHDOG_CYCLES" \
        "+pc_guard" \
        "+trace" "+trace_file=$rtl_trace_rel" \
        2>&1 | tee "$sim_log" || true)
    status=$(printf "%s\n" "$sim_output" | grep -E "^\[(DONE|PASS|FAIL|TIMEOUT)\]" | head -1 || true)

    if echo "$status" | grep -q "\[FAIL\]\|\[TIMEOUT\]"; then
        printf "  %-10s FAIL    %s\n" "$prog" "$status"
        failed=$((failed + 1))
        continue
    fi

    if python3 "$SCRIPT_DIR/compare_commit_trace.py" "$ref_trace" "$rtl_trace" \
        --commits "$COMMITS" --name "$prog"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

echo ""
echo "========================================================"
echo " Results: $passed/$total passed"
echo "   PASS: $passed"
echo "   FAIL: $failed"
echo " Logs:  $WORK_DIR/*.diff.sim.log"
echo "========================================================"

[ "$failed" -eq 0 ]
