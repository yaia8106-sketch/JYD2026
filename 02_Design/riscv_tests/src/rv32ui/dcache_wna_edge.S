#include "riscv_test.h"

// Test: DCache write-through + write-no-allocate edge cases.
// Focus:
//   1. store-miss SB/SH/SW do not allocate cache.
//   2. load-miss refill merges a pending store-buffer entry by byte mask.
//   3. a pending store to another word in the same line does not corrupt the
//      requested word.
//   4. last-beat refill forwarding uses the merged data.
//   5. two pending stores can both be merged into a refill.
//   6. when the two-entry store buffer is full, the next store waits for a
//      drain and then still preserves program-order data visibility.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    la    a0, wna_line0
    la    a1, wna_line1
    la    a2, wna_line2
    la    a3, wna_line3
    la    a4, wna_line4

    // ================================================================
    // Part 1: SB miss, immediate LW miss to same word.
    // Old DRAM word is 0x11223344. Refill must merge byte lane 1.
    // ================================================================
    li    TESTNUM, 1
    li    t0, 0xAA
    sb    t0, 1(a0)           // miss -> SB only
    lw    t1, 0(a0)           // miss -> refill + SB byte merge
    li    t2, 0x1122AA44
    bne   t1, t2, fail

    // The merged value must stay in cache after the refill completes.
    li    TESTNUM, 2
    lw    t1, 0(a0)
    bne   t1, t2, fail

    // ================================================================
    // Part 2: SH miss to word2, immediate LW miss to word0.
    // The requested word0 must not be polluted by the pending word2 store.
    // Later word2 hit must contain the merged halfword.
    // ================================================================
    li    TESTNUM, 3
    li    t0, 0xBEEF
    sh    t0, 10(a1)          // miss -> SB only, targets word2 upper half
    lw    t1, 0(a1)           // miss -> refill, requested word is not stored word
    li    t2, 0x01020304
    bne   t1, t2, fail

    li    TESTNUM, 4
    lw    t1, 8(a1)           // hit after refill; word2 must be merged
    li    t2, 0xBEEF2526
    bne   t1, t2, fail

    // ================================================================
    // Part 3: SW miss to the final word of a line.
    // The requested word is the last refill beat, so the last-word forward
    // register must hold the merged value, not the stale backend data.
    // ================================================================
    li    TESTNUM, 5
    li    t0, 0xCAFEBABE
    sw    t0, 12(a2)          // miss -> SB only
    lw    t1, 12(a2)          // miss -> refill + final-beat merge/forward
    bne   t1, t0, fail

    // ================================================================
    // Part 4: two-entry SB, two store misses to the same line.
    // The immediate load miss must merge both pending stores into the refill.
    // ================================================================
    li    TESTNUM, 6
    li    t0, 0x11111111
    li    t1, 0x22222222
    sw    t0, 0(a3)           // miss -> SB only
    sw    t1, 4(a3)           // miss -> second SB entry

    lw    t2, 0(a3)           // refill must merge entry0
    bne   t2, t0, fail

    li    TESTNUM, 7
    lw    t2, 4(a3)           // same refill line must also contain entry1
    bne   t2, t1, fail

    // Give the background drain time to empty the two entries before the next
    // full-buffer sequence.
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0
    addi  x0, x0, 0

    // ================================================================
    // Part 5: overlapping stores and a third store while SB is full.
    // The third store must wait for the oldest entry to drain. The following
    // load miss observes the drained oldest word from memory, merges the
    // younger byte store over it, and also merges the third store.
    // ================================================================
    li    TESTNUM, 8
    li    t0, 0xAAAA5555
    li    t1, 0x77
    li    t4, 0x33333333
    sw    t0, 0(a4)           // pending entry0, full-word store
    sb    t1, 1(a4)           // pending entry1, younger byte override
    sw    t4, 8(a4)           // full SB -> drain entry0, then enqueue

    lw    t2, 0(a4)           // memory has entry0; refill merges entry1 byte
    li    t3, 0xAAAA7755
    bne   t2, t3, fail

    li    TESTNUM, 9
    lw    t2, 8(a4)           // same refill must include the third store
    bne   t2, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 10
wna_line0:
    .word 0x11223344, 0x55667788, 0x99aabbcc, 0xddeeff00
    .space 1008
wna_line1:
    .word 0x01020304, 0x11121314, 0x23242526, 0x33343536
    .space 1008
wna_line2:
    .word 0x41424344, 0x51525354, 0x61626364, 0x71727374
    .space 1008
wna_line3:
    .word 0x81828384, 0x91929394, 0xa1a2a3a4, 0xb1b2b3b4
    .space 1008
wna_line4:
    .word 0x01020304, 0x11121314, 0x23242526, 0x33343536
RVTEST_DATA_END
