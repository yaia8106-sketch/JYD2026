#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    s0, 0
    li    s1, 0

    .align 2
    la    t0, trap_handler
    ori   t1, t0, 1
    csrrw x0, mtvec, t1
    csrrs t2, mtvec, x0
    li    TESTNUM, 1
    bne   t2, t1, fail

    li    t0, 0x08
    csrrw x0, mstatus, t0

ecall_site:
    ecall
    addi  s0, s0, 1

after_ecall:
    li    t0, 1
    li    TESTNUM, 2
    bne   s0, t0, fail
    li    TESTNUM, 3
    bne   s1, t0, fail

    csrrs t1, mstatus, x0
    andi  t2, t1, 0x88
    li    t3, 0x88
    li    TESTNUM, 4
    bne   t2, t3, fail

    RVTEST_PASS

    .align 2
trap_handler:
    addi  s1, x0, 1

    csrrs t0, mcause, x0
    li    t1, 11
    li    TESTNUM, 5
    bne   t0, t1, fail

    csrrs t0, mepc, x0
    la    t1, ecall_site
    li    TESTNUM, 6
    bne   t0, t1, fail

    csrrs t0, mstatus, x0
    andi  t1, t0, 0x88
    li    t2, 0x80
    li    TESTNUM, 7
    bne   t1, t2, fail

    csrrs t0, mepc, x0
    addi  t0, t0, 4
    csrrw x0, mepc, t0
    mret

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
