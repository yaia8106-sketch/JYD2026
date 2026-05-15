#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    .align 3
dual_start:
    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0

    addi  t0, x0, 7
    addi  t1, x0, 5
    add   t4, t0, t1
    addi  t4, t4, 0
    addi  t4, t4, 0
    addi  t4, t4, 0

    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0

    sub   t2, s1, s0
    li    t3, 1
    bne   t2, t3, fail_count

    li    t3, 12
    bne   t4, t3, fail_value

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
