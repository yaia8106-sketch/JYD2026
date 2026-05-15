#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // Prepare operands before taking the dual-issue counter snapshot.
    addi  t0, x0, 1
    addi  t1, x0, 2

    // A cold not-taken conditional branch can now dual-issue with slot1 ALU.
    .align 3
    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0

    bne   t0, t0, fail_value_nt
    addi  t1, t1, 5

    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0

    sub   t2, s1, s0
    li    t3, 1
    bne   t2, t3, fail_count_nt

    li    t3, 7
    bne   t1, t3, fail_value_nt

    // A cold taken branch may be fetched sequentially, but its slot1 ALU is
    // wrong-path and must be killed by the EX-stage branch flush.
    addi  t0, x0, 1
    addi  t1, x0, 0

    .align 3
    beq   t0, t0, taken_target
    addi  t1, x0, 99

taken_target:
    addi  t2, t1, 1
    addi  t2, t2, 0
    addi  t2, t2, 0

    li    t3, 1
    bne   t2, t3, fail_taken_flush
    bnez  t1, fail_taken_flush

pass:
    RVTEST_PASS

fail_count_nt:
    li    TESTNUM, 1
    j     fail

fail_value_nt:
    li    TESTNUM, 2
    j     fail

fail_taken_flush:
    li    TESTNUM, 3
    j     fail

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
