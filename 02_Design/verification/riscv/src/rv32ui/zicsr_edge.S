#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    t0, -1
    csrrw x0, mstatus, t0
    csrrs t1, mstatus, x0
    li    t2, 0x88
    li    TESTNUM, 1
    bne   t1, t2, fail

    li    t0, 0x55aa55aa
    csrrw x0, mscratch, t0
    csrrs t1, mscratch, x0
    li    TESTNUM, 2
    bne   t1, t0, fail
    csrrc t1, mscratch, x0
    li    TESTNUM, 3
    bne   t1, t0, fail
    csrrsi t1, mscratch, 0
    li    TESTNUM, 4
    bne   t1, t0, fail
    csrrci t1, mscratch, 0
    li    TESTNUM, 5
    bne   t1, t0, fail
    csrrs t1, mscratch, x0
    li    TESTNUM, 6
    bne   t1, t0, fail

    li    t2, 0x12345678
    csrrw x0, 0x304, t2
    csrrs t3, 0x304, x0
    li    TESTNUM, 7
    bne   t3, x0, fail
    csrrsi t4, 0x343, 31
    li    TESTNUM, 8
    bne   t4, x0, fail
    csrrci t5, 0x344, 31
    li    TESTNUM, 9
    bne   t5, x0, fail
    csrrs t6, 0x301, x0
    li    TESTNUM, 10
    bne   t6, x0, fail
    csrrs t6, 0xB00, x0
    li    TESTNUM, 11
    bne   t6, x0, fail

    la    t0, csr_load_value
    lw    t1, 0(t0)
    csrrw t2, mscratch, t1
    li    t3, 0x55aa55aa
    li    TESTNUM, 12
    bne   t2, t3, fail
    csrrs t4, mscratch, x0
    li    TESTNUM, 13
    bne   t4, t1, fail

    csrrw x0, mscratch, x0
    li    s0, 0
    li    t0, 0x111
    .align 3
csr_slot1_pair:
    addi  s0, s0, 1
    csrrw t1, mscratch, t0
after_csr_slot1:
    addi  s0, s0, 2
    li    t2, 3
    li    TESTNUM, 14
    bne   s0, t2, fail
    li    TESTNUM, 15
    bne   t1, x0, fail
    csrrs t2, mscratch, x0
    li    TESTNUM, 16
    bne   t2, t0, fail

    csrrw x0, mscratch, x0
    li    t0, 0xdead
    .align 3
branch_before_wrong_csr:
    beq   x0, x0, after_wrong_csr
    csrrw x0, mscratch, t0
after_wrong_csr:
    csrrs t1, mscratch, x0
    li    TESTNUM, 17
    bne   t1, x0, fail

    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
csr_load_value:
    .word 0xcafebabe
RVTEST_DATA_END
