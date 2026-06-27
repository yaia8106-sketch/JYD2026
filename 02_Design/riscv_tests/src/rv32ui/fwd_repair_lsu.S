#include "riscv_test.h"

// Test: MEM-ready load repair for S0 branch/JALR/LSU consumers.
// These cases fail if ID is released but EX still uses stale operands.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    addi  a1, a0, 128
    addi  a2, a0, 256
    addi  a3, a0, 384

    // Warm the scratch lines so the following dependent loads hit.
    lw    s0, 0(a0)
    lw    s0, 0(a1)
    lw    s0, 0(a2)
    lw    s0, 0(a3)

    // Part 1: loaded pointer feeds the next store address.
    li    TESTNUM, 1
    sw    a1, 0(a0)
    sw    x0, 0(a1)
    sw    x0, 0(a2)
    addi  t0, a2, 0
    li    t1, 0x5a
    lw    t0, 0(a0)
    sw    t1, 0(t0)
    lw    t2, 0(a1)
    bne   t2, t1, fail
    lw    t2, 0(a2)
    bnez  t2, fail

    // Part 2: loaded value feeds the next store data.
    li    TESTNUM, 2
    li    t3, 0x12345678
    sw    t3, 4(a0)
    sw    x0, 4(a1)
    addi  t0, x0, 0
    lw    t0, 4(a0)
    sw    t0, 4(a1)
    lw    t4, 4(a1)
    bne   t4, t3, fail

    // Part 3: loaded pointer feeds the next load address.
    li    TESTNUM, 3
    li    t5, 0x2468ace0
    sw    a3, 8(a0)
    sw    t5, 0(a3)
    addi  t0, a2, 0
    lw    t0, 8(a0)
    lw    t6, 0(t0)
    bne   t6, t5, fail

    // Part 4: loaded value feeds the next branch comparison.
    li    TESTNUM, 4
    li    t1, 0x33
    sw    t1, 12(a0)
    addi  t0, x0, 0
    lw    t0, 12(a0)
    beq   t0, t1, 1f
    j     fail
1:

    // Part 5: loaded pointer feeds the next JALR target.
    li    TESTNUM, 5
    la    t1, target_jalr
    sw    t1, 16(a0)
    addi  t0, x0, 0
    lw    t0, 16(a0)
    jalr  x0, 0(t0)
    j     fail

target_jalr:
    // Part 6: loaded value feeds a slot1 ALU consumer.
    li    TESTNUM, 6
    li    t1, 0x66
    sw    t1, 20(a0)
    addi  t0, x0, 0
    .align 3
    lw    t0, 20(a0)
    addi  s0, x0, 0
    addi  s1, x0, 1
    add   t2, t0, x0
    bne   t2, t1, fail

    // Part 7: loaded pointer feeds a slot1 store address.
    li    TESTNUM, 7
    sw    a1, 24(a0)
    sw    x0, 8(a1)
    sw    x0, 8(a2)
    addi  t0, a2, 0
    li    t1, 0x77
    .align 3
    lw    t0, 24(a0)
    addi  s0, x0, 0
    addi  s1, x0, 1
    sw    t1, 8(t0)
    lw    t2, 8(a1)
    bne   t2, t1, fail
    lw    t2, 8(a2)
    bnez  t2, fail

    // Part 8: loaded value feeds slot1 store data.
    li    TESTNUM, 8
    li    t3, 0x13572468
    sw    t3, 28(a0)
    sw    x0, 12(a1)
    addi  t0, x0, 0
    .align 3
    lw    t0, 28(a0)
    addi  s0, x0, 0
    addi  s1, x0, 1
    sw    t0, 12(a1)
    lw    t4, 12(a1)
    bne   t4, t3, fail

    // Part 9: loaded pointer feeds a slot1 load address.
    li    TESTNUM, 9
    li    t5, 0x24681357
    sw    a3, 32(a0)
    sw    t5, 16(a3)
    addi  t0, a2, 0
    .align 3
    lw    t0, 32(a0)
    addi  s0, x0, 0
    addi  s1, x0, 1
    lw    t6, 16(t0)
    bne   t6, t5, fail

    // Part 10: loaded value feeds a slot1 branch comparison.
    li    TESTNUM, 10
    li    t1, 0x44
    sw    t1, 36(a0)
    addi  t0, x0, 0
    .align 3
    lw    t0, 36(a0)
    addi  s0, x0, 0
    addi  s1, x0, 1
    beq   t0, t1, 2f
    j     fail
