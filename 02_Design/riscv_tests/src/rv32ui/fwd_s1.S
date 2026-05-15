#include "riscv_test.h"

// Test: Cross-slot forwarding from Slot 1 → next pair S0/S1
// Covers: S1_EX, S1_MEM, S1_WB forwarding paths (GAP 2)
// These paths are NEVER exercised by existing tests (all use NOP padding).
//
// Forwarding priority: S1_EX > S0_EX > S1_MEM > S0_MEM > S1_WB > S0_WB > RF
// Key: S1 writes rd in one pair, next pair(s) read it via forwarding.

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: S1_EX → next pair S0 and S1
    // Producer pair: S0=addi t0,x0,10; S1=addi t1,x0,20
    //   (S1.rs1=x0 != S0.rd=t0 → no RAW → dual-issue)
    // Consumer pair: S0=add t2,t0,t1; S1=addi t3,t1,5
    //   (S0.rd=t2, S1.rs1=t1 != t2 → no RAW → dual-issue)
    // When consumer is in ID, producer is in EX:
    //   t0 from S0_EX, t1 from S1_EX
    // ================================================================
    .align 3
    li    TESTNUM, 1
    addi  s3, x0, 0     // clear accumulator
    addi  t0, x0, 10    // S0: t0 = 10
    addi  t1, x0, 20    // S1: t1 = 20
    add   t2, t0, t1    // S0: t2 = 30 (S0_EX→t0, S1_EX→t1)
    addi  t3, t1, 5     // S1: t3 = 25 (S1_EX→t1)
    // drain
    addi  s3, x0, 0
    addi  s4, x0, 0
    addi  s5, x0, 0
    addi  s6, x0, 0
    li    t4, 30
    bne   t2, t4, fail

    li    TESTNUM, 2
    li    t4, 25
    bne   t3, t4, fail

    // ================================================================
    // Part 2: S1_MEM → next pair S0
    // Producer pair → 1 filler pair → consumer (reads from MEM stage)
    // Filler pair uses a0/a1 to avoid colliding with t0/t1.
    // ================================================================
    .align 3
    li    TESTNUM, 3
    addi  t0, x0, 0     // clear
    addi  t1, x0, 0     // clear
    addi  t0, x0, 33    // S0: t0 = 33
    addi  t1, x0, 44    // S1: t1 = 44 (dual: S1.rs1=x0 != S0.rd=t0)
    addi  a0, x0, 1     // S0: filler (a0=1)
    addi  a1, x0, 2     // S1: filler (S1.rs1=x0 != S0.rd=a0 → dual)
    // Now producer in MEM, filler in EX:
    //   t1 from S1_MEM (a0/a1 in EX don't match t0/t1)
    add   t2, t0, t1    // S0: t2 = 33+44 = 77 (S0_MEM→t0, S1_MEM→t1)
    addi  t3, t1, 6     // S1: t3 = 44+6 = 50 (S1_MEM→t1)
    addi  s3, x0, 0
    addi  s4, x0, 0
    addi  s5, x0, 0
    addi  s6, x0, 0
    li    t4, 77
    bne   t2, t4, fail

    li    TESTNUM, 4
    li    t4, 50
    bne   t3, t4, fail

    // ================================================================
    // Part 3: S1_WB → next pair S0
    // Producer → filler1 → filler2 → consumer (reads from WB stage)
    // ================================================================
    .align 3
    li    TESTNUM, 5
    addi  t0, x0, 0
    addi  t1, x0, 0
    addi  t0, x0, 55    // S0: t0 = 55
    addi  t1, x0, 66    // S1: t1 = 66
    addi  a0, x0, 1     // filler1 S0
    addi  a1, x0, 2     // filler1 S1
    addi  a2, x0, 3     // filler2 S0
    addi  a3, x0, 4     // filler2 S1
    // Producer in WB, filler1 in MEM, filler2 in EX:
    add   t2, t0, t1    // S0: t2 = 55+66 = 121 (S0_WB→t0, S1_WB→t1)
    addi  t3, t1, 7     // S1: t3 = 66+7 = 73  (S1_WB→t1)
    addi  s3, x0, 0
    addi  s4, x0, 0
    addi  s5, x0, 0
    addi  s6, x0, 0
    li    t4, 121
    bne   t2, t4, fail

    li    TESTNUM, 6
    li    t4, 73
    bne   t3, t4, fail

    // ================================================================
    // Part 4: S1_EX has higher priority than S0_MEM
    // Pair A: S0 writes t0=100 (goes to MEM), S1 writes t1=200
    // Pair B: S0 writes t0=999 (goes to EX), S1 writes t1=888
    // Consumer reads t0 → should get S0_EX (999), not S0_MEM (100)
    //                 t1 → should get S1_EX (888), not S1_MEM (200)
    // ================================================================
    .align 3
    li    TESTNUM, 7
    addi  t0, x0, 0
    addi  t1, x0, 0
    addi  t0, x0, 100   // S0: t0 = 100 (will be in MEM)
    addi  t1, x0, 200   // S1: t1 = 200 (will be in MEM)
    li    t0, 999        // S0: t0 = 999 (will be in EX)
    li    t1, 888        // S1: t1 = 888 (will be in EX)
    // Wait: li t0, 999 is addi t0, x0, 999. S0.rd=t0, S1.rs1=x0 != t0. Dual OK.
    // Consumer:
    add   t2, t0, t1    // S0: S1_EX(t1=888) > S0_EX(t0=999) → t2=1887
    addi  s3, x0, 0
    addi  s4, x0, 0
    addi  s5, x0, 0
    addi  s6, x0, 0
    li    t4, 1887
    bne   t2, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
