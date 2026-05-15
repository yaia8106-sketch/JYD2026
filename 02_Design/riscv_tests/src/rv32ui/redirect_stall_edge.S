#include "riscv_test.h"

// Branch redirect while an older DCache miss is holding MEM.
// This protects the current coupling between EX redirect, fetch-buffer cleanup,
// and backend branch cleanup from being broken by local retiming.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    addi  a2, a0, 512
    sw    x0, 0(a2)

    // Part 1: a taken branch behind a cache miss must kill the wrong-path store.
    li    TESTNUM, 1
    li    t1, 0x6D
    lui   a1, 0x80101

    lw    t0, 0(a1)
    beq   x0, x0, taken_after_miss
    sw    t1, 0(a2)

taken_after_miss:
    lw    t2, 0(a2)
    bne   t2, x0, fail

    // Part 2: a trained taken loop must still exit on the final not-taken
    // branch when the branch sits behind a cache miss.
    li    TESTNUM, 2
    li    s0, 4
    li    s1, 0
    lui   a1, 0x80102

miss_loop:
    addi  s0, s0, -1
    addi  s1, s1, 1
    lw    t0, 0(a1)
    addi  a1, a1, 64
    bnez  s0, miss_loop

    li    t3, 4
    bne   s1, t3, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
