#!/bin/bash
# ============================================================
# run_student_top_smoke.sh - student_top board-wrapper smoke tests
#
# Classification:
#   Functional correctness / special smoke.
#   This is intentionally outside run_all.sh because it validates the
#   student_top wrapper, MMIO bridge, and behavioral IP-model wiring.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$RISCV_TESTS_DIR"

RTL_DIR="$(cd "$RISCV_TESTS_DIR/../rtl" && pwd)"
CONTEST_RTL_DIR="$(cd "$RISCV_TESTS_DIR/../contest_readonly/rtl" && pwd)"
HEX_DIR="${HEX_DIR:-$RISCV_TESTS_DIR/work/hex}"
WORK_DIR="$RISCV_TESTS_DIR/work"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/student_top_smoke_simv"
COMPILE_LOG="$WORK_DIR/student_top_smoke_vcs.log"
MAX_CYCLES="${MAX_CYCLES:-50000}"
WATCHDOG_CYCLES="${WATCHDOG_CYCLES:-5000}"

TESTS=("$@")
if [ "${#TESTS[@]}" -eq 0 ]; then
    TESTS=(simple dcache_stress)
fi

mkdir -p "$WORK_DIR"

if [ ! -d "$HEX_DIR" ] || [ -z "$(ls "$HEX_DIR"/*.irom.hex 2>/dev/null)" ]; then
    echo "ERROR: hex not found. Run: bash utility/build_tests.sh"
    exit 1
fi

RTL_FILES="
    $RTL_DIR/common/cpu_defs.sv
    $RTL_DIR/core/if_id_reg.sv
    $RTL_DIR/core/decoder.sv
    $RTL_DIR/core/imm_gen.sv
    $RTL_DIR/core/regfile.sv
    $RTL_DIR/core/forwarding.sv
    $RTL_DIR/core/alu_src_mux.sv
    $RTL_DIR/core/id_ex_reg.sv
    $RTL_DIR/core/id_ex_reg_s1.sv
    $RTL_DIR/core/alu.sv
    $RTL_DIR/core/branch_condition.sv
    $RTL_DIR/core/id_stage_derive.sv
    $RTL_DIR/core/ex_stage_ctrl.sv
    $RTL_DIR/core/branch_unit.sv
    $RTL_DIR/core/branch_predictor.sv
    $RTL_DIR/core/frontend_ftq.sv
    $RTL_DIR/core/mem_interface.sv
    $RTL_DIR/core/redirect_ctrl.sv
    $RTL_DIR/core/csr_trap_unit.sv
    $RTL_DIR/core/memory_access_unit.sv
    $RTL_DIR/core/muldiv_unit.sv
    $RTL_DIR/core/dual_issue_counter.sv
    $RTL_DIR/core/ex_mem_reg.sv
    $RTL_DIR/core/ex_mem_reg_s1.sv
    $RTL_DIR/core/mem_wb_reg.sv
    $RTL_DIR/core/mem_wb_reg_s1.sv
    $RTL_DIR/core/wb_mux.sv
    $RTL_DIR/memory/dcache.sv
    $RTL_DIR/memory/backends/dcache_bram_backend.sv
    $RTL_DIR/core/cpu_top.sv
    $RTL_DIR/mmio/mmio_bridge.sv
    $RTL_DIR/top/student_top.sv
    $CONTEST_RTL_DIR/counter.sv
    $CONTEST_RTL_DIR/display_seg.sv
    $CONTEST_RTL_DIR/seg7.sv
    $RISCV_TESTS_DIR/work/dcache_data_ram.v
    $RISCV_TESTS_DIR/tb/student_top_ip_models.sv
    $RISCV_TESTS_DIR/tb/tb_student_top_smoke.sv
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

echo "[INFO] Compiling student_top smoke with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_student_top_smoke \
    -Mdir="$WORK_DIR/student_top_smoke_vcs.csrc" \
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
        "+cycles=$MAX_CYCLES" "+watchdog=$WATCHDOG_CYCLES" +pc_guard \
        2>&1 | grep -E "^\[(PASS|FAIL|TIMEOUT)\]" | head -1)

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
echo " student_top smoke Results: $PASSED/$TOTAL passed"
echo "========================================================"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
