#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    s0, 0

    la    t0, stall_trap_handler
    csrrw x0, mtvec, t0
    csrrw x0, mscratch, x0

    li    t2, 0x6d
    la    t0, stall_word0
    lw    t1, 0(t0)
    csrrw t3, mscratch, t2
    li    t4, 0x11112222
    li    TESTNUM, 1
    bne   t1, t4, fail
    li    TESTNUM, 2
    bne   t3, x0, fail
    csrrs t5, mscratch, x0
    li    TESTNUM, 3
    bne   t5, t2, fail

    li    t0, 0x08
    csrrw x0, mstatus, t0
    la    t0, stall_word1
    lw    s1, 0(t0)
ecall_after_load_miss:
    ecall

after_stalled_trap:
    li    t0, 1
    li    TESTNUM, 4
    bne   s0, t0, fail
    li    t0, 0x33334444
    li    TESTNUM, 5
    bne   s1, t0, fail
    li    t0, 0x55556666
    li    TESTNUM, 6
    bne   t6, t0, fail
    csrrs t1, mstatus, x0
    andi  t2, t1, 0x88
    li    t3, 0x88
    li    TESTNUM, 7
    bne   t2, t3, fail

    RVTEST_PASS

    .align 2
stall_trap_handler:
    addi  s0, s0, 1

    csrrs t0, mcause, x0
    li    t1, 11
    li    TESTNUM, 10
    bne   t0, t1, fail

    csrrs t0, mepc, x0
    la    t1, ecall_after_load_miss
    li    TESTNUM, 11
    bne   t0, t1, fail

    csrrs t0, mstatus, x0
    andi  t1, t0, 0x88
    li    t2, 0x80
    li    TESTNUM, 12
    bne   t1, t2, fail

    la    t0, after_stalled_trap
    csrrw x0, mepc, t0
    la    t0, stall_word2
    lw    t6, 0(t0)
    mret

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
stall_word0:
    .word 0x11112222
    .space 60
stall_word1:
    .word 0x33334444
    .space 60
stall_word2:
    .word 0x55556666
RVTEST_DATA_END
