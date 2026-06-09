#!/bin/bash
# ============================================================
# run_student_top_axi.sh - student_top_axi AXI integration smoke tests
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RTL_DIR="$(cd "$SCRIPT_DIR/../rtl" && pwd)"
CONTEST_RTL_DIR="$(cd "$SCRIPT_DIR/../contest_readonly/rtl" && pwd)"
HEX_DIR="${HEX_DIR:-work/hex}"
WORK_DIR="work"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$SCRIPT_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/student_top_axi_simv"
COMPILE_LOG="$WORK_DIR/student_top_axi_vcs.log"
MAX_CYCLES="${MAX_CYCLES:-50000}"

TESTS=("$@")
if [ "${#TESTS[@]}" -eq 0 ]; then
    TESTS=(axi_backend_stress dcache_stress sb_stress slot1_store)
fi

mkdir -p "$WORK_DIR"

if [ ! -d "$HEX_DIR" ] || [ -z "$(ls "$HEX_DIR"/*.irom.hex 2>/dev/null)" ]; then
    echo "ERROR: hex not found. Run: bash build_tests.sh"
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
    $RTL_DIR/axi_master_adapter.sv
    $RTL_DIR/dcache_axi_backend.sv
    $RTL_DIR/dcache.sv
    $RTL_DIR/cpu_top.sv
    $RTL_DIR/mmio_bridge.sv
    $RTL_DIR/student_top_axi.sv
    $CONTEST_RTL_DIR/counter.sv
    $CONTEST_RTL_DIR/display_seg.sv
    $CONTEST_RTL_DIR/seg7.sv
    $SCRIPT_DIR/work/dcache_data_ram.v
    $SCRIPT_DIR/tb/student_top_ip_models.sv
    $SCRIPT_DIR/tb/axi_ram_model.sv
    $SCRIPT_DIR/tb/tb_student_top_axi.sv
"

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

echo "[INFO] Compiling student_top_axi with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_student_top_axi \
    -Mdir="$WORK_DIR/student_top_axi_vcs.csrc" \
    -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -100 "$COMPILE_LOG"
    exit 1
fi

head -20 "$COMPILE_LOG"
echo "[INFO] Compilation OK"
echo ""

TOTAL=0
PASSED=0
FAILED=0

for test_name in "${TESTS[@]}"; do
    irom_hex="$HEX_DIR/rv32ui-p-${test_name}.irom.hex"
    dram_hex="$HEX_DIR/rv32ui-p-${test_name}.dram.hex"

    if [ ! -f "$irom_hex" ] || [ ! -f "$dram_hex" ]; then
        printf "  %-20s [SKIP] hex not found\n" "$test_name"
        continue
    fi

    TOTAL=$((TOTAL + 1))
    result=$("$SIM_BIN" \
        "+irom=$irom_hex" "+dram=$dram_hex" "+test=$test_name" \
        "+cycles=$MAX_CYCLES" 2>&1 | grep -E "^\[(PASS|FAIL|TIMEOUT)\]" | head -1)

    if echo "$result" | grep -q "^\[PASS\]"; then
        printf "  %-20s PASS  %s\n" "$test_name" "$result"
        PASSED=$((PASSED + 1))
    else
        printf "  %-20s FAIL  %s\n" "$test_name" "$result"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "========================================================"
echo " student_top_axi Results: $PASSED/$TOTAL passed"
echo "========================================================"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
