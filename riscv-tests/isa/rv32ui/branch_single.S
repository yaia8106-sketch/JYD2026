#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    t0, 0

    .align 3
branch_start:
    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0

    beq   x0, x0, branch_taken
    addi  t0, x0, 99

branch_taken:
    addi  t0, t0, 0
    addi  t0, t0, 0
    addi  t0, t0, 0
    addi  t0, t0, 0

    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0

    sub   t2, s1, s0
    bnez  t2, fail_count
    bnez  t0, fail_value

pass:
    RVTEST_PASS

fail_count:
    li    TESTNUM, 1
    j     fail

fail_value:
    li    TESTNUM, 2
    j     fail

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
