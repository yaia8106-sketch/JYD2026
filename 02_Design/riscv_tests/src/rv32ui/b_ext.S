#include "riscv_test.h"

#define CHECK_REG(testnum, reg, expected) \
    li TESTNUM, testnum;                  \
    li t6, expected;                      \
    bne reg, t6, fail;

RVTEST_RV32U
RVTEST_CODE_BEGIN

    li t0, 0x12345678
    li t1, 0x89abcdef

    // Zba: address-generation shifts.
    sh1add t2, t0, t1
    CHECK_REG(1, t2, 0xae147adf)
    sh2add t2, t0, t1
    CHECK_REG(2, t2, 0xd27d27cf)
    sh3add t2, t0, t1
    CHECK_REG(3, t2, 0x1b4e81af)

    // Zbb: logical-with-negate.
    andn t2, t0, t1
    CHECK_REG(4, t2, 0x12141210)
    orn t2, t0, t1
    CHECK_REG(5, t2, 0x76747678)
    xnor t2, t0, t1
    CHECK_REG(6, t2, 0x64606468)

    // Zbb: count operations and signed/unsigned min/max.
    clz t2, t0
    CHECK_REG(7, t2, 3)
    ctz t2, t0
    CHECK_REG(8, t2, 3)
    cpop t2, t0
    CHECK_REG(9, t2, 13)
    max t2, t0, t1
    CHECK_REG(10, t2, 0x12345678)
    maxu t2, t0, t1
    CHECK_REG(11, t2, 0x89abcdef)
    min t2, t0, t1
    CHECK_REG(12, t2, 0x89abcdef)
    minu t2, t0, t1
    CHECK_REG(13, t2, 0x12345678)

    // Zbb: extension, rotation, OR-combine, and byte reverse.
    li t3, 0x00000080
    sext.b t2, t3
    CHECK_REG(14, t2, 0xffffff80)
    li t3, 0x00008001
    sext.h t2, t3
    CHECK_REG(15, t2, 0xffff8001)
    zext.h t2, t1
    CHECK_REG(16, t2, 0x0000cdef)
    rol t2, t0, t1
    CHECK_REG(17, t2, 0x2b3c091a)
    ror t2, t0, t1
    CHECK_REG(18, t2, 0xacf02468)
    rori t2, t0, 7
    CHECK_REG(19, t2, 0xf02468ac)
    li t3, 0x12003400
    orc.b t2, t3
    CHECK_REG(20, t2, 0xff00ff00)
    rev8 t2, t0
    CHECK_REG(21, t2, 0x78563412)

    // Zbc: all three slices of the same carry-less product.
    clmul t2, t0, t1
    CHECK_REG(22, t2, 0x45cd25a8)
    clmulr t2, t0, t1
    CHECK_REG(23, t2, 0x132497aa)
    clmulh t2, t0, t1
    CHECK_REG(24, t2, 0x09924bd5)

    // Zbs: register and immediate single-bit forms.
    li t3, 4
    bclr t2, t0, t3
    CHECK_REG(25, t2, 0x12345668)
    bclri t2, t0, 4
    CHECK_REG(26, t2, 0x12345668)
    bext t2, t0, t3
    CHECK_REG(27, t2, 1)
    bexti t2, t0, 4
    CHECK_REG(28, t2, 1)
    binv t2, t0, t3
    CHECK_REG(29, t2, 0x12345668)
    binvi t2, t0, 4
    CHECK_REG(30, t2, 0x12345668)
    li t3, 7
    bset t2, t0, t3
    CHECK_REG(31, t2, 0x123456f8)
    bseti t2, t0, 7
    CHECK_REG(32, t2, 0x123456f8)

    // Zbkb instructions not already covered by their Zbb overlap.
    pack t2, t0, t1
    CHECK_REG(33, t2, 0xcdef5678)
    packh t2, t0, t1
    CHECK_REG(34, t2, 0x0000ef78)
    brev8 t2, t0
    CHECK_REG(35, t2, 0x482c6a1e)
    zip t2, t0
    CHECK_REG(36, t2, 0x131c1f60)
    unzip t2, t0
    CHECK_REG(37, t2, 0x141646ec)

    // Zbkx crossbar permutations, including an out-of-range selector.
    li t3, 0x01234567
    xperm4 t2, t0, t3
    CHECK_REG(38, t2, 0x87654321)
    li t3, 0x04020103
    xperm8 t2, t0, t3
    CHECK_REG(39, t2, 0x00345612)

    // Back-to-back dependency and EX result forwarding.
    andn t2, t0, t1
    xnor t3, t2, t1
    CHECK_REG(40, t3, 0x64402000)
    clmul t2, t0, t1
    addi t3, t2, 1
    CHECK_REG(41, t3, 0x45cd25a9)

    // Load repair into both the one-cycle and iterative resources.
    la t4, b_data
    lw t0, 0(t4)
    lw t1, 4(t4)
    xnor t2, t0, t1
    CHECK_REG(42, t2, 0x64606468)
    lw t0, 0(t4)
    lw t1, 4(t4)
    clmul t2, t0, t1
    CHECK_REG(43, t2, 0x45cd25a8)

    // A B instruction fetched in Slot 1 must be replayed as Slot 0.
    li t0, 0x12345678
    li t1, 0x89abcdef
    .align 3
    addi s0, x0, 123
    andn s1, t0, t1
    addi s2, s1, 1
    CHECK_REG(44, s2, 0x12141211)

    // A wrong-path multi-cycle B operation must be flushed without commit.
    li t2, 55
    beq x0, x0, 1f
    clmul t2, t0, t1
    addi t2, t2, 99
1:
    CHECK_REG(45, t2, 55)

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
b_data:
    .word 0x12345678
    .word 0x89abcdef
RVTEST_DATA_END
