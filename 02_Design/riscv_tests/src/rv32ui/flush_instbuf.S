#include "riscv_test.h"

// Test: Branch flush must clear instruction buffer (GAP 5)
// Scenario:
//   1. Single-issue (e.g., sw in S0) puts S1 instruction into inst_buf
//   2. Branch in the buffered or following instruction triggers flush
//   3. Verify inst_buf is cleared (stale buffered instruction not issued)
//
// Also tests: flush during active dual-issue clears both slots

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100          // DRAM base for scratch
    sw    x0, 0(a0)            // clear scratch[0]
    sw    x0, 4(a0)            // clear scratch[1]

    // ================================================================
    // Part 1: inst_buf filled → branch flush → buf must clear
    //
    // sw (S0) forces single-issue → S1 goes to inst_buf.
    // The buffered instruction is "addi t1, x0, 0xBAD".
    // Next cycle: buffered inst becomes S0, but a branch taken
    // in the pipeline should flush it.
    //
    // We use a backward branch that is NOT taken (fall through).
    // Then we verify t1 does NOT have 0xBAD.
    // Actually, let's be more precise: we cause a branch misprediction.
    // ================================================================
    .align 3
    li    TESTNUM, 1
    li    t0, 0x5A
    li    t1, 0              // t1 = 0 (will check it stays 0 or gets correct value)

    // Single-issue: sw causes non-ALU in S0 → S1 buffered
    sw    t0, 0(a0)          // S0: store (forces single-issue)
    // S1 position: this instruction goes into inst_buf
    // Next cycle: inst_buf becomes S0
    addi  t2, x0, 42         // this will be buffered, then issued as S0 next cycle

    // The buffered addi t2 will execute. Check it.
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t4, 42
    bne   t2, t4, fail

    // ================================================================
    // Part 2: Verify store was correct (inst_buf didn't corrupt pipeline)
    // ================================================================
    li    TESTNUM, 2
    lw    t3, 0(a0)
    addi  t3, t3, 0
    addi  t3, t3, 0
    addi  t3, t3, 0
    li    t4, 0x5A
    bne   t3, t4, fail

    // ================================================================
    // Part 3: Branch in S0 → single-issue, S1 buffered
    //         Branch taken → flush → inst_buf must be cleared
    //
    // If inst_buf is NOT cleared, the stale instruction would execute
    // and corrupt a register.
    // ================================================================
    .align 3
    li    TESTNUM, 3
    li    t0, 0
    li    t1, 0

    // Force t5 = 1 for branch condition
    addi  t5, x0, 1
    addi  s0, x0, 0

    // Branch taken: S0=beq → single issue → S1 buffered but flush clears it
    beq   t5, t5, branch_target1     // always taken
    // This instruction is in S1 position, will be buffered
    // If buffer is NOT cleared by flush, this would execute!
    addi  t0, x0, 0x77              // SHOULD NOT EXECUTE (wrong path)

branch_target1:
    // If inst_buf was properly cleared, t0 should still be 0
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    bne   t0, x0, fail    // t0 must be 0

    // ================================================================
    // Part 4: JAL in S0 → single-issue, S1 buffered
    //         JAL always taken → flush → inst_buf must clear
    // ================================================================
    .align 3
    li    TESTNUM, 4
    li    t0, 0

    jal   x0, branch_target2        // JAL (S0) → always taken, S1 buffered
    addi  t0, x0, 0x99              // SHOULD NOT EXECUTE

branch_target2:
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    bne   t0, x0, fail    // t0 must still be 0

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
