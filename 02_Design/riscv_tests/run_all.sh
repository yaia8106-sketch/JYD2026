#!/bin/bash
# ============================================================
# run_all.sh - 批量运行所有 riscv-tests 并汇总结果
#
# 用法:
#   ./run_all.sh              # 使用 Synopsys VCS
#   ./run_all.sh vcs          # 等价写法
#
# 前置条件:
#   1. 先运行 build_tests.sh 生成 hex 文件
#   2. 确保 RTL 文件路径正确
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RTL_DIR="$(cd "$SCRIPT_DIR/../rtl" && pwd)"
HEX_DIR="work/hex"
WORK_DIR="work"
SIMULATOR="${1:-vcs}"

# RTL 源文件 (cpu_top + dcache + 子模块)
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
    $SCRIPT_DIR/work/dcache_data_ram.v
    $SCRIPT_DIR/tb/perf_monitor.sv
    $SCRIPT_DIR/tb/tb_riscv_tests.sv
"

# 要运行的测试 (与 build_tests.sh 一致, 去掉 fence_i)
TESTS="simple \
       add addi sub \
       and andi or ori xor xori \
       sll slli srl srli sra srai \
       slt slti sltiu sltu \
       beq bne blt bge bltu bgeu \
       jal jalr \
       lui auipc \
       lb lbu lh lhu lw \
       sb sh sw \
       ld_st st_ld \
       dcache_stress \
       counter_stress \
       bp_stress \
       dual_alu raw_block branch_single branch_dual branch_dual_flush branch_fwd_matrix branch_dual_edge slot1_branch waw loaduse_dual inst_buffer \
       fwd_s1 waw_fwd flush_instbuf pc_align loaduse_cross slot1_load slot1_store slot1_jal lui_auipc_s1 \
       dcache_dual instbuf_stall bp_dual slot1_bp_update \
       sb_stress ras_overflow \
       m_ext \
       zicsr_basic zicsr_edge csr_forwarding csr_trap_stall trap_mret trap_slot1 trap_flush trap_nested timer_irq_basic"

SIM_GUARD_ARGS="${SIM_GUARD_ARGS:-+pc_guard +watchdog=5000}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$SCRIPT_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/riscv_tests_simv"
COMPILE_LOG="$WORK_DIR/riscv_tests_vcs.log"

if [ "$SIMULATOR" != "vcs" ]; then
    echo "ERROR: only Synopsys VCS is supported. Do not use iverilog/vvp/xsim for RTL regression."
    exit 1
fi

mkdir -p "$WORK_DIR"

# ---- 检查 hex 文件是否存在 ----
if [ ! -d "$HEX_DIR" ] || [ -z "$(ls $HEX_DIR/*.irom.hex 2>/dev/null)" ]; then
    echo "ERROR: hex 文件不存在。请先运行: bash build_tests.sh"
    exit 1
fi

echo "========================================================"
echo " riscv-tests Runner (VCS)"
echo "========================================================"

TOTAL=0
PASSED=0
FAILED=0
TIMEOUT=0
ERRORS=""

# ---- 编译 ----
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

echo "[INFO] Compiling with VCS..."
# shellcheck disable=SC2086
if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_riscv_tests -Mdir="$WORK_DIR/riscv_tests_vcs.csrc" -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -80 "$COMPILE_LOG"
    exit 1
fi
head -20 "$COMPILE_LOG"
echo "[INFO] Compilation OK"
echo ""

read -r -a GUARD_ARGS <<< "$SIM_GUARD_ARGS"

# ---- 逐个运行测试 ----
for test_name in $TESTS; do
    irom_hex="$HEX_DIR/rv32ui-p-${test_name}.irom.hex"
    dram_hex="$HEX_DIR/rv32ui-p-${test_name}.dram.hex"

    if [ ! -f "$irom_hex" ] || [ ! -f "$dram_hex" ]; then
        printf "  %-20s [SKIP] hex not found\n" "$test_name"
        continue
    fi

    TOTAL=$((TOTAL + 1))

    result=$("$SIM_BIN" \
        "+irom=$irom_hex" "+dram=$dram_hex" "+test=$test_name" \
        "+cycles=50000" "${GUARD_ARGS[@]}" 2>&1 | grep -E "^\[(PASS|FAIL|TIMEOUT)\]" | head -1)

    if echo "$result" | grep -q "\[PASS\]"; then
        printf "  %-20s ✅ PASS\n" "$test_name"
        PASSED=$((PASSED + 1))
    elif echo "$result" | grep -q "\[FAIL\]"; then
        printf "  %-20s ❌ %s\n" "$test_name" "$result"
        FAILED=$((FAILED + 1))
        ERRORS="$ERRORS  $result\n"
    elif echo "$result" | grep -q "\[TIMEOUT\]"; then
        printf "  %-20s ⏰ TIMEOUT\n" "$test_name"
        TIMEOUT=$((TIMEOUT + 1))
        ERRORS="$ERRORS  [TIMEOUT] $test_name\n"
    else
        printf "  %-20s ❓ UNKNOWN: %s\n" "$test_name" "$result"
        FAILED=$((FAILED + 1))
        ERRORS="$ERRORS  [UNKNOWN] $test_name\n"
    fi
done

# ---- 汇总 ----
echo ""
echo "========================================================"
echo " Results: $PASSED/$TOTAL passed"
echo "   ✅ PASS:    $PASSED"
echo "   ❌ FAIL:    $FAILED"
echo "   ⏰ TIMEOUT: $TIMEOUT"
echo "========================================================"

if [ -n "$ERRORS" ]; then
    echo ""
    echo "Failed tests:"
    printf "$ERRORS"
fi

# 退出码: 0 = 全部通过, 1 = 有失败
[ "$FAILED" -eq 0 ] && [ "$TIMEOUT" -eq 0 ]
