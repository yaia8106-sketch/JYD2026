#include "riscv_test.h"

// Branch diagnosis: an older taken branch skips over a victim branch.  While
// wrong-path, the victim would be taken because t3=1.  The final correct-path
// probe executes the same victim PC with t3=0, so any wrong-path predictor
// update tends to show up as a taken prediction for an actual fall-through.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    TESTNUM, 1
    li    t0, 0
    li    t1, 64
    li    t2, 0              // probe phase flag
    li    t3, 1              // wrong-path victim direction would be taken
    li    s0, 0

    .align 3
poison_loop:
    beq   x0, x0, poison_taken

victim_branch:
    bnez  t3, victim_taken
    addi  s0, s0, 1
    bnez  t2, victim_done
    j     fail

victim_taken:
    j     fail

poison_taken:
    addi  t0, t0, 1
    bne   t0, t1, poison_loop

    li    t3, 0              // correct-path victim direction is fall-through
    li    t2, 1
    j     victim_branch

victim_done:
    li    t4, 1
    bne   s0, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
