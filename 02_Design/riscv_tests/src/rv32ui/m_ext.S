#include "riscv_test.h"

#define CHECK_REG(testnum, reg, expected) \
    li TESTNUM, testnum;                  \
    li t6, expected;                      \
    bne reg, t6, fail;

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // MUL low word
    li   t0, 0x12345678
    li   t1, 0x00001000
    mul  t2, t0, t1
    CHECK_REG(1, t2, 0x45678000)

    li   t0, 0x80000000
    li   t1, 2
    mul  t2, t0, t1
    CHECK_REG(2, t2, 0x00000000)

    li   t0, -1
    li   t1, 2
    mul  t2, t0, t1
    CHECK_REG(3, t2, 0xfffffffe)

    // MULH signed high word
    li   t0, -1
    li   t1, -1
    mulh t2, t0, t1
    CHECK_REG(4, t2, 0x00000000)

    li   t0, -1
    li   t1, 2
    mulh t2, t0, t1
    CHECK_REG(5, t2, 0xffffffff)

    li   t0, 0x80000000
    li   t1, 2
    mulh t2, t0, t1
    CHECK_REG(6, t2, 0xffffffff)

    li   t0, 0x7fffffff
    li   t1, 2
    mulh t2, t0, t1
    CHECK_REG(7, t2, 0x00000000)

    // MULHU unsigned high word
    li    t0, 0xffffffff
    li    t1, 0xffffffff
    mulhu t2, t0, t1
    CHECK_REG(8, t2, 0xfffffffe)

    li    t0, 0x80000000
    li    t1, 2
    mulhu t2, t0, t1
    CHECK_REG(9, t2, 0x00000001)

    li    t0, 0x12345678
    li    t1, 0x00001000
    mulhu t2, t0, t1
    CHECK_REG(10, t2, 0x00000123)

    // MULHSU signed x unsigned high word
    li     t0, -1
    li     t1, 2
    mulhsu t2, t0, t1
    CHECK_REG(11, t2, 0xffffffff)

    li     t0, -1
    li     t1, 0xffffffff
    mulhsu t2, t0, t1
    CHECK_REG(12, t2, 0xffffffff)

    li     t0, 2
    li     t1, 0xffffffff
    mulhsu t2, t0, t1
    CHECK_REG(13, t2, 0x00000001)

    li     t0, 0x80000000
    li     t1, 2
    mulhsu t2, t0, t1
    CHECK_REG(14, t2, 0xffffffff)

    // DIV signed quotient
    li   t0, 7
    li   t1, 3
    div  t2, t0, t1
    CHECK_REG(20, t2, 2)

    li   t0, -7
    li   t1, 3
    div  t2, t0, t1
    CHECK_REG(21, t2, 0xfffffffe)

    li   t0, 7
    li   t1, -3
    div  t2, t0, t1
    CHECK_REG(22, t2, 0xfffffffe)

    li   t0, -7
    li   t1, -3
    div  t2, t0, t1
    CHECK_REG(23, t2, 2)

    li   t0, 0x80000000
    li   t1, -1
    div  t2, t0, t1
    CHECK_REG(24, t2, 0x80000000)

    li   t0, 0x12345678
    li   t1, 0
    div  t2, t0, t1
    CHECK_REG(25, t2, 0xffffffff)

    li   t0, 0x80000000
    li   t1, 1
    div  t2, t0, t1
    CHECK_REG(26, t2, 0x80000000)

    li   t0, 1
    li   t1, 0x80000000
    div  t2, t0, t1
    CHECK_REG(27, t2, 0)

    // DIVU unsigned quotient
    li    t0, 0xffffffff
    li    t1, 2
    divu  t2, t0, t1
    CHECK_REG(30, t2, 0x7fffffff)

    li    t0, 0x80000000
    li    t1, 2
    divu  t2, t0, t1
    CHECK_REG(31, t2, 0x40000000)

    li    t0, 7
    li    t1, 0
    divu  t2, t0, t1
    CHECK_REG(32, t2, 0xffffffff)

    li    t0, 0
    li    t1, 5
    divu  t2, t0, t1
    CHECK_REG(33, t2, 0)

    // REM signed remainder
    li   t0, 7
    li   t1, 3
    rem  t2, t0, t1
    CHECK_REG(40, t2, 1)

    li   t0, -7
    li   t1, 3
    rem  t2, t0, t1
    CHECK_REG(41, t2, 0xffffffff)

    li   t0, 7
    li   t1, -3
    rem  t2, t0, t1
    CHECK_REG(42, t2, 1)

    li   t0, -7
    li   t1, -3
    rem  t2, t0, t1
    CHECK_REG(43, t2, 0xffffffff)

    li   t0, 0x80000000
    li   t1, -1
    rem  t2, t0, t1
    CHECK_REG(44, t2, 0)

    li   t0, 0x12345678
    li   t1, 0
    rem  t2, t0, t1
    CHECK_REG(45, t2, 0x12345678)

    li   t0, 0x80000000
    li   t1, 3
    rem  t2, t0, t1
    CHECK_REG(46, t2, 0xfffffffe)

    // REMU unsigned remainder
    li    t0, 0xffffffff
    li    t1, 2
    remu  t2, t0, t1
    CHECK_REG(50, t2, 1)

    li    t0, 0x80000000
    li    t1, 3
    remu  t2, t0, t1
    CHECK_REG(51, t2, 2)

    li    t0, 0x12345678
    li    t1, 0
    remu  t2, t0, t1
    CHECK_REG(52, t2, 0x12345678)

    li    t0, 0
    li    t1, 5
    remu  t2, t0, t1
    CHECK_REG(53, t2, 0)

    // Result bypass after multi-cycle operations
    li   t0, 6
    li   t1, 7
    mul  t2, t0, t1
    addi t3, t2, 5
    CHECK_REG(60, t3, 47)

    li   t0, 100
    li   t1, 7
    div  t2, t0, t1
    add  t3, t2, t2
    CHECK_REG(61, t3, 28)

    rem  t2, t0, t1
    addi t3, t2, 3
    CHECK_REG(62, t3, 5)

    // Back-to-back M operations
    li   t0, 6
    li   t1, 7
    mul  t2, t0, t1
    div  t3, t2, t0
    rem  t4, t2, t1
    add  t5, t2, t3
    add  t5, t5, t4
    CHECK_REG(63, t5, 49)

    // Operands from DCache/load path
    la   t0, m_data
    lw   t1, 0(t0)
    lw   t2, 4(t0)
    mul  t3, t1, t2
    CHECK_REG(64, t3, 0xffffffe5)

    div  t4, t3, t2
    CHECK_REG(65, t4, 9)

    rem  t5, t3, t1
    CHECK_REG(66, t5, 0)

    // Dependent MUL chains exercise result forwarding into the local DSP input
    // registers on the ID/EX acceptance edge. Each younger instruction must
    // receive the previous result before launching its one-wait-cycle MUL.
    li   t0, 3
    li   t1, 5
    mul  t2, t0, t1
    mul  t3, t2, t1
    mul  t4, t3, t0
    CHECK_REG(67, t4, 225)

    // A MUL immediately following DIV must receive the completed DIV result
    // and launch cleanly after the unit returns to idle.
    li   t0, 100
    li   t1, 7
    div  t2, t0, t1
    mul  t3, t2, t1
    CHECK_REG(68, t3, 98)

    // A variable shift in Slot 0 is the longest ordinary EX forwarding
    // producer. The immediately dependent MUL must take the dedicated raw-ALU
    // fast path without adding an issue bubble.
    li   t0, 3
    li   t1, 4
    .align 3
    sll  t2, t0, t1
    addi t6, x0, 0
    mul  t3, t2, t1
    CHECK_REG(69, t3, 192)

    // Force a load-repaired ALU into Slot 1, followed immediately by a MUL.
    // This exercises the other reported EX-to-DSP critical-path family.
    la   t0, m_data
    .align 3
    lw   t1, 0(t0)
    addi t6, x0, 0
    addi t5, x0, 1
    addi t2, t1, 4
    mul  t3, t2, t1
    CHECK_REG(72, t3, 117)

    // M instruction in the slot1 fetch position must be buffered and then
    // executed as slot0, not as a Slot1 ALU instruction.
    li   t0, 11
    li   t1, 12
    .align 3
    addi s0, x0, 123
    mul  s1, t0, t1
    addi s2, s1, 1
    CHECK_REG(70, s2, 133)

    // Wrong-path M operation after a taken branch must not commit.
    li   t0, 2
    li   t1, 3
    li   t2, 55
    beq  x0, x0, 1f
    mul  t2, t0, t1
    addi t2, t2, 99
1:
    CHECK_REG(71, t2, 55)

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
m_data:
    .word 9
    .word 0xfffffffd
RVTEST_DATA_END
