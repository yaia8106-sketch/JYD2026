#include "riscv_test.h"

// Branch diagnosis: one hot S0 backward conditional branch.
// Expected after warmup: high BTB hit, pred_taken close to actual_taken,
// and only a few dir_to_taken misses before the 2-bit state converges.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    TESTNUM, 1
    li    t0, 0
    li    t1, 512
    li    s0, 0

    .align 3
bp_s0_taken_loop:
    addi  t0, t0, 1
    addi  s0, s0, 1
    bne   t0, t1, bp_s0_taken_loop

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
