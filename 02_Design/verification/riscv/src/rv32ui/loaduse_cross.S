#include "riscv_test.h"

// Test: Cross-pair load-use hazard with Slot 1 as consumer (GAP 4)
// S0 load → next pair S1 depends on load result → must stall.
// forwarding.sv checks id_s1_uses_ex_load and id_s1_uses_mem_load.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100
    li    t0, 100
    sw    t0, 0(a0)
    li    t0, 200
    sw    t0, 4(a0)
    li    t0, 300
    sw    t0, 8(a0)

    // ================================================================
    // Part 1: load in EX, S1 of next pair reads it → stall
    //   lw t0 → next pair: S0=addi t4,x0,7 (no dep), S1=add t2,t0,t1
    //   same-pair RAW: S0.rd=t4, S1.rs1=t0, S1.rs2=t1 → no RAW → dual
    //   load-use: ex_rd=t0, S1.rs1=t0 → stall!
    // ================================================================
    .align 3
    li    TESTNUM, 1
    addi  t0, x0, 0
    addi  t1, x0, 0
    addi  t2, x0, 0

    lw    t0, 0(a0)            // t0 = 100
    addi  t4, x0, 7            // S0: rd=t4 (no collision with t0/t1)
    add   t2, t0, t1           // S1: rs1=t0(load-use!), rs2=t1(=0)
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t5, 100
    bne   t2, t5, fail

    // ================================================================
    // Part 2: load in EX, S1.rs2 depends → stall
    // ================================================================
    .align 3
    li    TESTNUM, 2
    addi  t0, x0, 0
    addi  t1, x0, 0

    lw    t0, 4(a0)            // t0 = 200
    addi  t4, x0, 3            // S0: rd=t4
    add   t1, t3, t0           // S1: rs2=t0(load-use!), rs1=t3
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t5, 200
    bne   t1, t5, fail         // t3=0 from earlier, so t1=0+200=200

    // ================================================================
    // Part 3: S0 reads load result (standard path) while S1 is independent
    //   Verifies S0 load-use stall also stalls S1 correctly.
    // ================================================================
    .align 3
    li    TESTNUM, 3
    addi  t0, x0, 0
    addi  t1, x0, 0

    lw    t0, 8(a0)            // t0 = 300
    add   t1, t0, x0           // S0: rs1=t0(load-use!) → stall
    addi  t4, x0, 55           // S1: independent, but stalled with S0
    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0
    li    t5, 300
    bne   t1, t5, fail

    li    TESTNUM, 4
    li    t5, 55
    bne   t4, t5, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
