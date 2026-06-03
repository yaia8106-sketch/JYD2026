#!/bin/bash
# ============================================================
# student_top COE runner
#
# Builds a student_top-level simulation and runs a banked COE program.
# Defaults to the current board target: dual_issue/new_with_Mext.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$WORKSPACE/02_Design/rtl"
CONTEST_RTL_DIR="$WORKSPACE/02_Design/contest_readonly/rtl"
WORK_DIR="$SCRIPT_DIR/work"
HEX_DIR="${HEX_DIR:-$WORK_DIR/hex}"
SIM_BIN="$WORK_DIR/student_top_coe_sim"

TEST_NAME="${1:-new_with_Mext}"
MAX_CYCLES="${MAX_CYCLES:-5000000}"
MAX_COMMITS="${MAX_COMMITS:-20000}"
WATCHDOG_CYCLES="${WATCHDOG_CYCLES:-150000}"
TRACE_FILE="${TRACE_FILE:-$WORK_DIR/${TEST_NAME}.student_top.trace.log}"
TRACE="${TRACE:-0}"
LED_TRACE="${LED_TRACE:-1}"

case "$TEST_NAME" in
    new_with_Mext)
        STOP_PC=80000014
        ;;
    new_without_Mext)
        STOP_PC=80000010
        ;;
    *)
        echo "ERROR: unknown COE test '$TEST_NAME' (supported: new_with_Mext, new_without_Mext)"
        exit 1
        ;;
esac

IROM_SLOT0="$HEX_DIR/${TEST_NAME}.irom_slot0.hex"
IROM_SLOT1="$HEX_DIR/${TEST_NAME}.irom_slot1.hex"
DRAM_HEX="$HEX_DIR/${TEST_NAME}.dram.hex"

for f in "$IROM_SLOT0" "$IROM_SLOT1" "$DRAM_HEX"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing hex input: $f"
        echo "       Set HEX_DIR=<dir> or generate the required student_top hex files under $HEX_DIR."
        exit 1
    fi
done

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
    $RTL_DIR/branch_condition.sv
    $RTL_DIR/id_stage_derive.sv
    $RTL_DIR/ex_stage_ctrl.sv
    $RTL_DIR/branch_unit.sv
    $RTL_DIR/branch_predictor.sv
    $RTL_DIR/frontend_ftq.sv
    $RTL_DIR/mem_interface.sv
    $RTL_DIR/redirect_ctrl.sv
    $RTL_DIR/csr_trap_unit.sv
    $RTL_DIR/memory_access_unit.sv
    $RTL_DIR/muldiv_unit.sv
    $RTL_DIR/dual_issue_counter.sv
    $RTL_DIR/dual_issue_decider.sv
    $RTL_DIR/if_stage_buffer.sv
    $RTL_DIR/irom_addr_ctrl.sv
    $RTL_DIR/ex_mem_reg.sv
    $RTL_DIR/ex_mem_reg_s1.sv
    $RTL_DIR/mem_wb_reg.sv
    $RTL_DIR/mem_wb_reg_s1.sv
    $RTL_DIR/wb_mux.sv
    $RTL_DIR/dcache.sv
    $RTL_DIR/cpu_top.sv
    $RTL_DIR/mmio_bridge.sv
    $RTL_DIR/student_top.sv
    $CONTEST_RTL_DIR/counter.sv
    $CONTEST_RTL_DIR/display_seg.sv
    $CONTEST_RTL_DIR/seg7.sv
    $SCRIPT_DIR/work/dcache_data_ram.v
    $SCRIPT_DIR/tb/student_top_ip_models.sv
    $SCRIPT_DIR/tb/tb_student_top_coe.sv
"

echo "[INFO] Compiling student_top COE simulator..."
# shellcheck disable=SC2086
iverilog -g2012 -o "$SIM_BIN" $RTL_FILES

echo "[INFO] Running $TEST_NAME through student_top..."
RUN_ARGS=(
    "+irom_slot0=$IROM_SLOT0" \
    "+irom_slot1=$IROM_SLOT1" \
    "+dram=$DRAM_HEX" \
    "+test=${TEST_NAME}_student_top" \
    "+cycles=$MAX_CYCLES" \
    "+commits=$MAX_COMMITS" \
    "+stop_pc=$STOP_PC" \
    "+watchdog=$WATCHDOG_CYCLES" \
    +pc_guard
)

if [ "$LED_TRACE" != "0" ]; then
    RUN_ARGS+=(+led_trace)
fi

if [ "$TRACE" != "0" ]; then
    RUN_ARGS+=(+trace "+trace_file=$TRACE_FILE")
fi

vvp -N "$SIM_BIN" "${RUN_ARGS[@]}"
