#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

// Test: Slot0 ordinary ALU + Slot1 load shares the single LSU port.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    li    t6, 0x80ff7f01
    sw    t6, 0(a0)

    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0

    j     load_pairs
    nop

    // Five aligned pairs. Each pair should issue as:
    //   Slot0: ordinary ALU
    //   Slot1: load using the shared single-port LSU
    .align 3
load_pairs:
    addi  s1, x0, 1
    lb    t0, 0(a0)
    addi  s2, x0, 2
    lbu   t1, 1(a0)
    addi  s3, x0, 3
    lh    t2, 2(a0)
    addi  s4, x0, 4
    lhu   t3, 2(a0)
    addi  s5, x0, 5
    lw    t4, 0(a0)

    // Immediate consumer of a Slot1 load must wait until the value is ready.
    .align 3
    addi  s6, x0, 6
    lb    a1, 0(a0)
    addi  a2, a1, 2
    addi  s7, x0, 7

    lw    s1, 0(t6)
    addi  s1, s1, 0
    sub   s2, s1, s0
    li    s3, 6
    blt   s2, s3, fail_count

    li    TESTNUM, 2
    li    t5, 1
    bne   t0, t5, fail

    li    TESTNUM, 3
    li    t5, 0x7f
    bne   t1, t5, fail

    li    TESTNUM, 4
    li    t5, 0xffff80ff
    bne   t2, t5, fail

    li    TESTNUM, 5
    li    t5, 0x80ff
    bne   t3, t5, fail

    li    TESTNUM, 6
    li    t5, 0x80ff7f01
    bne   t4, t5, fail

    li    TESTNUM, 7
    li    t5, 3
    bne   a2, t5, fail

pass:
    RVTEST_PASS

fail_count:
    li    TESTNUM, 1
    j     fail

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
