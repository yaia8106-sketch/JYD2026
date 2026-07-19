#include "riscv_test.h"

// Test: Store buffer back-to-back traffic and recent-store visibility.
// Direct BRAM drains in parallel with new pushes; generic backends may stall.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100

    // ================================================================
    // Part 1: Two stores to same line, different words → sb_conflict
    // ================================================================
    .align 3
    li    TESTNUM, 1
    li    t0, 0xAA
    li    t1, 0xBB
    sw    t0, 0(a0)           // store hit → fills SB
    sw    t1, 4(a0)           // store hit, SB valid → sb_conflict → drain stall

    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    lw    t2, 0(a0)
    addi  t2, t2, 0
    addi  t2, t2, 0
    addi  t2, t2, 0
    li    t4, 0xAA
    bne   t2, t4, fail

    li    TESTNUM, 2
    lw    t3, 4(a0)
    addi  t3, t3, 0
    addi  t3, t3, 0
    addi  t3, t3, 0
    li    t4, 0xBB
    bne   t3, t4, fail

    // ================================================================
    // Part 2: Three stores in rapid succession
    // ================================================================
    .align 3
    li    TESTNUM, 3
    li    t0, 0x11
    li    t1, 0x22
    li    t2, 0x33
    sw    t0, 8(a0)
    sw    t1, 12(a0)          // sb_conflict #1
    sw    t2, 8(a0)           // sb_conflict #2 (overwrites first store)

    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    lw    t3, 8(a0)
    addi  t3, t3, 0
    addi  t3, t3, 0
    addi  t3, t3, 0
    li    t4, 0x33
    bne   t3, t4, fail        // should be 0x33 (last store wins)

    li    TESTNUM, 4
    lw    t3, 12(a0)
    addi  t3, t3, 0
    addi  t3, t3, 0
    addi  t3, t3, 0
    li    t4, 0x22
    bne   t3, t4, fail

    // ================================================================
    // Part 3: Store + dual-issue ALU + store → SB stall + dual
    // ================================================================
    .align 3
    li    TESTNUM, 5
    li    t0, 0x55
    li    t1, 0x66
    sw    t0, 16(a0)          // store → SB fills
    addi  t5, x0, 99          // might dual-issue or buffer
    sw    t1, 20(a0)          // next store → sb_conflict

    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    li    t4, 99
    bne   t5, t4, fail

    lw    t3, 16(a0)
    addi  t3, t3, 0
    addi  t3, t3, 0
    addi  t3, t3, 0
    li    t4, 0x55
    bne   t3, t4, fail

    li    TESTNUM, 6
    lw    t3, 20(a0)
    addi  t3, t3, 0
    addi  t3, t3, 0
    addi  t3, t3, 0
    li    t4, 0x66
    bne   t3, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
