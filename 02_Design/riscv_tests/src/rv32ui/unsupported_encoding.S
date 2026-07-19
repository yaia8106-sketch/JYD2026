#include "riscv_test.h"

#define CHECK_UNCHANGED(testnum) \
    li TESTNUM, testnum;         \
    li t3, 0x13579bdf;          \
    bne t2, t3, fail;

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li t0, 0x12345678
    li t1, 0x89abcdef

    // Former Zba register encoding. It must not alias SLT.
    li t2, 0x13579bdf
    .word 0x2062a3b3             // sh1add t2, t0, t1
    CHECK_UNCHANGED(1)

    // Former Zbb register encoding. It must not alias a base logical op.
    li t2, 0x13579bdf
    .word 0x4062f3b3             // andn t2, t0, t1
    CHECK_UNCHANGED(2)

    // Former Zbb unary immediate encoding. It must not alias SLLI.
    li t2, 0x13579bdf
    .word 0x60029393             // clz t2, t0
    CHECK_UNCHANGED(3)

    // Former Zbb rotate immediate encoding. It must not alias SRAI.
    li t2, 0x13579bdf
    .word 0x6072d393             // rori t2, t0, 7
    CHECK_UNCHANGED(4)

    // Former Zbc register encoding. It must not alias SLL.
    li t2, 0x13579bdf
    .word 0x0a6293b3             // clmul t2, t0, t1
    CHECK_UNCHANGED(5)

    // Former Zbs immediate encoding. It must not alias SLLI.
    li t2, 0x13579bdf
    .word 0x48429393             // bclri t2, t0, 4
    CHECK_UNCHANGED(6)

    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
