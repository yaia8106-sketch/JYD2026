#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060
#define SEG_MMIO_ADDR 0x80200020

// Test: Slot0 ordinary ALU + Slot1 store shares the single LSU port.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    li    t6, DUAL_CNT_ADDR

    // Prepare cacheable scratch words.
    sw    x0, 0(a0)
    sw    x0, 4(a0)
    sw    x0, 16(a0)
    sw    x0, 20(a0)
    sw    x0, 24(a0)
    sw    x0, 28(a0)

    li    t0, 0x5a
    li    t1, 0x1234
    li    t2, 0x13579bdf

    // Counter snapshot before the intended Slot1 store pairs.
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0

    // Three cacheable Slot1 stores: byte, half, word.
    .align 3
    addi  s1, x0, 1
    sb    t0, 0(a0)
    addi  s2, x0, 2
    sh    t1, 2(a0)
    addi  s3, x0, 3
    sw    t2, 4(a0)

    addi  s4, x0, 4
    addi  s5, x0, 5
    addi  s6, x0, 6

    lw    s7, 0(t6)
    addi  s7, s7, 0
    addi  s7, s7, 0
    sub   s8, s7, s0
    li    s9, 3
    blt   s8, s9, fail_count

    li    TESTNUM, 2
    lw    t3, 0(a0)
    li    t4, 0x1234005a
    bne   t3, t4, fail

    li    TESTNUM, 3
    lw    t3, 4(a0)
    bne   t3, t2, fail

    // Same-pair RAW on store address must serialize.
    li    TESTNUM, 4
    addi  a1, a0, 0
    li    t3, 0x2468ace0
    .align 3
    addi  a1, a0, 16
    sw    t3, 0(a1)
    lw    t4, 16(a0)
    bne   t4, t3, fail

    // Same-pair RAW on store data must serialize.
    li    TESTNUM, 5
    addi  t3, x0, 0
    .align 3
    addi  t3, x0, 0x77
    sw    t3, 20(a0)
    lw    t4, 20(a0)
    bne   t4, t3, fail

    // Store data loaded by the immediately previous load must stall until ready.
    li    TESTNUM, 6
    lw    t5, 4(a0)
    .align 3
    addi  s10, x0, 10
    sw    t5, 24(a0)
    lw    t4, 24(a0)
    bne   t4, t2, fail

    // Slot0 LSU + Slot1 store remains serialized; the store still executes later.
    li    TESTNUM, 7
    .align 3
    lw    t5, 4(a0)
    sw    t2, 28(a0)
    lw    t4, 28(a0)
    bne   t4, t2, fail

    // Uncacheable Slot1 store uses the shared MMIO write path.
    li    TESTNUM, 8
    li    a2, SEG_MMIO_ADDR
    li    t3, 0x00000abc
    .align 3
    addi  s11, x0, 11
    sw    t3, 0(a2)
    lw    t4, 0(a2)
    bne   t4, t3, fail

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
