#include "riscv_test.h"

// Test: Branch predictor + dual-issue interaction
// 1. BP misprediction while dual-issue pair is in flight
// 2. Branch in loop body with dual-issue ALU pairs
// 3. JAL/JALR link address correctness in dual-issue context

#define DUAL_CNT_ADDR 0x80200060

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // ================================================================
    // Part 1: Tight loop with dual-issue ALU body
    // Loop body has ALU pairs that dual-issue.
    // Branch at end → misprediction on exit → flush both slots.
    // Verify accumulator is correct after loop.
    // ================================================================
    .align 3
    li    TESTNUM, 1
    addi  t0, x0, 0           // accumulator
    addi  t1, x0, 0           // counter
    li    t5, 10              // loop limit

    .align 3
loop1:
    addi  t0, t0, 1           // S0: acc += 1
    addi  t1, t1, 1           // S1: cnt += 1 (dual: S1.rs1=t1 != S0.rd=t0)
    bne   t1, t5, loop1       // branch (S0, single-issue)
    // After loop: t0=10, t1=10

    addi  s0, x0, 0
    addi  s1, x0, 0

    li    t4, 10
    bne   t0, t4, fail
    li    TESTNUM, 2
    bne   t1, t4, fail

    // ================================================================
    // Part 2: Nested control flow with dual-issue
    // Outer loop iterates, inner body has dual-issue pairs.
    // Tests flush/redirect when dual-issue is active.
    // ================================================================
    .align 3
    li    TESTNUM, 3
    addi  t0, x0, 0           // sum
    addi  t1, x0, 0           // i
    li    t5, 5               // outer limit

    .align 3
loop2:
    // Dual-issue pair inside loop
    addi  t2, t1, 1           // S0: t2 = i+1
    addi  t3, t1, 2           // S1: t3 = i+2 (S1.rs1=t1 != S0.rd=t2 → dual OK)
    add   t0, t0, t2          // sum += (i+1)
    add   t0, t0, t3          // sum += (i+2)
    addi  t1, t1, 1           // i++
    bne   t1, t5, loop2
    // sum = (1+2) + (2+3) + (3+4) + (4+5) + (5+6) = 3+5+7+9+11 = 35

    addi  s0, x0, 0
    addi  s1, x0, 0

    li    t4, 35
    bne   t0, t4, fail

    // ================================================================
    // Part 3: JAL with dual-issue on return path
    // After JAL returns (link in ra), verify ra is correct.
    // Then execute dual-issue pairs after the return.
    // ================================================================
    .align 3
    li    TESTNUM, 4
    addi  t0, x0, 0
    addi  t1, x0, 0

    jal   ra, subroutine1
    // Return here. ra should point to this instruction.
return_point1:
    // Dual-issue pair after return:
    addi  t2, t0, 100         // S0: t2 = t0 + 100
    addi  t3, t1, 200         // S1: t3 = t1 + 200 (S1.rs1=t1 != S0.rd=t2 → dual)
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    // Check ra
    la    t4, return_point1
    bne   ra, t4, fail

    li    TESTNUM, 5
    li    t4, 142              // t0=42, t2=42+100=142
    bne   t2, t4, fail

    li    TESTNUM, 6
    li    t4, 213              // t1=13, t3=13+200=213
    bne   t3, t4, fail

    j     part4

subroutine1:
    addi  t0, x0, 42          // S0
    addi  t1, x0, 13          // S1 (dual with above)
    jalr  x0, ra, 0           // return

    // ================================================================
    // Part 4: Back-to-back branches with dual-issue between them
    // branch → dual pair → branch → dual pair → check
    // ================================================================
    .align 3
part4:
    li    TESTNUM, 7
    addi  t0, x0, 0
    addi  t1, x0, 0

    li    t5, 1
    beq   t5, t5, target1     // always taken
    addi  t0, x0, 0xFF        // should NOT execute
    .align 3
target1:
    addi  t0, x0, 10          // S0
    addi  t1, x0, 20          // S1 (dual)
    beq   t5, t5, target2     // always taken
    addi  t0, x0, 0xFF        // should NOT execute
    .align 3
target2:
    add   t2, t0, t1          // S0: 10+20=30
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    li    t4, 30
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
