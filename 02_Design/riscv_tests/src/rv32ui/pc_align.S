#include "riscv_test.h"

// Test: PC[2]=1 fetch-window handling
// When a branch target lands at PC[2]=1 (not 8-byte aligned),
// the IROM window must still expose {PC+4, PC} and execute correctly.
//
// Also tests: S1-type edge cases at aligned fetch windows. Slot1 load/store
// and branch may dual-issue when their pairing policy allows it.

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: Branch to PC[2]=1 address, verify correct window/order
    // ================================================================
    .align 3
    li    TESTNUM, 1

    // Read dual counter before
    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    addi  s0, s0, 0

    // Jump to a PC[2]=1 address
    j     odd_target
    nop

    .align 3                 // align to 8 bytes
    nop                      // +0: this is at PC[2]=0
odd_target:                  // +4: this is at PC[2]=1
    // At PC[2]=1: inst0=PC and inst1=PC+4 may dual-issue if constraints allow.
    addi  t0, x0, 42
    addi  t1, x0, 55
    addi  t2, x0, 77

    // Drain and check
    addi  s3, x0, 0
    addi  s4, x0, 0
    addi  s5, x0, 0
    addi  s6, x0, 0

    li    t4, 42
    bne   t0, t4, fail
    li    t4, 55
    bne   t1, t4, fail
    li    t4, 77
    bne   t2, t4, fail

    // ================================================================
    // Part 2: S1 is a load and may dual-issue with ordinary S0 ALU.
    // ================================================================
    .align 3
    li    TESTNUM, 2
    lui   a0, 0x80100
    li    t0, 0x12
    sw    t0, 8(a0)           // prepare: store 0x12 to scratch[2]
    addi  s0, x0, 0
    addi  s1, x0, 0

    // Read dual counter
    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    addi  s0, s0, 0

    .align 3
    // This pair: S0=addi, S1=lw. The shared LSU path may issue it in S1.
    addi  t0, x0, 99         // S0
    lw    t1, 8(a0)          // S1 position: load → single-issue, goes to inst_buf
    // t1 should eventually get 0x12 from DRAM

    addi  s3, x0, 0
    addi  s4, x0, 0
    addi  s5, x0, 0
    addi  s6, x0, 0

    // Read dual counter after
    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0
    addi  s1, s1, 0

    // Dual count should be 0 for the test region
    // (li t6 + lw s0 may dual-issue but that's outside the test)
    // Check values
    li    t4, 99
    bne   t0, t4, fail

    li    TESTNUM, 3
    li    t4, 0x12
    bne   t1, t4, fail

    // ================================================================
    // Part 3: S1 is a store, but this pair has same-pair RAW on store data and
    // must serialize.
    // ================================================================
    .align 3
    li    TESTNUM, 4
    lui   a0, 0x80100

    .align 3
    addi  t0, x0, 88         // S0
    sw    t0, 12(a0)         // S1 position: store with RAW on t0

    addi  s3, x0, 0
    addi  s4, x0, 0
    addi  s5, x0, 0
    addi  s6, x0, 0

    lw    t2, 12(a0)
    addi  t2, t2, 0
    addi  t2, t2, 0
    addi  t2, t2, 0
    li    t4, 88
    bne   t2, t4, fail

    // ================================================================
    // Part 4: S1 is a branch. It may dual-issue and redirect from Slot1.
    // ================================================================
    .align 3
    li    TESTNUM, 5
    addi  t0, x0, 0

    .align 3
    addi  t0, x0, 11         // S0
    beq   x0, x0, s1_branch_target  // S1 position: branch

s1_branch_not_taken:
    addi  t0, x0, 0xFF       // should NOT execute if branch works
    j     fail

s1_branch_target:
    addi  s3, x0, 0
    addi  s4, x0, 0
    addi  s5, x0, 0
    addi  s6, x0, 0
    li    t4, 11
    bne   t0, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
