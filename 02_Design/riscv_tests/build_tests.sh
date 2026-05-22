#!/bin/bash
# ============================================================
# build_tests.sh - 编译 riscv-tests 并转换为 hex 文件
# 使用自定义 env + 自定义 link.ld (IROM/DRAM 分离)
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEX_DIR="$SCRIPT_DIR/work/hex"
BUILD_DIR="/tmp/riscv_build"

CC=riscv64-unknown-elf-gcc
OBJDUMP="riscv64-unknown-elf-objdump"
CFLAGS="-march=rv32im_zicsr -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles"
INCLUDES="-I$SCRIPT_DIR/env"
LDFLAGS="-T$SCRIPT_DIR/env/link.ld"

# RV32IM 指令测试 (去掉 fence_i)
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
       fwd_s1 waw_fwd flush_instbuf pc_align loaduse_cross slot1_load lui_auipc_s1 \
       dcache_dual instbuf_stall bp_dual \
       sb_stress ras_overflow \
       m_ext \
       zicsr_basic zicsr_edge csr_forwarding csr_trap_stall trap_mret trap_slot1 trap_flush trap_nested"

mkdir -p "$HEX_DIR"
mkdir -p "$BUILD_DIR"

echo "========================================================"
echo " Building riscv-tests for RV32IM/Zicsr (custom env)"
echo " Source:  $SCRIPT_DIR/src/rv32ui/"
echo " Output:  $HEX_DIR/"
echo "========================================================"

PASS=0
FAIL=0
SKIP=0

for test in $TESTS; do
    src="$SCRIPT_DIR/src/rv32ui/$test.S"
    elf="$BUILD_DIR/rv32ui-p-$test"

    if [ ! -f "$src" ]; then
        echo "[SKIP] rv32ui-p-$test (source not found)"
        SKIP=$((SKIP + 1))
        continue
    fi

    printf "[BUILD] rv32ui-p-%-12s " "$test"

    if $CC $CFLAGS $INCLUDES $LDFLAGS "$src" -o "$elf" 2>/tmp/rv_build_err.txt; then
        # 转换为 hex (直接输出到 HEX_DIR)
        python3 "$SCRIPT_DIR/tools/elf2hex.py" "$elf" \
            "$HEX_DIR/rv32ui-p-${test}.irom.hex" \
            "$HEX_DIR/rv32ui-p-${test}.dram.hex"

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
