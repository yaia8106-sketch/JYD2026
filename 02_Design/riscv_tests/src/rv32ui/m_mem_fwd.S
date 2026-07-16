#include "riscv_test.h"

#define CHECK_REG(testnum, reg, expected) \
    li TESTNUM, testnum;                  \
    li t6, expected;                      \
    bne reg, t6, fail;

// Directed coverage for the registered MUL result rendezvous in MEM.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // An aligned multiplier occupies Slot 0 while an independent ALU uses
    // Slot 1. The following dependent add must wait for, then consume, MEM
    // forwarding rather than an early EX value.
    li   t0, 6
    li   t1, 7
    .align 3
    mul  s0, t0, t1
    addi s1, x0, 5
    add  s2, s0, s1
    CHECK_REG(1, s0, 42)
    CHECK_REG(2, s1, 5)
    CHECK_REG(3, s2, 47)

    // A younger Slot 1 WAW producer must retain priority over the Slot 0 MUL
    // in EX, MEM, and the dual-write register file.
    li   t0, 3
    li   t1, 4
    .align 3
    mul  s3, t0, t1
    addi s3, x0, 77
    addi s4, s3, 1
    CHECK_REG(4, s4, 78)

    // Pair the multiplier with a cold-miss load. The MUL result owner must
    // remain stable for the full MEM backpressure interval. A dependent MUL
    // also verifies that a new M owner cannot overwrite the held product and
    // that its DSP operands receive the old product through MEM forwarding.
    la   a0, hold_line
    li   t0, 9
    li   t1, 11
    .align 3
    mul  s5, t0, t1
    lw   s6, 0(a0)
    mul  s7, s5, t0
    CHECK_REG(5, s5, 99)
    CHECK_REG(6, s6, 0x12345678)
    CHECK_REG(7, s7, 891)

    // The younger Slot 1 branch redirects after the older MUL has entered
    // MEM. The flush must not discard the older registered result.
    li   t0, 4
    li   t1, 5
    .align 3
    mul  s8, t0, t1
    beq  x0, x0, 1f
    addi s8, x0, 99
1:
    addi s9, s8, 1
    CHECK_REG(8, s9, 21)

    // High-half selection uses the same MEM forwarding path.
    li   t0, -1
    li   t1, 2
    .align 3
    mulh s10, t0, t1
    addi s11, x0, 9
    xor  a1, s10, s11
    CHECK_REG(9, s10, 0xffffffff)
    CHECK_REG(10, a1, 0xfffffff6)

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 6
hold_line:
    .word 0x12345678
    .word 0x89abcdef
    .word 0x0badcafe
    .word 0x55aa55aa
RVTEST_DATA_END
