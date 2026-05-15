#include "riscv_test.h"

// Test: RAS overflow (depth > 4)
// RAS is 4-deep. Nesting 5+ calls overflows it.
// The 5th return gets wrong predicted target → branch_flush corrects it.
// Verifies CPU recovers correctly from RAS overflow misprediction.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: 4-deep call (within RAS capacity) → all returns correct
    // ================================================================
    .align 3
    li    TESTNUM, 1
    addi  t0, x0, 0           // depth counter

    jal   ra, func_a
ret_a:
    // After all returns, t0 should be 4 (incremented at each depth)
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    li    t4, 4
    bne   t0, t4, fail

    // Verify ra = ret_a (JAL saved it)
    la    t4, ret_a
    bne   ra, t4, fail

    // ================================================================
    // Part 2: 6-deep call (overflows RAS by 2)
    // Deepest 2 returns get wrong RAS prediction → flush → correct
    // ================================================================
    .align 3
    li    TESTNUM, 2
    addi  t0, x0, 0
    addi  t1, x0, 0           // secondary counter (set at deepest)

    jal   ra, deep_a
ret_deep_a:
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    // t0 should be 6, t1 should be 0xDE (set at depth 6)
    li    t4, 6
    bne   t0, t4, fail

    li    TESTNUM, 3
    li    t4, 0xDE
    bne   t1, t4, fail

    // ================================================================
    // Part 3: RAS correct after overflow recovery
    // Do a normal 2-deep call after the overflow test.
    // RAS should have been restored by branch_flush corrections.
    // ================================================================
    .align 3
    li    TESTNUM, 4
    addi  t0, x0, 0

    jal   ra, simple_a
ret_simple_a:
    addi  s0, x0, 0
    addi  s1, x0, 0

    li    t4, 2
    bne   t0, t4, fail

    j     pass

    // ============================================================
    //  Subroutines for Part 1 (4-deep)
    // ============================================================
func_a:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, func_b
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

func_b:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, func_c
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

func_c:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, func_d
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

func_d:
    addi  t0, t0, 1
    jalr  x0, ra, 0           // leaf: depth 4

    // ============================================================
    //  Subroutines for Part 2 (6-deep, overflows RAS)
    // ============================================================
deep_a:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, deep_b
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

deep_b:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, deep_c
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

deep_c:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, deep_d
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

deep_d:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, deep_e
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

deep_e:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, deep_f
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

deep_f:
    addi  t0, t0, 1
    li    t1, 0xDE             // marker at deepest level
    jalr  x0, ra, 0           // leaf: depth 6

    // ============================================================
    //  Subroutines for Part 3 (2-deep, post-overflow)
    // ============================================================
simple_a:
    addi  t0, t0, 1
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   ra, simple_b
    lw    ra, 0(sp)
    addi  sp, sp, 4
    jalr  x0, ra, 0

simple_b:
    addi  t0, t0, 1
    jalr  x0, ra, 0

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
