#!/bin/bash
# ============================================================
# student_top COE runner
#
# Builds a student_top-level simulation and runs a banked COE program.
# Defaults to the current board target: dual_issue/new_with_Mext.
# Normal completion is stop_pc only. Cycle timeout and commit stop are disabled
# by default so full contest programs are not truncated.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
RTL_DIR="$WORKSPACE/02_Design/rtl"
CONTEST_RTL_DIR="$WORKSPACE/02_Design/contest_readonly/rtl"
WORK_DIR="$SCRIPT_DIR/work"
COE_ROOT="${COE_ROOT:-$WORKSPACE/02_Design/coe/dual_issue}"
HEX_DIR="${HEX_DIR:-$WORK_DIR/coe_hex}"
SIM_BIN="$WORK_DIR/student_top_coe_sim"

TEST_NAME="${1:-new_with_Mext}"
MAX_CYCLES="${MAX_CYCLES:-5000000}"
MAX_COMMITS="${MAX_COMMITS:-0}"
CYCLE_TIMEOUT="${CYCLE_TIMEOUT:-0}"
WATCHDOG_CYCLES="${WATCHDOG_CYCLES:-150000}"
TRACE_FILE="${TRACE_FILE:-$WORK_DIR/${TEST_NAME}.student_top.trace.log}"
TRACE="${TRACE:-0}"
LED_TRACE="${LED_TRACE:-1}"

case "$TEST_NAME" in
    current|src0|src1|src2|new_without_Mext|new_with_Mext)
        ;;
    *)
        echo "ERROR: unknown COE test '$TEST_NAME' (supported: current, src0, src1, src2, new_without_Mext, new_with_Mext)"
        exit 1
        ;;
esac

IROM_SLOT0="$HEX_DIR/${TEST_NAME}.irom_slot0.hex"
IROM_SLOT1="$HEX_DIR/${TEST_NAME}.irom_slot1.hex"
DRAM_HEX="$HEX_DIR/${TEST_NAME}.dram.hex"

coe_to_hex() {
    local in_file="$1"
    local out_file="$2"
    awk '
        BEGIN { in_vec = 0 }
        /memory_initialization_vector/ { in_vec = 1; next }
        in_vec {
            gsub(/[ \t\r]/, "")
            sub(/;.*/, "")
            gsub(/,/, "")
            if ($0 != "") print tolower($0)
        }
    ' "$in_file" > "$out_file"
}

derive_stop_pc() {
    local slot0_hex="$1"
    local slot1_hex="$2"
    awk '
        FNR == NR {
            slot0[FNR] = tolower($0)
            if (FNR > n0) n0 = FNR
            next
        }
        {
            slot1[FNR] = tolower($0)
            if (FNR > n1) n1 = FNR
        }
        END {
            max = (n0 > n1) ? n0 : n1
            for (i = 1; i <= max; i++) {
                if (slot0[i] == "0000006f") {
                    printf "%08x\n", 2147483648 + ((i - 1) * 2) * 4
                    exit 0
                }
                if (slot1[i] == "0000006f") {
                    printf "%08x\n", 2147483648 + (((i - 1) * 2) + 1) * 4
                    exit 0
                }
            }
            exit 1
        }
    ' "$slot0_hex" "$slot1_hex"
}

mkdir -p "$WORK_DIR" "$HEX_DIR"

if [ ! -f "$IROM_SLOT0" ] || [ ! -f "$IROM_SLOT1" ] || [ ! -f "$DRAM_HEX" ]; then
    COE_DIR="$COE_ROOT/$TEST_NAME"
    for f in "$COE_DIR/irom_slot0.coe" "$COE_DIR/irom_slot1.coe" "$COE_DIR/dram.coe"; do
        if [ ! -f "$f" ]; then
            echo "ERROR: missing COE input: $f"
            exit 1
        fi
    done
    coe_to_hex "$COE_DIR/irom_slot0.coe" "$IROM_SLOT0"
    coe_to_hex "$COE_DIR/irom_slot1.coe" "$IROM_SLOT1"
    coe_to_hex "$COE_DIR/dram.coe" "$DRAM_HEX"
fi

for f in "$IROM_SLOT0" "$IROM_SLOT1" "$DRAM_HEX"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing hex input: $f"
        echo "       Set HEX_DIR=<dir> or generate the required student_top hex files under $HEX_DIR."
        exit 1
    fi
done

if ! STOP_PC="$(derive_stop_pc "$IROM_SLOT0" "$IROM_SLOT1")"; then
    echo "ERROR: cannot derive stop_pc from first self-loop in $IROM_SLOT0/$IROM_SLOT1"
    exit 1
fi

RTL_FILES="
    $RTL_DIR/cpu_defs.sv
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
echo "[INFO] stop_pc: 0x$STOP_PC"
RUN_ARGS=(
    "+irom_slot0=$IROM_SLOT0" \
    "+irom_slot1=$IROM_SLOT1" \
    "+dram=$DRAM_HEX" \
    "+test=${TEST_NAME}_student_top" \
    "+stop_pc=$STOP_PC" \
    "+watchdog=$WATCHDOG_CYCLES" \
    +pc_guard
)

if [ "$CYCLE_TIMEOUT" != "0" ]; then
    RUN_ARGS+=("+cycles=$MAX_CYCLES")
else
    RUN_ARGS+=(+no_cycle_timeout)
fi

if [ "$MAX_COMMITS" -gt 0 ]; then
    RUN_ARGS+=("+commits=$MAX_COMMITS")
fi

if [ "$LED_TRACE" != "0" ]; then
    RUN_ARGS+=(+led_trace)
fi

if [ "$TRACE" != "0" ]; then
    RUN_ARGS+=(+trace "+trace_file=$TRACE_FILE")
fi

vvp -N "$SIM_BIN" "${RUN_ARGS[@]}"
