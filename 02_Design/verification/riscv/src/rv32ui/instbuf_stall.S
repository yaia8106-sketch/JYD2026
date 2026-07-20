#include "riscv_test.h"

// Test: Instruction buffer + pipeline stall interaction
// Scenario 1: inst_buf valid → pipeline stalls (load-use) → buf survives
// Scenario 2: inst_buf valid → pipeline stalls (cache miss) → buf survives
// Scenario 3: inst_buf filled, then consumed, then re-filled in rapid succession

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    li    t0, 100
    sw    t0, 0(a0)

    // ================================================================
    // Part 1: Single-issue (sw in S0) → S1 buffered
    //         Next cycle: buffered inst becomes S0, triggers load-use stall
    //         Verify buffered instruction executes correctly after stall.
    // ================================================================
    .align 3
    li    TESTNUM, 1
    addi  t1, x0, 0
    addi  t2, x0, 0

    // lw t1 first (to set up load-use dependency)
    lw    t1, 0(a0)           // t1 = 100 (this is a load)
    // Buffered instruction from single-issue will depend on t1:
    // Actually we need sw to trigger single-issue. Let me restructure.

    // sw forces single-issue → S1 goes to inst_buf
    li    t0, 200
    sw    t0, 4(a0)           // S0: store → single-issue
    // S1 position: this becomes inst_buf
    lw    t2, 4(a0)           // buffered → next cycle becomes S0 (load)
    // The buffered lw issues as S0. Next instruction may depend on it:
    add   t3, t2, x0         // reads t2 → load-use stall!
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    li    t4, 200
    bne   t2, t4, fail
    li    TESTNUM, 2
    bne   t3, t4, fail        // t3 = t2 = 200

    // ================================================================
    // Part 2: Rapid buffer fill-consume-fill chain
    // sw → buf → consume as S0 → sw again → buf → consume
    // Tests that inst_buf_valid toggles correctly across cycles.
    // ================================================================
    .align 3
    li    TESTNUM, 3
    addi  t1, x0, 0
    addi  t2, x0, 0
    addi  t3, x0, 0

    // First sw → S1 buffered
    li    t0, 0x11
    sw    t0, 8(a0)           // S0: store → single-issue
    addi  t1, x0, 0x22       // S1 position → buffered
    // Next cycle: t1=0x22 issued from buffer as S0
    // S1 position from new fetch:
    // addi t0,x0,0x33 is next instruction in memory
    li    t0, 0x33
    sw    t0, 12(a0)          // S0: another store → single-issue
    addi  t2, x0, 0x44       // S1 position → buffered again
    // Next cycle: t2=0x44 from buffer
    addi  t3, x0, 0x55       // next instruction

    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    li    t4, 0x22
    bne   t1, t4, fail

    li    TESTNUM, 4
    li    t4, 0x44
    bne   t2, t4, fail

    li    TESTNUM, 5
    li    t4, 0x55
    bne   t3, t4, fail

    // Verify stores went through
    li    TESTNUM, 6
    lw    t1, 8(a0)
    addi  t1, t1, 0
    addi  t1, t1, 0
    addi  t1, t1, 0
    li    t4, 0x11
    bne   t1, t4, fail

    li    TESTNUM, 7
    lw    t2, 12(a0)
    addi  t2, t2, 0
    addi  t2, t2, 0
    addi  t2, t2, 0
    li    t4, 0x33
    bne   t2, t4, fail

    // ================================================================
    // Part 3: inst_buf + branch prediction redirect
    // If BP predicts taken on the buffered instruction's fetch cycle,
    // the buffer should still work correctly.
    // ================================================================
    .align 3
    li    TESTNUM, 8
    addi  t0, x0, 0
    addi  t1, x0, 0

    // Create a loop so BP learns the branch direction
    li    t5, 3
    li    t6, 0
loop_bp:
    sw    t6, 16(a0)          // S0: store → single-issue
    addi  t0, x0, 42          // S1 → buffered, then issued next cycle
    addi  t6, t6, 1
    bne   t6, t5, loop_bp
    // After loop: t0=42, t6=3

    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    li    t4, 42
    bne   t0, t4, fail

    li    TESTNUM, 9
    li    t4, 3
    bne   t6, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
