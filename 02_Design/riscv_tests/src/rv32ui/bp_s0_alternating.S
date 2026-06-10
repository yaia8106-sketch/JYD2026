#include "riscv_test.h"

// Branch diagnosis: one S0 branch alternates taken/not-taken by iteration.
// This should not collapse into a one-sided dir_to_taken failure.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    TESTNUM, 1
    li    t0, 0
    li    t1, 512
    li    s0, 0

    .align 3
bp_s0_alt_loop:
    andi  t2, t0, 1
    bnez  t2, bp_s0_alt_taken
    addi  s0, s0, 1
    j     bp_s0_alt_join

bp_s0_alt_taken:
    addi  s0, s0, 2

bp_s0_alt_join:
    addi  t0, t0, 1
    bne   t0, t1, bp_s0_alt_loop

    li    t3, 768
    bne   s0, t3, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
