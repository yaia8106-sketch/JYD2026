#include "riscv_test.h"

// Direct-mapped BTB conflict regression:
// train a taken branch, then execute a load at a different PC with the same
// BTB index (PC[8:2]) but a different tag (PC[13:9]).  The stale BTB target
// must not redirect the non-branch load.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    la    a0, alias_word

    // Part 1: train a taken conditional branch.
    li    TESTNUM, 1
    li    s0, 8

    .balign 512
train_branch:
    addi  s0, s0, -1
    bnez  s0, train_taken
    j     train_done
train_taken:
    j     train_branch

train_done:
    // Part 2: same BTB index, different tag.  This first instruction is a
    // cold data load so stale-target misuse would combine BP and DCache state.
    li    TESTNUM, 2

    .balign 512
victim_same_index:
    lw    t0, 0(a0)
    li    t1, 0x1BADB002
    bne   t0, t1, fail

    li    TESTNUM, 3
    addi  s1, x0, 1
    bne   s1, x0, pass

fail:
    RVTEST_FAIL

pass:
    RVTEST_PASS

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
alias_word:
    .word 0x1BADB002
RVTEST_DATA_END
