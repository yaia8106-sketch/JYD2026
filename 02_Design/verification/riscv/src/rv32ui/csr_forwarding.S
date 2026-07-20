#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    csrrw x0, mstatus, x0
    csrrw x0, mscratch, x0
    csrrw x0, mcause, x0

    li    t0, 0x100
    addi  t0, t0, 0x23
    csrrw t1, mscratch, t0
    li    TESTNUM, 1
    bne   t1, x0, fail
    csrrs t2, mscratch, x0
    li    t3, 0x123
    li    TESTNUM, 2
    bne   t2, t3, fail

    li    t0, 0x20
    csrrw t1, mscratch, t0
    addi  t2, t1, 1
    li    t3, 0x124
    li    TESTNUM, 3
    bne   t2, t3, fail
    csrrs t4, mscratch, x0
    li    TESTNUM, 4
    bne   t4, t0, fail

    li    t1, 0x20
    li    TESTNUM, 5
    csrrs t0, mscratch, x0
    bne   t0, t1, fail

    li    t2, 0x13579bdf
    csrrw x0, mscratch, t2
    la    t3, csr_store_data_word
    li    TESTNUM, 6
    csrrs t0, mscratch, x0
    sw    t0, 0(t3)
    lw    t4, 0(t3)
    bne   t4, t2, fail

    la    t2, csr_load_target_word
    csrrw x0, mscratch, t2
    li    TESTNUM, 7
    csrrs t0, mscratch, x0
    lw    t1, 0(t0)
    li    t3, 0x2468ace0
    bne   t1, t3, fail

    la    t2, csr_store_addr_word
    li    t3, 0x0badc0de
    csrrw x0, mscratch, t2
    li    TESTNUM, 8
    csrrs t0, mscratch, x0
    sw    t3, 0(t0)
    lw    t4, 0(t2)
    bne   t4, t3, fail

    li    t2, 0x5a
    csrrw x0, mscratch, t2
    li    TESTNUM, 9
    csrrs t0, mscratch, x0
    csrrw t1, mcause, t0
    csrrs t3, mcause, x0
    bne   t3, t2, fail

    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
csr_store_data_word:
    .word 0
csr_load_target_word:
    .word 0x2468ace0
csr_store_addr_word:
    .word 0
RVTEST_DATA_END
