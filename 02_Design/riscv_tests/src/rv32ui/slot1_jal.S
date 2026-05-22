#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

// Test: Slot0 ordinary ALU + Slot1 JAL shares the existing delayed
// control redirect path. JALR is intentionally not enabled in Slot1 yet.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    t6, DUAL_CNT_ADDR
    lui   a0, 0x80100
    addi  t1, x0, 0

    // Read the dual-issue counter before the Slot1 JAL pair.
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    sw    x0, 0(a0)

    j     s1_jal_pair
    nop

    .align 3
s1_jal_pair:
    addi  s2, x0, 123
    jal   t0, s1_jal_target

s1_jal_fallthrough:
    addi  t1, x0, 1
    j     fail

    .align 3
s1_jal_target:
    addi  t6, t6, 0
    addi  t6, t6, 0
    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0

    li    TESTNUM, 1
    sub   t2, s1, s0
    li    t3, 1
    bne   t2, t3, fail

    li    TESTNUM, 2
    bnez  t1, fail

    li    TESTNUM, 3
    li    t4, 123
    bne   s2, t4, fail

    li    TESTNUM, 4
    la    t4, s1_jal_fallthrough
    bne   t0, t4, fail

    // S0 LSU + S1 JAL remains outside the enabled pairing policy. The JAL
    // still has to execute correctly after serialization.
    .align 3
    lw    t5, 0(t6)
    jal   t0, s0_lsu_s1_jal_target

s0_lsu_s1_jal_fallthrough:
    addi  t1, x0, 2
    j     fail

    .align 3
s0_lsu_s1_jal_target:
    li    TESTNUM, 5
    bnez  t1, fail

    li    TESTNUM, 6
    la    t4, s0_lsu_s1_jal_fallthrough
    bne   t0, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
