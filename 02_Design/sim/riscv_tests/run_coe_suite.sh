#!/bin/bash
# ============================================================
# run_coe_suite.sh - Run contest COE programs in the CPU testbench.
#
# The board project consumes Vivado .coe files, while tb_riscv_tests
# consumes one-word-per-line hex files.  This script converts the
# single_issue COE set and runs current/src0/src1/src2 with the same
# direct cpu_top + dcache simulation used by run_all.sh.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RTL_DIR="$(cd "$SIM_DIR/../rtl" && pwd)"
COE_DIR="$WORKSPACE/02_Design/coe/single_issue"
WORK_DIR="$SCRIPT_DIR/work"
HEX_DIR="$WORK_DIR/coe_hex"
SIM_BIN="$WORK_DIR/coe_suite_sim"
MAX_CYCLES="${MAX_CYCLES:-2000000}"
WATCHDOG_CYCLES="${WATCHDOG_CYCLES:-200000}"
TRACE="${TRACE:-0}"

PROGRAMS="${*:-current src0 src1 src2}"

cd "$SCRIPT_DIR"

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

mkdir -p "$WORK_DIR" "$HEX_DIR"

echo "========================================================"
echo " COE suite"
echo " COE:       $COE_DIR"
echo " Programs:  $PROGRAMS"
echo " Cycles:    $MAX_CYCLES"
echo " Watchdog:  $WATCHDOG_CYCLES idle cycles"
echo " Trace:     $TRACE"
echo "========================================================"

for prog in $PROGRAMS; do
    src_dir="$COE_DIR/$prog"
    if [ ! -f "$src_dir/irom.coe" ] || [ ! -f "$src_dir/dram.coe" ]; then
        echo "ERROR: missing COE pair for $prog in $src_dir"
        exit 1
    fi
    python3 "$SCRIPT_DIR/coe_to_hex.py" "$src_dir/irom.coe" "$HEX_DIR/$prog.irom.hex" >/dev/null
    python3 "$SCRIPT_DIR/coe_to_hex.py" "$src_dir/dram.coe" "$HEX_DIR/$prog.dram.hex" >/dev/null
done

echo "[INFO] Compiling with iverilog..."
# shellcheck disable=SC2086
iverilog -g2012 -o "$SIM_BIN" $RTL_FILES 2>&1 | head -30
echo "[INFO] Compilation OK"
echo ""

total=0
passed=0
failed=0
timeout=0
errors=""

for prog in $PROGRAMS; do
    total=$((total + 1))
    irom_hex_rel="work/coe_hex/$prog.irom.hex"
    dram_hex_rel="work/coe_hex/$prog.dram.hex"
    trace_file_rel="work/${prog}.trace.log"
    trace_args=()
    if [ "$TRACE" = "1" ]; then
        trace_args=("+trace" "+trace_file=$trace_file_rel")
    fi
    sim_output=$(vvp -N "$SIM_BIN" \
        "+irom=$irom_hex_rel" \
        "+dram=$dram_hex_rel" \
        "+test=coe_$prog" \
        "+cycles=$MAX_CYCLES" \
        "+watchdog=$WATCHDOG_CYCLES" \
        "+pc_guard" \
        "${trace_args[@]}" \
        2>&1 | tee "$WORK_DIR/${prog}.sim.log" || true)
    result=$(printf "%s\n" "$sim_output" | grep -E "^\[(PASS|FAIL|TIMEOUT)\]" | head -1 || true)

    if echo "$result" | grep -q "\[PASS\]"; then
        if [ "$TRACE" = "1" ]; then
            printf "  %-10s PASS    trace=%s\n" "$prog" "$trace_file_rel"
        else
            printf "  %-10s PASS\n" "$prog"
        fi
        passed=$((passed + 1))
    elif echo "$result" | grep -q "\[FAIL\]"; then
        printf "  %-10s FAIL    %s\n" "$prog" "$result"
        failed=$((failed + 1))
        errors="$errors  $result\n"
    else
        printf "  %-10s TIMEOUT %s\n" "$prog" "$result"
        timeout=$((timeout + 1))
        errors="$errors  [TIMEOUT] $prog: $result\n"
    fi
done

echo ""
echo "========================================================"
echo " Results: $passed/$total passed"
echo "   PASS:    $passed"
echo "   FAIL:    $failed"
echo "   TIMEOUT: $timeout"
echo " Logs:     $WORK_DIR/*.sim.log"
echo " Traces:   $WORK_DIR/*.trace.log"
echo "========================================================"

if [ -n "$errors" ]; then
    echo ""
    echo "Failed programs:"
    printf "%b" "$errors"
fi

[ "$failed" -eq 0 ] && [ "$timeout" -eq 0 ]
