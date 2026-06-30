#include "riscv_test.h"

// Test: DIRECT_BRAM critical-word early issue and speculative-read discard.
// Four cold lines request each possible word offset. Hit and recent-store
// forwarding cases are immediately followed by real misses so a discarded
// speculative BRAM response cannot be mistaken for the next refill.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    la    a0, refill_line0
    la    a1, refill_line1
    la    a2, refill_line2
    la    a3, refill_line3
    la    a4, spec_store_word

    li    TESTNUM, 1
    lw    t0, 0(a0)
    li    t1, 0x00112233
    bne   t0, t1, fail

    // Cache hit followed immediately by a cold miss. The hit's speculative
    // external read must not create a logical refill response.
    li    TESTNUM, 2
    li    t1, 0x00112233
    li    t3, 0x44556677
    lw    t0, 0(a0)
    lw    t2, 4(a1)
    bne   t0, t1, fail
    bne   t2, t3, fail

    // A recent-store miss-buffer hit followed immediately by a cold miss.
    // The forwarded load must discard its speculative external read.
    li    TESTNUM, 3
    li    t4, 0xDEADBEEF
    sw    t4, 0(a4)
    lw    t5, 0(a4)
    lw    t6, 8(a2)
    bne   t5, t4, fail
    li    t1, 0x8899AABB
    bne   t6, t1, fail

    li    TESTNUM, 4
    lw    t0, 12(a3)
    li    t1, 0xCCDDEEFF
    bne   t0, t1, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 10
refill_line0:
    .word 0x00112233, 0x10213243, 0x20314253, 0x30415263
    .space 1008
refill_line1:
    .word 0x34455667, 0x44556677, 0x54657687, 0x64758697
    .space 1008
refill_line2:
    .word 0x68798A9B, 0x78899AAB, 0x8899AABB, 0x98A9BACB
    .space 1008
refill_line3:
    .word 0x9CADBECF, 0xACBDCEDF, 0xBCCDEEFF, 0xCCDDEEFF
    .space 1008
spec_store_word:
    .word 0
RVTEST_DATA_END