2:

    // Part 11: loaded pointer feeds a slot1 JALR target.
    li    TESTNUM, 11
    la    t1, target_s1_jalr
    sw    t1, 40(a0)
    la    t0, fail
    .align 3
    lw    t0, 40(a0)
    addi  s0, x0, 0
    addi  s1, x0, 1
    jalr  x0, 0(t0)
    j     fail

target_s1_jalr:
    // Part 12: slot1 load feeds a slot0 ALU consumer.
    li    TESTNUM, 12
    li    t1, 0x1212
    sw    t1, 44(a0)
    addi  t0, x0, 0
    .align 3
    addi  s0, x0, 0
    lw    t0, 44(a0)
    add   t2, t0, x0
    addi  s1, x0, 1
    bne   t2, t1, fail

    // Part 13: slot1 load feeds a slot1 ALU consumer.
    li    TESTNUM, 13
    li    t1, 0x1313
    sw    t1, 48(a0)
    addi  t0, x0, 0
    .align 3
    addi  s0, x0, 0
    lw    t0, 48(a0)
    addi  s1, x0, 1
    add   t2, t0, x0
    bne   t2, t1, fail

    // Part 14: slot1 load feeds a slot0 store address.
    li    TESTNUM, 14
    sw    a1, 52(a0)
    sw    x0, 20(a1)
    sw    x0, 20(a2)
    addi  t0, a2, 0
    li    t1, 0x1414
    .align 3
    addi  s0, x0, 0
    lw    t0, 52(a0)
    sw    t1, 20(t0)
    addi  s1, x0, 1
    lw    t2, 20(a1)
    bne   t2, t1, fail
    lw    t2, 20(a2)
    bnez  t2, fail

    // Part 15: slot1 load feeds slot1 store data.
    li    TESTNUM, 15
    li    t3, 0x15151515
    sw    t3, 56(a0)
    sw    x0, 24(a1)
    addi  t0, x0, 0
    .align 3
    addi  s0, x0, 0
    lw    t0, 56(a0)
    addi  s1, x0, 1
    sw    t0, 24(a1)
    lw    t4, 24(a1)
    bne   t4, t3, fail

    // Part 16: slot1 load feeds a slot1 load address.
    li    TESTNUM, 16
    li    t5, 0x16161616
    sw    a3, 60(a0)
    sw    t5, 28(a3)
    addi  t0, a2, 0
    .align 3
    addi  s0, x0, 0
    lw    t0, 60(a0)
    addi  s1, x0, 1
    lw    t6, 28(t0)
    bne   t6, t5, fail

    // Part 17: slot1 load feeds a slot1 branch comparison.
    li    TESTNUM, 17
    li    t1, 0x1717
    sw    t1, 64(a0)
    addi  t0, x0, 0
    .align 3
    addi  s0, x0, 0
    lw    t0, 64(a0)
    addi  s1, x0, 1
    beq   t0, t1, 3f
    j     fail
3:

    // Part 18: slot1 load feeds a slot1 JALR target.
    li    TESTNUM, 18
    la    t1, target_s1_load_jalr
    sw    t1, 68(a0)
    la    t0, fail
    .align 3
    addi  s0, x0, 0
    lw    t0, 68(a0)
    addi  s1, x0, 1
    jalr  x0, 0(t0)
    j     fail

target_s1_load_jalr:
    // Part 19: a Slot1 load returns the critical word of a cold line, followed
    // by a younger load from the same line and a repaired JALR. Refill can hold
    // JALR in EX for several cycles, so non-completing MEM cycles must preserve
    // the registered repair payload.
    li    TESTNUM, 19
    la    a4, held_refill_line
    li    ra, 0
    .align 3
    addi  s3, x0, 0
    lw    ra, 12(a4)
    lw    s0, 8(a4)
    addi  s1, x0, 1
    jalr  x0, 0(ra)
    j     fail

target_held_jalr:
    li    t2, 0x1919
    bne   s0, t2, fail
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.space 512
.align 4
held_refill_line:
    .word 0
    .word 0
    .word 0x00001919
    .word target_held_jalr
RVTEST_DATA_END
