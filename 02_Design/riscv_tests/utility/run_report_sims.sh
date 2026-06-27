#!/bin/bash
# ============================================================
# run_report_sims.sh - 报告补充仿真：AXI + 应用程序
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(dirname "$SCRIPT_DIR")"
cd "$RISCV_TESTS_DIR"

RTL_DIR="$(cd "$RISCV_TESTS_DIR/../rtl" && pwd)"
CONTEST_RTL_DIR="$(cd "$RISCV_TESTS_DIR/../contest_readonly/rtl" && pwd)"
HEX_DIR="$RISCV_TESTS_DIR/work/hex"
WORK_DIR="$RISCV_TESTS_DIR/work"
WAVE_DIR="$WORK_DIR/waveforms"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"

mkdir -p "$WAVE_DIR"

# ============================================================
# 1. AXI 仿真 (student_top_axi + VCD dump)
# ============================================================
AXI_SIM_BIN="$WORK_DIR/student_top_axi_simv"
AXI_COMPILE_LOG="$WORK_DIR/student_top_axi_vcs.log"

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
    $RTL_DIR/core/frontend_stage1_direction.sv
    $RTL_DIR/core/frontend_abtb.sv
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
    $RTL_DIR/bus/axi/axi_master_adapter.sv
    $RTL_DIR/memory/backends/dcache_axi_backend.sv
    $RTL_DIR/memory/dcache.sv
    $RTL_DIR/core/cpu_top.sv
    $RTL_DIR/mmio/mmio_bridge.sv
    $RTL_DIR/top/student_top_axi.sv
    $CONTEST_RTL_DIR/counter.sv
    $CONTEST_RTL_DIR/display_seg.sv
    $CONTEST_RTL_DIR/seg7.sv
    $RISCV_TESTS_DIR/work/dcache_data_ram.v
    $RISCV_TESTS_DIR/tb/student_top_ip_models.sv
    $RISCV_TESTS_DIR/tb/axi_ram_model.sv
    $RISCV_TESTS_DIR/tb/tb_student_top_axi.sv
"

echo "[1/2] Compiling student_top_axi with VCD support..."
if ! vcs $VCS_OPTS -top tb_student_top_axi \
    -Mdir="$WORK_DIR/student_top_axi_vcs.csrc" \
    -o "$AXI_SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$AXI_COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -60 "$AXI_COMPILE_LOG"
    exit 1
fi
echo "  Compilation OK"

echo ""
echo "  Running axi_backend_stress with VCD dump..."
result=$("$AXI_SIM_BIN" \
    "+irom=$HEX_DIR/rv32ui-p-axi_backend_stress.irom.hex" \
    "+dram=$HEX_DIR/rv32ui-p-axi_backend_stress.dram.hex" \
    "+test=axi_backend_stress" "+cycles=50000" \
    "+dump" "+dump_file=$WAVE_DIR/axi_backend_stress.vcd" \
    2>&1 | grep -E "^\[(PASS|FAIL|VCD|TIMEOUT)\]" | head -3)
echo "  $result"

# ============================================================
# 2. 应用程序仿真 (simple)
# ============================================================
APP_SIM_BIN="$WORK_DIR/riscv_tests_simv"
VCS_APP_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
APP_COMPILE_LOG="$WORK_DIR/riscv_tests_simv_compile.log"

APP_RTL_FILES="
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
    $RTL_DIR/core/frontend_stage1_direction.sv
    $RTL_DIR/core/frontend_abtb.sv
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
    $RISCV_TESTS_DIR/tb/student_top_simple_dram.sv
    $RISCV_TESTS_DIR/tb/perf_monitor.sv
    $RISCV_TESTS_DIR/tb/tb_riscv_tests.sv
"

echo ""
echo "[2/2] Compiling riscv_tests for application..."
if ! vcs $VCS_OPTS -top tb_riscv_tests \
    -Mdir="$WORK_DIR/riscv_tests_simv.csrc" \
    -o "$APP_SIM_BIN" $APP_RTL_FILES "$VCS_APP_SHIM" >"$APP_COMPILE_LOG" 2>&1; then
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
ls -lh "$WAVE_DIR"/axi_backend_stress.vcd "$WAVE_DIR"/simple.vcd 2>/dev/null
echo ""
echo " 打开 AXI 波形:"
echo "   cd $WAVE_DIR && gtkwave axi_backend_stress.vcd -Smod_axi.tcl &"
echo " 打开应用波形:"
echo "   cd $WAVE_DIR && gtkwave simple.vcd -Sapp_simple.tcl &"
echo "========================================================"
