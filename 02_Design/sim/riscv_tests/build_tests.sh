#!/bin/bash
# ============================================================
# build_tests.sh - 编译 riscv-tests 并转换为 hex 文件
# 使用自定义 env (无 CSR) + 自定义 link.ld (IROM/DRAM 分离)
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TESTS_DIR="$WORKSPACE/riscv-tests"
CUSTOM_ENV="$TESTS_DIR/env/custom"
HEX_DIR="$SCRIPT_DIR/work/hex"

CC=riscv64-unknown-elf-gcc
OBJDUMP="riscv64-unknown-elf-objdump"
CFLAGS="-march=rv32i -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles"
INCLUDES="-I$CUSTOM_ENV -I$TESTS_DIR/isa/macros/scalar"
LDFLAGS="-T$CUSTOM_ENV/link.ld"

# RV32I 指令测试 (去掉 fence_i)
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
       bp_stress \
       coprime \
       dcache_test"

mkdir -p "$HEX_DIR"

echo "========================================================"
echo " Building riscv-tests for RV32I (custom env, no CSR)"
echo " Source:  $TESTS_DIR/isa/rv32ui/"
echo " Output:  $HEX_DIR/"
echo "========================================================"

PASS=0
FAIL=0
SKIP=0

for test in $TESTS; do
    src="$TESTS_DIR/isa/rv32ui/$test.S"
    elf="$HEX_DIR/rv32ui-p-$test"

    if [ ! -f "$src" ]; then
        echo "[SKIP] rv32ui-p-$test (source not found)"
        SKIP=$((SKIP + 1))
        continue
    fi

    printf "[BUILD] rv32ui-p-%-12s " "$test"

    if $CC $CFLAGS $INCLUDES $LDFLAGS "$src" -o "$elf" 2>/tmp/rv_build_err.txt; then
        # 生成反汇编
        $OBJDUMP --disassemble-all --section=.text --section=.text.init \
                 --section=.data "$elf" > "${elf}.dump" 2>/dev/null

        # 转换为 hex
        python3 "$SCRIPT_DIR/elf2hex.py" "$elf" "${elf}.irom.hex" "${elf}.dram.hex"

        PASS=$((PASS + 1))
    else
        echo "COMPILE ERROR:"
        cat /tmp/rv_build_err.txt | head -5
        FAIL=$((FAIL + 1))
    fi
done

echo "========================================================"
echo " Results: $PASS built, $FAIL failed, $SKIP skipped"
echo " Hex files: $HEX_DIR/"
echo "========================================================"
