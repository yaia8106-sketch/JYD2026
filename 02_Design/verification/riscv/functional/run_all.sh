#!/bin/bash
# ============================================================
# run_all.sh - 批量运行所有 riscv-tests 并汇总结果
#
# Classification:
#   Functional correctness gate. Add short correctness tests here, not in
#   run_perf.sh or COE long-run scripts.
#
# 用法:
#   bash functional/run_all.sh      # 使用 Synopsys VCS
#   bash functional/run_all.sh vcs  # 等价写法
#
# 前置条件:
#   1. 先运行 build_tests.sh 生成 hex 文件
#   2. 确保 RTL 文件路径正确
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$RISCV_TESTS_DIR/.." && pwd)"
cd "$RISCV_TESTS_DIR"

RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
HEX_DIR="${HEX_DIR:-$RISCV_TESTS_DIR/work/hex}"
WORK_DIR="$RISCV_TESTS_DIR/work"
SIMULATOR="${1:-vcs}"

# RTL 源文件 (cpu_top + dcache + 子模块)
RTL_FILES="
    -F $RTL_DIR/filelists/cpu_blocks.f
    -F $RTL_DIR/filelists/dcache_bram.f
    $RTL_DIR/core/cpu_top.sv
    $RISCV_TESTS_DIR/work/dcache_data_ram.v
    $RISCV_TESTS_DIR/tb/perf_monitor.sv
    $RISCV_TESTS_DIR/tb/tb_riscv_tests.sv
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
       dcache_stress axi_backend_stress \
       counter_stress \
       bp_stress \
       dual_alu raw_block branch_single branch_dual branch_dual_flush branch_fwd_matrix branch_dual_edge slot1_branch waw loaduse_dual inst_buffer \
       fwd_s1 waw_fwd flush_instbuf pc_align loaduse_cross fwd_repair_lsu slot1_load slot1_store slot1_jal slot1_jump slot1_cfi_matrix lui_auipc_s1 \
       dcache_dual dcache_wna_edge dcache_miss_buffer dcache_refill_early instbuf_stall bp_dual slot1_bp_update \
       sb_stress ras_overflow \
       m_ext m_mem_fwd m_dcache_edge unsupported_encoding \
       zicsr_basic zicsr_edge csr_forwarding csr_trap_stall trap_mret trap_slot1 trap_flush trap_nested timer_irq_basic"

SIM_GUARD_ARGS="${SIM_GUARD_ARGS:-+pc_guard +watchdog=5000}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"
SIM_BIN="$WORK_DIR/riscv_tests_simv"
COMPILE_LOG="$WORK_DIR/riscv_tests_vcs.log"

if [ "$SIMULATOR" != "vcs" ]; then
    echo "ERROR: only Synopsys VCS is supported. Do not use iverilog/vvp/xsim for RTL regression."
    exit 1
fi

mkdir -p "$WORK_DIR"

export VCS_EXTRA_OPTS

# ---- 检查 hex 文件是否存在 ----
if [ ! -d "$HEX_DIR" ] || [ -z "$(ls $HEX_DIR/*.irom.hex 2>/dev/null)" ]; then
    echo "ERROR: hex 文件不存在。请先运行: bash utility/build_tests.sh"
    exit 1
fi

echo "========================================================"
echo " riscv-tests Runner (VCS)"
echo "========================================================"

echo "[INFO] Running standalone forwarding directed test..."
bash "$VERIFICATION_DIR/common/core/run_forwarding.sh"
echo ""

echo "[INFO] Running standalone muldiv randomized test..."
bash "$VERIFICATION_DIR/common/core/run_muldiv.sh"
echo ""

echo "[INFO] Verifying generated DRAM IP latency contract..."
bash "$VERIFICATION_DIR/platform/jyd/functional/run_dram_ip_latency.sh"
echo ""

echo "[INFO] Running store-buffer state/lookup/refill test..."
bash "$VERIFICATION_DIR/common/memory/run_store_buffer.sh"
echo ""

echo "[INFO] Running standalone frontend ABTB correctness test..."
bash "$VERIFICATION_DIR/common/frontend/run_abtb.sh"
echo ""

echo "[INFO] Running standalone Stage-1 PHT/GHR correctness test..."
bash "$VERIFICATION_DIR/common/frontend/run_direction.sh"
echo ""

echo "[INFO] Running frontend ABTB shadow integration test..."
bash "$VERIFICATION_DIR/common/frontend/run_integration.sh"
echo ""

echo "[INFO] Running frontend FTQ pair-policy test..."
bash "$VERIFICATION_DIR/common/frontend/run_pair.sh"
echo ""

echo "[INFO] Running frontend canonical steering test..."
bash "$VERIFICATION_DIR/common/frontend/run_canonical.sh"
echo ""

echo "[INFO] Running frontend ABTB/PHT branch steering integration test..."
bash "$VERIFICATION_DIR/common/frontend/run_steering.sh"
echo ""

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
