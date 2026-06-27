#include "riscv_test.h"

#define CHECK_REG(testnum, reg, expected) \
    li TESTNUM, testnum;                  \
    li t6, expected;                      \
    bne reg, t6, fail;

// RV32M and DCache interaction coverage.
// Keep load-to-M dependencies adjacent so the result must use the load repair
// path rather than a value already committed to the register file.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    la   a0, edge_line0
    li   a1, 7

    // Cold-miss load feeding each divider operand.
    lw   t0, 0(a0)
    div  t1, t0, a1
    CHECK_REG(1, t1, 14)

    li   t0, 100
    lw   t1, 4(a0)
    div  t2, t0, t1
    CHECK_REG(2, t2, 14)

    // Hit load feeding signed/unsigned remainder.
    lw   t0, 8(a0)
    rem  t1, t0, a1
    CHECK_REG(3, t1, -2)

    li   t0, 0xffffffff
    lw   t1, 12(a0)
    remu t2, t0, t1
    CHECK_REG(4, t2, 3)

    // Multiplication uses the same load repair path.
    lw   t0, 0(a0)
    mul  t1, t0, a1
    CHECK_REG(5, t1, 686)

    // A critical-word-first miss retires before the rest of the line. Access
    // all remaining words immediately and verify their wrapped refill order.
    la   a2, edge_line1
    lw   t0, 12(a2)
    CHECK_REG(6, t0, 0x44444444)
    lw   t1, 0(a2)
    CHECK_REG(7, t1, 0x11111111)
    lw   t2, 4(a2)
    CHECK_REG(8, t2, 0x22222222)
    lw   t3, 8(a2)
    CHECK_REG(9, t3, 0x33333333)

    // Three tags in one set force replacement. Each reloaded word is then
    // consumed immediately by DIV to combine refill and M-extension hazards.
    la   a3, edge_conflict0
    la   a4, edge_conflict1
    la   a5, edge_conflict2

    lw   t0, 0(a3)
    lw   t1, 0(a4)
    lw   t2, 0(a5)

    lw   t0, 0(a3)
    divu t1, t0, a1
    CHECK_REG(10, t1, 17)

    lw   t0, 0(a4)
    remu t1, t0, a1
    CHECK_REG(11, t1, 4)

    // Pending byte store merged into a refill, then used by signed DIV.
    la   a2, edge_store_line
    li   t0, 0x80
    sb   t0, 1(a2)
    lw   t1, 0(a2)
    li   t2, 2
    div  t3, t1, t2
    CHECK_REG(12, t1, 0xffff8008)
    CHECK_REG(13, t3, 0xffffc004)

    // Cold-miss target-word return feeding each enabled repair role. All
    // source lines alias one DCache set so every source load must refill.

    // ALU consumer.
    la   a2, repair_alu_line
    lw   t0, 0(a2)
    addi t1, t0, 5
    CHECK_REG(14, t1, 0x1234567d)

    // Taken branch redirects while the rest of the refill is still in flight.
    la   a2, repair_branch_line
    li   t1, 0x55aa55aa
    lw   t0, 0(a2)
    beq  t0, t1, repair_branch_ok
    j    fail
repair_branch_ok:

    // JALR redirects while the rest of the refill is still in flight.
    la   a2, repair_jalr_line
    lw   t0, 0(a2)
    jalr x0, 0(t0)
    j    fail
repair_jalr_ok:

    // Loaded pointer feeds the next load address.
    la   a2, repair_load_ptr_line
    lw   t0, 0(a2)
    lw   t1, 0(t0)
    CHECK_REG(15, t1, 0x2468ace0)

    // Loaded pointer feeds the next store address.
    la   a2, repair_store_ptr_line
    li   t1, 0x13579bdf
    lw   t0, 0(a2)
    sw   t1, 0(t0)
    lw   t2, 0(t0)
    CHECK_REG(16, t2, 0x13579bdf)

    // Loaded value feeds the next store data operand.
    la   a2, repair_store_data_line
    la   a3, repair_store_data_target
    lw   t0, 0(a2)
    sw   t0, 0(a3)
    lw   t1, 0(a3)
    CHECK_REG(17, t1, 0x89abcdef)

    pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 10
edge_line0:
    .word 98, 7, -100, 4
edge_line1:
    .word 0x11111111, 0x22222222, 0x33333333, 0x44444444
    .space 992
edge_conflict0:
    .word 119, 0, 0, 0
    .space 1008
edge_conflict1:
    .word 123, 0, 0, 0
    .space 1008
edge_conflict2:
    .word 127, 0, 0, 0
    .space 1008
edge_store_line:
    .word 0xffff0008, 0, 0, 0

.align 10
repair_alu_line:
    .word 0x12345678, 0, 0, 0
    .space 1008
repair_branch_line:
    .word 0x55aa55aa, 0, 0, 0
    .space 1008
repair_jalr_line:
    .word repair_jalr_ok, 0, 0, 0
    .space 1008
repair_load_ptr_line:
    .word repair_load_target, 0, 0, 0
    .space 1008
repair_store_ptr_line:
    .word repair_store_target, 0, 0, 0
    .space 1008
repair_store_data_line:
    .word 0x89abcdef, 0, 0, 0
    .space 1008
repair_load_target:
    .word 0x2468ace0, 0, 0, 0
    .space 1008
repair_store_target:
    .word 0, 0, 0, 0
    .space 1008
repair_store_data_target:
    .word 0, 0, 0, 0
RVTEST_DATA_END
