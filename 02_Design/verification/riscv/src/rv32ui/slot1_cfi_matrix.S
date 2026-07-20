#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

#define READ_DUAL_CNT(_rd) \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    addi  t6, t6, 0; \
    lw    _rd, 0(t6); \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0; \
    addi  _rd, _rd, 0

#define CHECK_DUAL_DELTA_GE_ONE(_num) \
    li    TESTNUM, _num; \
    sub   s10, s1, s0; \
    li    s11, 1; \
    blt   s10, s11, fail

// Test: slot0 ALU/LSU + slot1 CFI combinations.
// The dual-issue counter check proves the CFI really committed from slot1.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    t6, DUAL_CNT_ADDR
    lui   a0, 0x80100
    addi  a0, a0, 1536

    li    t0, 0x11
    li    t1, 0x22
    li    t2, 0x33
    li    t3, 0x44
    sw    t0, 0(a0)
    sw    t1, 4(a0)
    sw    t2, 8(a0)
    sw    t3, 12(a0)
    lw    s2, 0(a0)
    lw    s2, 4(a0)
    lw    s2, 8(a0)
    lw    s2, 12(a0)

    // Part 1: slot0 ALU + slot1 branch, not taken.
    li    TESTNUM, 1
    li    t0, 0
    .align 3
    READ_DUAL_CNT(s0)
    addi  t0, x0, 1
    bne   x0, x0, fail
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(1)
    li    s2, 1
    bne   t0, s2, fail

    // Part 2: slot0 ALU + slot1 JAL.
    li    TESTNUM, 2
    li    t0, 0
    li    t1, 0
    li    t2, 0
    .align 3
    READ_DUAL_CNT(s0)
    addi  t0, x0, 2
    jal   t1, alu_jal_target
alu_jal_fallthrough:
    addi  t2, x0, 99
    j     fail

    .align 3
alu_jal_target:
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(2)
    li    s2, 2
    bne   t0, s2, fail
    la    s2, alu_jal_fallthrough
    bne   t1, s2, fail
    bnez  t2, fail

    // Part 3: slot0 ALU + slot1 JALR.
    li    TESTNUM, 3
    li    t0, 0
    li    t1, 0
    li    t2, 0
    la    s3, alu_jalr_target
    .align 3
    READ_DUAL_CNT(s0)
    addi  t0, x0, 3
    jalr  t1, 0(s3)
alu_jalr_fallthrough:
    addi  t2, x0, 99
    j     fail

    .align 3
alu_jalr_target:
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(3)
    li    s2, 3
    bne   t0, s2, fail
    la    s2, alu_jalr_fallthrough
    bne   t1, s2, fail
    bnez  t2, fail

    // Part 4: slot0 load hit + slot1 branch, taken.
    li    TESTNUM, 4
    li    t0, 0
    li    t2, 0
    .align 3
    READ_DUAL_CNT(s0)
    lw    t0, 0(a0)
    beq   x0, x0, load_branch_target
load_branch_fallthrough:
    addi  t2, x0, 99
    j     fail

    .align 3
load_branch_target:
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(4)
    li    s2, 0x11
    bne   t0, s2, fail
    bnez  t2, fail

    // Part 5: slot0 store hit + slot1 branch, taken.
    li    TESTNUM, 5
    li    t2, 0
    li    t3, 0x55
    sw    x0, 16(a0)
    .align 3
    READ_DUAL_CNT(s0)
    sw    t3, 16(a0)
    beq   x0, x0, store_branch_target
store_branch_fallthrough:
    addi  t2, x0, 99
    j     fail

    .align 3
store_branch_target:
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(5)
    lw    s2, 16(a0)
    bne   s2, t3, fail
    bnez  t2, fail

    // Part 6: slot0 load hit + slot1 JAL.
    li    TESTNUM, 6
    li    t0, 0
    li    t1, 0
    li    t2, 0
    .align 3
    READ_DUAL_CNT(s0)
    lw    t0, 4(a0)
    jal   t1, load_jal_target
load_jal_fallthrough:
    addi  t2, x0, 99
    j     fail

    .align 3
load_jal_target:
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(6)
    li    s2, 0x22
    bne   t0, s2, fail
    la    s2, load_jal_fallthrough
    bne   t1, s2, fail
    bnez  t2, fail

    // Part 7: slot0 store hit + slot1 JAL.
    li    TESTNUM, 7
    li    t1, 0
    li    t2, 0
    li    t3, 0x66
    sw    x0, 20(a0)
    .align 3
    READ_DUAL_CNT(s0)
    sw    t3, 20(a0)
    jal   t1, store_jal_target
store_jal_fallthrough:
    addi  t2, x0, 99
    j     fail

    .align 3
store_jal_target:
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(7)
    lw    s2, 20(a0)
    bne   s2, t3, fail
    la    s2, store_jal_fallthrough
    bne   t1, s2, fail
    bnez  t2, fail

    // Part 8: slot0 load hit + slot1 JALR.
    li    TESTNUM, 8
    li    t0, 0
    li    t1, 0
    li    t2, 0
    la    s3, load_jalr_target
    .align 3
    READ_DUAL_CNT(s0)
    lw    t0, 8(a0)
    jalr  t1, 0(s3)
load_jalr_fallthrough:
    addi  t2, x0, 99
    j     fail

    .align 3
load_jalr_target:
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(8)
    li    s2, 0x33
    bne   t0, s2, fail
    la    s2, load_jalr_fallthrough
    bne   t1, s2, fail
    bnez  t2, fail

    // Part 9: slot0 store hit + slot1 JALR.
    li    TESTNUM, 9
    li    t1, 0
    li    t2, 0
    li    t3, 0x77
    sw    x0, 24(a0)
    la    s3, store_jalr_target
    .align 3
    READ_DUAL_CNT(s0)
    sw    t3, 24(a0)
    jalr  t1, 0(s3)
store_jalr_fallthrough:
    addi  t2, x0, 99
    j     fail

    .align 3
store_jalr_target:
    READ_DUAL_CNT(s1)
    CHECK_DUAL_DELTA_GE_ONE(9)
    lw    s2, 24(a0)
    bne   s2, t3, fail
    la    s2, store_jalr_fallthrough
    bne   t1, s2, fail
    bnez  t2, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
