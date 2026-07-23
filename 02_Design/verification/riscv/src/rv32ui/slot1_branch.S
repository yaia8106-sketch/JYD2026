#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    t6, DUAL_CNT_ADDR

    // Part 1: slot0 ALU + slot1 branch, not taken. The RAW chains around the
    // counter reads keep unrelated S1 commits out of the measured window.
    addi  t0, x0, 0
    addi  t1, x0, 7

    .align 3
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    addi  s0, s0, 0

    addi  t0, s0, 0
    bne   t1, t1, fail_nt

    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0
    sub   t2, s1, s0
    li    t3, 1
    blt   t2, t3, fail_nt_count

    // Part 2: slot0 ALU + slot1 branch, taken. Fall-through instructions are
    // younger than the slot1 branch and must be flushed by delayed replay.
    addi  t4, x0, 0

    .align 3
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    addi  s0, s0, 0

    addi  t0, s0, 0
    beq   x0, x0, s1_taken

    addi  t4, x0, 99
    addi  t4, x0, 100

s1_taken:
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0
    sub   t2, s1, s0
    li    t3, 1
    blt   t2, t3, fail_taken_count
    bnez  t4, fail_taken

    // Part 3: slot0 LSU + slot1 branch is now legal. The taken slot1 branch
    // must redirect and the fall-through instruction must not execute.
    addi  t4, x0, 0

    .align 3
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    lw    s0, 0(t6)
    lw    t5, 0(t6)
    beq   x0, x0, lsu_s1_branch_target

    addi  t4, x0, 123

lsu_s1_branch_target:
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0
    sub   t2, s1, s0
    li    t3, 1
    blt   t2, t3, fail_lsu_count
    bnez  t4, fail_lsu_count

pass:
    RVTEST_PASS

fail_nt_count:
    li    TESTNUM, 1
    j     fail

fail_nt:
    li    TESTNUM, 2
    j     fail

fail_taken_count:
    li    TESTNUM, 3
    j     fail

fail_taken:
    li    TESTNUM, 4
    j     fail

fail_lsu_count:
    li    TESTNUM, 5
    j     fail

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
