#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    csrrw x0, mstatus, x0

    li    t0, 0x88
    csrrw t1, mstatus, t0
    li    TESTNUM, 1
    bne   t1, x0, fail

    csrrs t2, mstatus, x0
    li    TESTNUM, 2
    bne   t2, t0, fail

    li    t3, 0x08
    csrrc t4, mstatus, t3
    li    TESTNUM, 3
    bne   t4, t0, fail

    csrrs t5, mstatus, x0
    li    t6, 0x80
    li    TESTNUM, 4
    bne   t5, t6, fail

    csrrs t4, mstatus, x0
    li    TESTNUM, 5
    bne   t4, t6, fail

    csrrw x0, mstatus, x0
    li    t0, 0x88
    csrrw t1, mstatus, t0
    addi  t2, t1, 1
    li    t3, 1
    li    TESTNUM, 6
    bne   t2, t3, fail

    li    t0, 0x08
    csrrw x0, mstatus, t0
    csrrs t1, mstatus, x0
    li    TESTNUM, 7
    bne   t1, t0, fail

    csrrwi t1, mcause, 5
    li    TESTNUM, 8
    bne   t1, x0, fail

    csrrsi t2, mcause, 2
    li    t3, 5
    li    TESTNUM, 9
    bne   t2, t3, fail

    csrrci t4, mcause, 1
    li    t5, 7
    li    TESTNUM, 10
    bne   t4, t5, fail

    csrrsi t6, mcause, 0
    li    t0, 6
    li    TESTNUM, 11
    bne   t6, t0, fail

    li    t1, 0x123
    csrrw x0, mscratch, t1
    csrrs t2, mscratch, x0
    li    TESTNUM, 12
    bne   t2, x0, fail

    li    t0, 0x80000100
    csrrw x0, mepc, t0
    csrrs t1, mepc, x0
    li    TESTNUM, 13
    bne   t1, t0, fail

    la    t0, mtvec_target
    ori   t1, t0, 1
    csrrw x0, mtvec, t1
    csrrs t2, mtvec, x0
    li    TESTNUM, 14
    bne   t2, t1, fail

    RVTEST_PASS

mtvec_target:
    nop

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
