#include "riscv_test.h"

// Test: WAW + forwarding priority verification
// Covers: GAP 3 - When S0 and S1 both write same rd, forwarding MUX
//         must select S1 (higher priority) for subsequent readers.
//
// Existing waw.S only checks the final value after NOP drain.
// This test checks forwarding when the WAW pair is still in EX/MEM/WB
// and a dual-issue consumer reads the contested register.

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: WAW in EX, consumer reads via forwarding
    // S0: addi t0, x0, 1 (t0=1)
    // S1: addi t0, x0, 2 (t0=2, WAW)
    //   → dual-issue OK (S1.rs1=x0 != S0.rd=t0)
    // Next: add t2, t0, x0 (should read t0=2 from S1_EX, not t0=1 from S0_EX)
    // ================================================================
    .align 3
    li    TESTNUM, 1
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  t0, x0, 1     // S0: t0 = 1
    addi  t0, x0, 2     // S1: t0 = 2 (WAW, S1.rs1=x0 != S0.rd=t0)
    // WAW pair in EX, consumer in ID:
    // S1_EX hit (t0=2) has higher priority than S0_EX hit (t0=1)
    add   t2, t0, x0    // S0: t2 = 2 (from S1_EX)
    addi  t3, t0, 10    // S1: t3 = 12 (from S1_EX, t0=2+10)
    // But wait: S0.rd=t2, S1.rs1=t0 != t2 → no same-pair RAW → dual OK
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t4, 2
    bne   t2, t4, fail

    li    TESTNUM, 2
    li    t4, 12
    bne   t3, t4, fail

    // ================================================================
    // Part 2: WAW in MEM, consumer reads via forwarding
    // Same WAW pair, but with 1 filler pair to push producer to MEM
    // ================================================================
    .align 3
    li    TESTNUM, 3
    addi  t0, x0, 0
    addi  t1, x0, 0
    addi  t0, x0, 10    // S0: t0 = 10
    addi  t0, x0, 20    // S1: t0 = 20 (WAW)
    addi  a0, x0, 1     // filler S0
    addi  a1, x0, 2     // filler S1
    // WAW pair in MEM: S1_MEM(t0=20) > S0_MEM(t0=10)
    add   t2, t0, x0    // t2 = 20
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t4, 20
    bne   t2, t4, fail

    // ================================================================
    // Part 3: WAW in WB, consumer reads via forwarding
    // ================================================================
    .align 3
    li    TESTNUM, 4
    addi  t0, x0, 0
    addi  t1, x0, 0
    addi  t0, x0, 30    // S0: t0 = 30
    addi  t0, x0, 40    // S1: t0 = 40 (WAW)
    addi  a0, x0, 1     // filler1 S0
    addi  a1, x0, 2     // filler1 S1
    addi  a2, x0, 3     // filler2 S0
    addi  a3, x0, 4     // filler2 S1
    // WAW pair in WB: S1_WB(t0=40) > S0_WB(t0=30)
    add   t2, t0, x0    // t2 = 40
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t4, 40
    bne   t2, t4, fail

    // ================================================================
    // Part 4: WAW pair → next pair also WAW → chain forwarding
    // Pair A: S0: t0=1, S1: t0=2 (WAW, t0=2 wins)
    // Pair B: S0: t0=3, S1: t0=4 (WAW, t0=4 wins)
    //   But Pair B S0 reads... no wait, addi t0, x0, 3 doesn't read t0.
    //   rs1=x0 for all. So no forwarding needed for pairs themselves.
    // Consumer: reads t0 → should get 4 from S1_EX of pair B
    // ================================================================
    .align 3
    li    TESTNUM, 5
    addi  t0, x0, 0
    addi  t1, x0, 0
    addi  t0, x0, 1     // pair A S0: t0 = 1
    addi  t0, x0, 2     // pair A S1: t0 = 2 (WAW)
    addi  t0, x0, 3     // pair B S0: t0 = 3
    addi  t0, x0, 4     // pair B S1: t0 = 4 (WAW)
    // But can pair B dual-issue?
    // S0.rd=t0, S1.rs1=x0 != t0 → no RAW → dual OK
    // Consumer in ID, pair B in EX: S1_EX(t0=4) > S0_EX(t0=3)
    add   t2, t0, x0    // t2 = 4
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t4, 4
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
