#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    addi  a0, a0, 1024

    // Part 1: slot0 ALU + slot1 JAL.  The JAL must write its link register,
    // flush the fall-through path, and count as one slot1 commit.
    li    TESTNUM, 1
    li    t0, 0
    li    t1, 0
    sw    x0, 4(a0)
    li    t2, 0x66

    .align 3
    j     s1_jal_pair
    nop

    .align 3
s1_jal_pair:
    addi  t0, x0, 1
    jal   t5, s1_jal_target
s1_jal_return:
    sw    t2, 4(a0)
    addi  t1, x0, 100

    .align 3
s1_jal_target:
    li    t3, 1
    bne   t0, t3, fail
    bnez  t1, fail
    lw    t2, 4(a0)
    bnez  t2, fail
    la    t2, s1_jal_return
    bne   t5, t2, fail

    // Part 2: slot0 ALU + slot1 JALR.  The target must clear bit 0, link
    // must point to the fall-through PC, and the wrong-path store must not run.
    li    TESTNUM, 2
    li    t0, 0
    sw    x0, 0(a0)
    la    t4, s1_jalr_target
    addi  t4, t4, 1

    .align 3
    j     s1_jalr_pair
    nop

    .align 3
s1_jalr_pair:
    addi  t0, x0, 2
    jalr  t5, 0(t4)
s1_jalr_return:
    li    t1, 0x5A
    sw    t1, 0(a0)

    .align 3
s1_jalr_target:
    li    t3, 2
    bne   t0, t3, fail
    lw    t2, 0(a0)
    bnez  t2, fail
    la    t2, s1_jalr_return
    bne   t5, t2, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
