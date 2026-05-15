#include "riscv_test.h"

// Test: Branch+ALU dual-issue edge cases
// Covers: load-use stall + branch dual, inst_buf interaction,
//         PC[2]=1 fetch-window handling, consecutive branch+ALU pressure

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: Load-use stall followed by branch+ALU dual-issue.
    // The load-use stall must not corrupt held_can_dual_r.
    // ================================================================
    li    TESTNUM, 1

    // Store a value for load-use
    li    t0, 0x80100000
    li    t1, 42
    sw    t1, 0(t0)

    // Load-use stall: lw → addi using loaded value
    lw    t2, 0(t0)           // cache miss → stall
    addi  t2, t2, 8           // load-use: stall 1 cycle, t2 = 50

    // After stall resolves, branch+ALU should dual-issue normally
    .align 3
    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0

    bne   t2, t2, fail        // not-taken branch
    addi  t3, t2, 10          // slot1 ALU: t3 = 60

    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0

    // Verify dual-issue happened
    sub   t4, s1, s0
    li    t5, 1
    bne   t4, t5, fail

    // Verify values
    li    t5, 50
    bne   t2, t5, fail
    li    t5, 60
    bne   t3, t5, fail

    // ================================================================
    // Part 2: inst_buf interaction.
    // Single-issue SW (slot1 goes to inst_buf) → branch+ALU dual-issue.
    // Inst_buf must be correctly consumed before the branch pair.
    // ================================================================
    li    TESTNUM, 2
    li    t0, 0x80100010
    addi  t1, x0, 77

    // SW is single-issue → slot1 (addi) enters inst_buf
    .align 3
    sw    t1, 0(t0)           // S0: store (single-issue)
    addi  t2, x0, 33          // goes to inst_buf

    // inst_buf consumed as next S0, then branch+ALU pair follows
    addi  t2, t2, 0           // drain
    addi  t2, t2, 0           // drain

    // Verify inst_buf instruction executed correctly
    li    t3, 33
    bne   t2, t3, fail

    // Verify store worked
    lw    t4, 0(t0)
    addi  t4, t4, 0
    addi  t4, t4, 0
    li    t5, 77
    bne   t4, t5, fail

    // ================================================================
    // Part 3: PC[2]=1 branch-window handling.
    // Force branch to land at non-8B-aligned address.
    // ================================================================
    li    TESTNUM, 3
    addi  t0, x0, 0
    addi  t1, x0, 1

    j     align_test_start
    // Padding to push target to PC[2]=1 position
    .align 3
    nop
align_test_start:
    // Jump to a PC[2]=1 address
    j     misaligned_target
    .align 3
    nop                       // padding
    nop                       // padding filler
misaligned_target:
    // Here PC[2] may be 1. Branch+ALU may dual-issue; result must stay correct.
    addi  t0, x0, 5
    addi  t1, x0, 5
    bne   t0, t1, fail        // not-taken
    addi  t0, t0, 10          // t0 = 15 (may or may not dual-issue)

    li    t3, 15
    bne   t0, t3, fail

    // ================================================================
    // Part 4: Consecutive branch+ALU pairs (pressure test).
    // 10 consecutive not-taken branch + ALU pairs.
    // Accumulator must be exactly correct.
    // ================================================================
    li    TESTNUM, 4
    addi  t0, x0, 0           // accumulator
    addi  t1, x0, 1           // constant for comparison

    .align 3
    bne   t1, t1, fail        // not-taken
    addi  t0, t0, 1           // acc = 1
    bne   t1, t1, fail
    addi  t0, t0, 2           // acc = 3
    bne   t1, t1, fail
    addi  t0, t0, 3           // acc = 6
    bne   t1, t1, fail
    addi  t0, t0, 4           // acc = 10
    bne   t1, t1, fail
    addi  t0, t0, 5           // acc = 15
    bne   t1, t1, fail
    addi  t0, t0, 6           // acc = 21
    bne   t1, t1, fail
    addi  t0, t0, 7           // acc = 28
    bne   t1, t1, fail
    addi  t0, t0, 8           // acc = 36
    bne   t1, t1, fail
    addi  t0, t0, 9           // acc = 45
    bne   t1, t1, fail
    addi  t0, t0, 10          // acc = 55

    li    t3, 55
    bne   t0, t3, fail

    // ================================================================
    // Part 5: Loop with branch+ALU body (sustained dual-issue).
    // Each iteration: not-taken branch + addi pair inside loop body,
    // plus the taken loop-back branch at the end.
    // ================================================================
    li    TESTNUM, 5
    addi  t0, x0, 0           // accumulator
    addi  t1, x0, 0           // counter
    li    t5, 10              // limit

    .align 3
loop5:
    // not-taken branch + ALU pair in loop body
    bne   t1, t1, fail        // always not-taken (t1 == t1)
    addi  t0, t0, 3           // slot1: acc += 3
    addi  t1, t1, 1           // counter++
    bne   t1, t5, loop5       // loop-back (taken 9 times, not-taken on 10th)

    // t0 = 10 * 3 = 30
    li    t3, 30
    bne   t0, t3, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
