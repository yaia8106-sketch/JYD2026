#include "riscv_test.h"

// Test: Branch+ALU dual-issue with misprediction flush
// Verifies that slot1 ALU result is killed when slot0 branch mispredicts.

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: Train BP not-taken, then take the branch.
    // slot1 ALU (addi t2, x0, 0xFF) must NOT commit on misprediction.
    // ================================================================
    li    TESTNUM, 1
    addi  t2, x0, 0           // t2 = 0 (sentinel)
    addi  t0, x0, 0           // loop counter
    li    t4, 6               // train 6 iterations not-taken

    // Train BP: branch is not-taken for 6 iterations
    .align 3
train_nt:
    addi  t0, t0, 1
    bne   t0, t4, train_nt_body
    j     train_nt_done
    .align 3
train_nt_body:
    // not-taken branch + ALU pair (harmless writes to t3)
    bne   t0, t4, train_nt_skip   // always not-taken (t0 != t4 until last)
    addi  t3, x0, 0              // slot1: harmless
    .align 3
train_nt_skip:
    j     train_nt

train_nt_done:
    // Now BP should predict this branch not-taken, but we force taken.
    // If dual-issue fires, slot1 writes t2=0xFF. Flush must kill it.
    addi  t0, x0, 1
    addi  t1, x0, 1
    .align 3
    beq   t0, t1, mispred_target1  // actually taken (BP may predict not-taken)
    addi  t2, x0, 0xFF            // slot1: MUST be killed by flush

    .align 3
mispred_target1:
    // Drain pipeline
    addi  s0, x0, 0
    addi  s0, x0, 0
    addi  s0, x0, 0
    addi  s0, x0, 0

    // t2 must still be 0 (slot1 was killed)
    bnez  t2, fail

    // ================================================================
    // Part 2: Verify correct-path execution after flush recovery.
    // After misprediction, subsequent instructions must work normally.
    // ================================================================
    li    TESTNUM, 2
    addi  t0, x0, 10
    addi  t1, x0, 20
    add   t2, t0, t1          // t2 = 30
    li    t3, 30
    bne   t2, t3, fail

    // ================================================================
    // Part 3: Repeated misprediction with accumulator.
    // Loop where branch trains one direction then switches.
    // Accumulator must be exactly correct despite flushes.
    // ================================================================
    li    TESTNUM, 3
    addi  s0, x0, 0           // accumulator
    addi  t0, x0, 0           // outer counter
    li    t5, 4               // outer limit

    .align 3
outer_loop:
    // Inner: train branch taken 4 times, then not-taken on 5th
    addi  t1, x0, 0           // inner counter
    li    t4, 5               // inner limit
    .align 3
inner_loop:
    addi  t1, t1, 1
    addi  s0, s0, 1           // acc += 1
    bne   t1, t4, inner_loop  // taken 4 times, not-taken on 5th

    addi  t0, t0, 1
    bne   t0, t5, outer_loop

    // s0 should be 4 * 5 = 20
    li    t3, 20
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
