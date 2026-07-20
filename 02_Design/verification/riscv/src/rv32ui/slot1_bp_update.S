#include "riscv_test.h"

// Slot1 branch predictor update coverage.
//
// The loop head is 8-byte aligned so the filler ALU instruction sits in slot0
// and the loop branch sits in slot1.  The simulation harness checks that this
// slot1 branch both updates the predictor and later gets predicted-taken from
// the slot1 candidate metadata path.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    TESTNUM, 1
    li    t0, 0
    li    t1, 40
    li    s0, 0

    .align 3
s1_bp_loop:
    addi  s0, s0, 1
    bne   t0, t1, s1_bp_body
    j     s1_bp_done

s1_bp_body:
    addi  t0, t0, 1
    j     s1_bp_loop

s1_bp_done:
    li    t2, 40
    bne   t0, t2, fail

    li    TESTNUM, 2
    li    t2, 41
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
