#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    li    t0, 37
    sw    t0, 0(a0)

    .align 3
load_start:
    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0

    lw    t1, 0(a0)
    addi  t2, x0, 5
    add   t3, t1, t2
    addi  t3, t3, 0
    addi  t3, t3, 0
    addi  t3, t3, 0

    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0

    sub   t4, s1, s0
    li    t5, 1
    bne   t4, t5, fail_count
    li    t5, 42
    bne   t3, t5, fail_value

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
