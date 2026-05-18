#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li    s0, 0
    li    s1, 0

    la    t0, unexpected_trap
    csrrw x0, mtvec, t0
    csrrw x0, mscratch, x0
    csrrw x0, mcause, x0

    .align 3
wrong_path_ecall_pair:
    beq   x0, x0, after_wrong_path_ecall
    ecall
after_wrong_path_ecall:
    csrrs t0, mcause, x0
    li    TESTNUM, 1
    bne   t0, x0, fail

    la    t0, wrong_mret_target
    csrrw x0, mepc, t0
    .align 3
wrong_path_mret_pair:
    beq   x0, x0, after_wrong_path_mret
    mret
after_wrong_path_mret:
    csrrs t1, mepc, x0
    li    TESTNUM, 2
    bne   t1, t0, fail

    la    t0, unexpected_trap
    csrrw x0, mtvec, t0
    li    t1, 0
    .align 3
wrong_path_mtvec_pair:
    beq   x0, x0, after_wrong_path_mtvec
    csrrw x0, mtvec, t1
after_wrong_path_mtvec:
    csrrs t2, mtvec, x0
    li    TESTNUM, 3
    bne   t2, t0, fail

    la    t0, expected_mepc_value
    csrrw x0, mepc, t0
    li    t1, 0
    .align 3
wrong_path_mepc_pair:
    beq   x0, x0, after_wrong_path_mepc
    csrrw x0, mepc, t1
after_wrong_path_mepc:
    csrrs t2, mepc, x0
    li    TESTNUM, 4
    bne   t2, t0, fail

    li    t0, 0x1357
    csrrw x0, mscratch, t0
    li    t1, 0
    .align 3
wrong_path_csr_after_jal:
    jal   after_wrong_path_jal_csr
    csrrw x0, mscratch, t1
after_wrong_path_jal_csr:
    csrrs t2, mscratch, x0
    li    TESTNUM, 5
    bne   t2, t0, fail

    .align 3
wrong_path_ecall_after_jal:
    jal   after_wrong_path_jal_ecall
    ecall
after_wrong_path_jal_ecall:
    csrrs t0, mcause, x0
    li    TESTNUM, 6
    bne   t0, x0, fail

    RVTEST_PASS

unexpected_trap:
    li    TESTNUM, 20
    j     fail

wrong_mret_target:
    li    TESTNUM, 21
    j     fail

expected_mepc_value:
    nop

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
