#include "riscv_test.h"

// Test: branch condition precompute with forwarding/stall/flush coverage.
// The CPU compares branch operands in ID and latches the 1-bit result into EX.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: S0 EX producer -> branch taken; wrong-path slot1 killed.
    // ================================================================
    li    TESTNUM, 1
    addi  t1, x0, 5
    addi  t2, x0, 0
    addi  t0, x0, 5
    beq   t0, t1, 1f
    addi  t2, x0, 0x7f
    j     fail
1:
    addi  s0, x0, 0
    addi  s0, x0, 0
    bnez  t2, fail

    // ================================================================
    // Part 2: S0 EX producer -> branch not taken.
    // If ID compare sees stale x0, this branch is wrongly taken.
    // ================================================================
    li    TESTNUM, 2
    addi  t1, x0, 0
    addi  t2, x0, 0
    addi  t0, x0, 8
    beq   t0, t1, fail
    addi  t2, x0, 2
    addi  t3, x0, 2
    bne   t2, t3, fail

    // ================================================================
    // Part 3: S1 EX producer -> next branch taken.
    // The producer is deliberately placed in slot1 of a dual ALU pair.
    // ================================================================
    li    TESTNUM, 3
    addi  t1, x0, 7
    addi  t2, x0, 0
    .align 3
    addi  s1, x0, 1
    addi  t0, x0, 7
    beq   t0, t1, 3f
    addi  t2, x0, 0x55
    j     fail
3:
    addi  s0, x0, 0
    addi  s0, x0, 0
    bnez  t2, fail

    // ================================================================
    // Part 4: MEM/WB-stage ALU forwarding into branch operands.
    // ================================================================
    li    TESTNUM, 4
    addi  t1, x0, 11
    addi  t0, x0, 11
    addi  s2, x0, 0
    beq   t0, t1, 4f
    j     fail
4:
    addi  t1, x0, 13
    addi  t0, x0, 13
    addi  s2, x0, 0
    addi  s3, x0, 0
    beq   t0, t1, 5f
    j     fail

    // ================================================================
    // Part 5: load-use branch must stall, then compare loaded data.
    // ================================================================
5:
    li    TESTNUM, 5
    lui   a0, 0x80100
    addi  t1, x0, 0x23
    sw    t1, 0(a0)
    lw    t0, 0(a0)
    beq   t0, t1, 6f
    j     fail

    // ================================================================
    // Part 6: all branch condition encodings, signed and unsigned.
    // ================================================================
6:
    li    TESTNUM, 6
    addi  t0, x0, -1
    addi  t1, x0, 1
    blt   t0, t1, .Lcond_blt
    j     fail
.Lcond_blt:
    bge   t1, t0, .Lcond_bge
    j     fail
.Lcond_bge:
    bltu  t1, t0, .Lcond_bltu
    j     fail
.Lcond_bltu:
    bgeu  t0, t1, .Lcond_bgeu
    j     fail
.Lcond_bgeu:
    bne   t0, t1, .Lcond_bne
    j     fail
.Lcond_bne:
    beq   t1, t1, 7f
    j     fail

    // ================================================================
    // Part 7: cache-miss load feeding a taken branch.
    // ================================================================
7:
    li    TESTNUM, 7
    lui   a0, 0x80100
    addi  t1, x0, 0x55
    sw    t1, 64(a0)
    lw    t0, 64(a0)
    bne   t0, x0, pass
    j     fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
