#include "riscv_test.h"

// Test: LUI and AUIPC in Slot 1 (GAP 7)
// LUI/AUIPC are classified as ALU-type → allowed in S1.
// They use special alu_src1_sel (x0 or PC) and alu_src2_sel (imm).
// Decoder and ALU source MUX for S1 must handle these correctly.
// Also: sustained dual-issue pressure test (GAP 8).

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: LUI in S1
    //   S0=addi t0,x0,5; S1=lui t1,0x12345
    //   LUI doesn't use rs1/rs2 → if_pair_raw=0 → dual-issue OK
    //   LUI: alu_src1=0, alu_src2=imm → result = 0x12345000
    // ================================================================
    .align 3
    li    TESTNUM, 1
    addi  t0, x0, 0
    addi  t1, x0, 0
    addi  t0, x0, 5           // S0: t0=5
    lui   t1, 0x12345         // S1: t1=0x12345000
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t4, 5
    bne   t0, t4, fail
    li    TESTNUM, 2
    lui   t4, 0x12345
    bne   t1, t4, fail

    // ================================================================
    // Part 2: AUIPC in S1
    //   S0=addi t0,x0,9; S1=auipc t1,0
    //   AUIPC: result = S1_PC + (imm << 12)
    //   With imm=0: t1 = S1_PC = S0_PC + 4
    // ================================================================
    .align 3
    li    TESTNUM, 3
    addi  t0, x0, 0
    addi  t1, x0, 0
auipc_pair:
    addi  t0, x0, 9           // S0 at auipc_pair
    auipc t1, 0               // S1: t1 = PC of this instruction = auipc_pair + 4
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    // Compute expected: auipc_pair + 4
    la    t4, auipc_pair
    addi  t4, t4, 4
    bne   t1, t4, fail

    // ================================================================
    // Part 3: LUI in S1 + forwarding from S1
    //   Pair A: S0=addi t0,x0,1; S1=lui t1,0x80100
    //   Pair B: S0=sw t0,0(t1)  → reads t1 from S1_EX forward
    //   (but sw in S0 blocks dual-issue... that's OK, we're testing
    //    the forwarded LUI result is correct for the store address)
    // ================================================================
    .align 3
    li    TESTNUM, 4
    addi  t0, x0, 0
    addi  t1, x0, 0

    lui   a0, 0x80100
    sw    x0, 16(a0)          // clear scratch[4]

    .align 3
    li    t0, 0xAB            // S0
    lui   t1, 0x80100         // S1: t1 = 0x80100000 (dual: no RAW)
    // t1 forwarded from S1_EX to next S0:
    sw    t0, 16(t1)          // store 0xAB to 0x80100000+16
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    lw    t2, 16(a0)
    addi  t2, t2, 0
    addi  t2, t2, 0
    addi  t2, t2, 0
    li    t4, 0xAB
    bne   t2, t4, fail

    // ================================================================
    // Part 4: Sustained dual-issue — 8 consecutive dual pairs
    //   All independent ALU operations, no RAW between pairs.
    //   Check dual counter delta >= 8.
    // ================================================================
    .align 3
    li    TESTNUM, 5

    li    t6, DUAL_CNT_ADDR
    lw    s0, 0(t6)
    addi  s0, s0, 0
    addi  s0, s0, 0
    addi  s0, s0, 0

    .align 3
    // 8 pairs: each S0 writes s2, S1 writes s3 (overwritten each pair)
    // No cross-pair deps since each pair overwrites the same regs.
    addi  s2, x0, 1           // pair 1
    addi  s3, x0, 2
    addi  s2, x0, 3           // pair 2
    addi  s3, x0, 4
    addi  s2, x0, 5           // pair 3
    addi  s3, x0, 6
    addi  s2, x0, 7           // pair 4
    addi  s3, x0, 8
    addi  s2, x0, 9           // pair 5
    addi  s3, x0, 10
    addi  s2, x0, 11          // pair 6
    addi  s3, x0, 12
    addi  s2, x0, 13          // pair 7
    addi  s3, x0, 14
    addi  s2, x0, 15          // pair 8
    addi  s3, x0, 16

    addi  t6, t6, 0
    lw    s1, 0(t6)
    addi  s1, s1, 0
    addi  s1, s1, 0
    addi  s1, s1, 0

    sub   t2, s1, s0
    // Expect at least 8 dual-issues (could be more from surrounding code)
    li    t4, 8
    blt   t2, t4, fail_count

    // Final values: s2=15, s3=16
    li    TESTNUM, 6
    li    t4, 15
    bne   s2, t4, fail
    li    t4, 16
    bne   s3, t4, fail

pass:
    RVTEST_PASS

fail_count:
    li    TESTNUM, 10
    j     fail_out

fail:
fail_out:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
