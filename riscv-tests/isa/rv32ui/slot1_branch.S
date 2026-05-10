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
    addi  t5, x0, 0
    addi  t5, t5, 0
    addi  t5, t5, 0
    addi  t5, t5, 0
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    addi  s0, s0, 0

    addi  t0, s0, 0
    bne   t1, t1, fail_nt

    addi  t0, t0, 0
    addi  t0, t0, 0
    addi  t0, t0, 0
    addi  t0, t0, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0
    sub   t2, s1, s0
    li    t3, 1
    bne   t2, t3, fail_nt_count

    // Part 2: slot0 ALU + slot1 branch, taken. Fall-through instructions are
    // younger than the slot1 branch and must be flushed by delayed replay.
    addi  t4, x0, 0

    .align 3
    addi  t5, x0, 0
    addi  t5, t5, 0
    addi  t5, t5, 0
    addi  t5, t5, 0
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    addi  s0, s0, 0

    addi  t0, s0, 0
    beq   x0, x0, s1_taken

    addi  t4, x0, 99
    addi  t4, x0, 100

s1_taken:
    addi  t0, t0, 0
    addi  t0, t0, 0
    addi  t0, t0, 0
    addi  t0, t0, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0
    sub   t2, s1, s0
    li    t3, 1
    bne   t2, t3, fail_taken_count
    bnez  t4, fail_taken

    // Part 3: slot0 LSU + slot1 branch is intentionally not dual-issued in
    // V1. The branch should execute later as slot0, and the counter must not
    // increase for this pair.
    addi  t4, x0, 0

    .align 3
    addi  t5, x0, 0
    addi  t5, t5, 0
    addi  t5, t5, 0
    addi  t5, t5, 0
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    addi  s0, s0, 0

    lw    t5, 0(t6)
    beq   x0, x0, lsu_s1_branch_target

    addi  t4, x0, 123

lsu_s1_branch_target:
    addi  t5, t5, 0
    addi  t5, t5, 0
    addi  t5, t5, 0
    addi  t5, t5, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0
    sub   t2, s1, s0
    bnez  t2, fail_lsu_count
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
