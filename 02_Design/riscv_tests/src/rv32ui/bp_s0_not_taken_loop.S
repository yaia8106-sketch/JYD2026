#include "riscv_test.h"

// Branch diagnosis: repeatedly execute the same S0 branch as not-taken.
// The loop-back branch is intentionally separate; use hot-PC trace when
// isolating the probe branch from aggregate loop-control counters.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    TESTNUM, 1
    li    t0, 0
    li    t1, 512
    li    s0, 0

    .align 3
bp_s0_nt_loop:
    bne   x0, x0, fail
    addi  s0, s0, 1
    addi  t0, t0, 1
    bne   t0, t1, bp_s0_nt_loop

    li    t2, 512
    bne   s0, t2, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
