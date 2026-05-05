#include "riscv_test.h"

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    sw    x0, 4(a0)

    .align 3
buffer_start:
    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0

    addi  t0, x0, 0x5a
    sw    t0, 4(a0)
    lw    t1, 4(a0)
    addi  t1, t1, 0
    addi  t1, t1, 0
    addi  t1, t1, 0

    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0

    // Odd-PC fetch can now create legal dual-issue pairs around this region.
    // The value check below is the real inst_buf assertion: the buffered load
    // must execute in order and observe the store.
    sub   t2, s1, s0
    addi  t2, t2, 0
    li    t3, 0x5a
    bne   t1, t3, fail_value

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
