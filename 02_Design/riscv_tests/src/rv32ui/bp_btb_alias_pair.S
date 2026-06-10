#include "riscv_test.h"

// Branch diagnosis: two always-taken conditional branches at the same
// direct-mapped BTB index and different tags.  On the current 128-entry BTB,
// PC[8:2] selects the index, so 512-byte alignment creates an intentional
// index conflict between alias_a and alias_b.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    TESTNUM, 1
    li    t0, 0
    li    t1, 128
    li    s0, 0

    j     alias_a

    .balign 512
alias_a:
    beq   x0, x0, alias_a_taken
    j     fail

alias_a_taken:
    addi  s0, s0, 1
    j     alias_b

    .balign 512
alias_b:
    beq   x0, x0, alias_b_taken
    j     fail

alias_b_taken:
    addi  s0, s0, 1
    addi  t0, t0, 1
    bne   t0, t1, alias_a

    li    t2, 256
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
