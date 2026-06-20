#include "riscv_test.h"

// Test: EX-stage JALR target forwarding and late-load stall behavior.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    // Part 1: S0 EX ALU producer feeds the next JALR target.
    li    TESTNUM, 1
    la    t1, target_ex0
    addi  t0, t1, 0
    jalr  x0, 0(t0)
    j     fail

target_ex0:
    // Part 2: S1 EX ALU producer feeds the next JALR target.
    li    TESTNUM, 2
    la    t1, target_ex1
    .align 3
    addi  s0, x0, 0
    addi  t0, t1, 0
    jalr  x0, 0(t0)
    j     fail

target_ex1:
    // Part 3: EX producer supplies an odd address; JALR must clear bit 0.
    li    TESTNUM, 3
    la    t1, target_odd
    addi  t0, t1, 1
    jalr  x0, 0(t0)
    j     fail

target_odd:
    // Part 4: load-produced JALR target still stalls, then jumps correctly.
    li    TESTNUM, 4
    lui   a0, 0x80100
    addi  a0, a0, 1024
    la    t1, target_load
    sw    t1, 0(a0)
    lw    t0, 0(a0)
    jalr  x0, 0(t0)
    j     fail

target_load:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
