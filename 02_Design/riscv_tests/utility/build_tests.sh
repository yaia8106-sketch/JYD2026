#!/bin/bash
# ============================================================
# build_tests.sh - 编译 riscv-tests 并转换为 hex 文件
# 使用自定义 env + 自定义 link.ld (IROM/DRAM 分离)
#
# Classification:
#   Utility only. This generates work/hex inputs after test source changes;
#   it is not a verification entry point.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HEX_DIR="$RISCV_TESTS_DIR/work/hex"
BUILD_DIR="/tmp/riscv_build"

CC=riscv64-unknown-elf-gcc
OBJDUMP="riscv64-unknown-elf-objdump"
CFLAGS="-march=rv32im_zicsr -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles"
INCLUDES="-I$RISCV_TESTS_DIR/env"
LDFLAGS="-T$RISCV_TESTS_DIR/env/link.ld"

# RV32IM 指令测试 (去掉 fence_i).
# Includes diagnostic-only microbenchmarks used by performance/branch; those
# are built here but intentionally not added to functional/run_all.sh.
TESTS="app_calc \
       simple \
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
       bp_s0_taken_loop bp_s0_not_taken_loop bp_s0_alternating bp_btb_alias_pair bp_wrongpath_pollution \
       dual_alu raw_block branch_single branch_dual branch_dual_flush branch_fwd_matrix branch_dual_edge slot1_branch waw loaduse_dual inst_buffer \
       fwd_s1 waw_fwd flush_instbuf pc_align loaduse_cross fwd_repair_lsu slot1_load slot1_store slot1_jal slot1_jump slot1_cfi_matrix lui_auipc_s1 \
	       dcache_dual dcache_wna_edge instbuf_stall bp_dual slot1_bp_update \
       sb_stress ras_overflow \
       m_ext m_dcache_edge \
       zicsr_basic zicsr_edge csr_forwarding csr_trap_stall trap_mret trap_slot1 trap_flush trap_nested timer_irq_basic"

mkdir -p "$HEX_DIR"
mkdir -p "$BUILD_DIR"

echo "========================================================"
echo " Building riscv-tests for RV32IM/Zicsr (custom env)"
echo " Source:  $RISCV_TESTS_DIR/src/rv32ui/"
echo " Output:  $HEX_DIR/"
echo "========================================================"

PASS=0
FAIL=0
SKIP=0

for test in $TESTS; do
    src="$RISCV_TESTS_DIR/src/rv32ui/$test.S"
    elf="$BUILD_DIR/rv32ui-p-$test"

    if [ ! -f "$src" ]; then
        echo "[SKIP] rv32ui-p-$test (source not found)"
        SKIP=$((SKIP + 1))
        continue
    fi

    printf "[BUILD] rv32ui-p-%-12s " "$test"

    if $CC $CFLAGS $INCLUDES $LDFLAGS "$src" -o "$elf" 2>/tmp/rv_build_err.txt; then
        # 转换为 hex (直接输出到 HEX_DIR)
        python3 "$RISCV_TESTS_DIR/tools/elf2hex.py" "$elf" \
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
