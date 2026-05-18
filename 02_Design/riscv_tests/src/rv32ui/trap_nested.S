#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    s0, 0
    li    s1, 0

    la    t0, nested_trap_handler
    csrrw x0, mtvec, t0

    li    t0, 0x08
    csrrw x0, mstatus, t0

outer_ecall:
    ecall

after_outer:
    li    t0, 2
    li    TESTNUM, 1
    bne   s1, t0, fail
    li    t0, 3
    li    TESTNUM, 2
    bne   s0, t0, fail
    csrrs t1, mstatus, x0
    andi  t2, t1, 0x88
    li    t3, 0x88
    li    TESTNUM, 3
    bne   t2, t3, fail
    csrrs t1, mepc, x0
    la    t2, after_outer
    li    TESTNUM, 4
    bne   t1, t2, fail

    RVTEST_PASS

    .align 2
nested_trap_handler:
    addi  s1, s1, 1

    csrrs t0, mcause, x0
    li    t1, 11
    li    TESTNUM, 10
    bne   t0, t1, fail

    beqz  s0, handle_outer_trap
    li    t1, 1
    beq   s0, t1, handle_inner_trap
    li    TESTNUM, 11
    j     fail

handle_outer_trap:
    li    s0, 1
    csrrs t0, mepc, x0
    la    t1, outer_ecall
    li    TESTNUM, 12
    bne   t0, t1, fail
    csrrs t0, mstatus, x0
    andi  t1, t0, 0x88
    li    t2, 0x80
    li    TESTNUM, 13
    bne   t1, t2, fail

inner_ecall:
    ecall

after_inner:
    li    t0, 2
    li    TESTNUM, 14
    bne   s0, t0, fail
    li    s0, 3
    la    t0, after_outer
    csrrw x0, mepc, t0
    mret

handle_inner_trap:
    li    s0, 2
    csrrs t0, mepc, x0
    la    t1, inner_ecall
    li    TESTNUM, 15
    bne   t0, t1, fail
    csrrs t0, mstatus, x0
    andi  t1, t0, 0x88
    li    TESTNUM, 16
    bne   t1, x0, fail
    la    t0, after_inner
    csrrw x0, mepc, t0
    mret

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
