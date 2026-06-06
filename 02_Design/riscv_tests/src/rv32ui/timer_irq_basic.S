#include "riscv_test.h"

#define MTIME_LO        0x80200070
#define MTIME_HI        0x80200074
#define MTIMECMP_LO     0x80200078
#define MTIMECMP_HI     0x8020007C

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    s1, 0
    li    s2, 0

    la    t0, timer_trap_handler
    csrrw x0, mtvec, t0
    csrrw x0, mie, x0
    csrrw x0, mstatus, x0

    li    t0, MTIME_HI
    sw    x0, 0(t0)
    li    t0, MTIME_LO
    sw    x0, 0(t0)
    li    t0, MTIMECMP_HI
    sw    x0, 0(t0)
    li    t1, 32
    li    t0, MTIMECMP_LO
    sw    t1, 0(t0)

    li    t0, 96
mask_wait:
    addi  t0, t0, -1
    bnez  t0, mask_wait

    li    TESTNUM, 1
    bne   s1, x0, fail

    csrrs t0, mip, x0
    andi  t0, t0, 0x80
    li    t1, 0x80
    li    TESTNUM, 2
    bne   t0, t1, fail

    li    t0, 0x80
    csrrw x0, mie, t0
    csrrs t1, mie, x0
    li    TESTNUM, 3
    bne   t1, t0, fail

    li    t0, 0x08
    csrrw x0, mstatus, t0

wait_irq_start:
    addi  s2, s2, 1
    beqz  s1, wait_irq_start
wait_irq_end:

    li    t0, 1
    li    TESTNUM, 4
    bne   s1, t0, fail
    li    TESTNUM, 5
    beqz  s2, fail

    csrrs t0, mie, x0
    li    TESTNUM, 6
    bne   t0, x0, fail

    csrrs t0, mstatus, x0
    andi  t0, t0, 0x88
    li    t1, 0x88
    li    TESTNUM, 7
    bne   t0, t1, fail

    RVTEST_PASS

    .align 2
timer_trap_handler:
    addi  s1, s1, 1

    csrrs t0, mcause, x0
    li    t1, 0x80000007
    li    TESTNUM, 10
    bne   t0, t1, fail

    csrrs t0, mepc, x0
    la    t1, wait_irq_start
    li    TESTNUM, 11
    bltu  t0, t1, fail
    la    t1, wait_irq_end
    li    TESTNUM, 12
    bgeu  t0, t1, fail

    csrrs t0, mstatus, x0
    andi  t0, t0, 0x88
    li    t1, 0x80
    li    TESTNUM, 13
    bne   t0, t1, fail

    csrrs t0, mip, x0
    andi  t0, t0, 0x80
    li    t1, 0x80
    li    TESTNUM, 14
    bne   t0, t1, fail

    csrrw x0, mie, x0
    mret

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
