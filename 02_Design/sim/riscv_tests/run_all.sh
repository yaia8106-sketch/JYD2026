#!/bin/bash
# ============================================================
# run_all.sh - 批量运行所有 riscv-tests 并汇总结果
#
# 用法:
#   ./run_all.sh              # 使用 iverilog (默认)
#   ./run_all.sh xsim         # 使用 Vivado xsim
#
# 前置条件:
#   1. 先运行 build_tests.sh 生成 hex 文件
#   2. 确保 RTL 文件路径正确
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SIM_DIR="$(cd ".." && pwd)"
RTL_DIR="$(cd "$SIM_DIR/../rtl" && pwd)"
HEX_DIR="work/hex"
WORK_DIR="work"
SIMULATOR="${1:-iverilog}"

# RTL 源文件 (cpu_top + dcache + 子模块)
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
    $SCRIPT_DIR/tb_riscv_tests.sv
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
       bp_stress"

mkdir -p "$WORK_DIR"

# ---- 检查 hex 文件是否存在 ----
if [ ! -d "$HEX_DIR" ] || [ -z "$(ls $HEX_DIR/*.irom.hex 2>/dev/null)" ]; then
    echo "ERROR: hex 文件不存在。请先运行: bash build_tests.sh"
    exit 1
fi

echo "========================================================"
echo " riscv-tests Runner ($SIMULATOR)"
echo "========================================================"

TOTAL=0
PASSED=0
FAILED=0
TIMEOUT=0
ERRORS=""

# ---- 编译 (仅 iverilog 需要预编译) ----
if [ "$SIMULATOR" = "iverilog" ]; then
    echo "[INFO] Compiling with iverilog..."
    SIM_BIN="$WORK_DIR/riscv_tests_sim"
    # shellcheck disable=SC2086
    iverilog -g2012 -o "$SIM_BIN" $RTL_FILES 2>&1 | head -20
    if [ $? -ne 0 ]; then
        echo "ERROR: iverilog compilation failed"
        exit 1
    fi
    echo "[INFO] Compilation OK"
    echo ""
fi

# ---- 逐个运行测试 ----
for test_name in $TESTS; do
    irom_hex="$HEX_DIR/rv32ui-p-${test_name}.irom.hex"
    dram_hex="$HEX_DIR/rv32ui-p-${test_name}.dram.hex"

    if [ ! -f "$irom_hex" ] || [ ! -f "$dram_hex" ]; then
        printf "  %-20s [SKIP] hex not found\n" "$test_name"
        continue
    fi

    TOTAL=$((TOTAL + 1))

    if [ "$SIMULATOR" = "iverilog" ]; then
        result=$(vvp -N "$SIM_BIN" \
            "+irom=$irom_hex" "+dram=$dram_hex" "+test=$test_name" \
            "+cycles=50000" 2>&1 | grep -E "^\[(PASS|FAIL|TIMEOUT)\]" | head -1)
    elif [ "$SIMULATOR" = "xsim" ]; then
        # Vivado xsim flow (requires pre-elaborated snapshot)
        result=$(xsim riscv_tests_sim \
            -testplusarg "irom=$irom_hex" \
            -testplusarg "dram=$dram_hex" \
            -testplusarg "test=$test_name" \
            -testplusarg "cycles=50000" \
            -runall 2>&1 | grep -E "^\[(PASS|FAIL|TIMEOUT)\]" | head -1)
    fi

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
