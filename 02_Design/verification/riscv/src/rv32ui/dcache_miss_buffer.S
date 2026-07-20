#include "riscv_test.h"

// Test: two-entry recent-store miss buffer with independent direct-BRAM drain.
// Focus:
//   1. Consecutive stores remain visible while older stores drain in parallel.
//   2. Drained entries remain searchable until one of the next two stores
//      overwrites their physical slot.
//   3. Physical pending states 01 and 10 both preserve forwarding.
//   4. Byte/half loads forward when every consumed byte is covered.
//   5. Partial coverage falls back to refill and merges recent store bytes.
//   6. The younger of two overlapping stores wins.
//   7. Push/pop overlap reuses the drained slot without losing recent data.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    la    a0, mb_line0
    la    a1, mb_line1
    la    a2, mb_line2
    la    a3, mb_line3
    la    a4, mb_line4
    la    a5, mb_line5
    la    a6, mb_line6
    la    a7, mb_line7

    // ================================================================
    // Part 1: consecutive stores rotate through both physical entries while
    // the dedicated BRAM write port drains the older store in parallel.
    // ================================================================
    li    TESTNUM, 1
    li    t0, 0x10203040
    li    t1, 0x50607080
    sw    t0, 0(a0)
    sw    t1, 0(a1)
    lw    t2, 0(a0)
    bne   t2, t0, fail

    li    TESTNUM, 2
    lw    t2, 0(a1)
    bne   t2, t1, fail

    // Let both backend writes complete. Their recent-store payloads must stay.
    .rept 12
        nop
    .endr

    // ================================================================
    // Part 2: pending=00. Both drained entries remain directly readable.
    // ================================================================
    li    TESTNUM, 3
    lw    t2, 0(a0)
    bne   t2, t0, fail

    li    TESTNUM, 4
    lw    t2, 0(a1)
    bne   t2, t1, fail

    // ================================================================
    // Part 3: exercise the two one-pending physical states (01 and 10).
    // ================================================================
    li    TESTNUM, 5
    li    t0, 0x89ABCDEF
    sw    t0, 0(a2)
    lw    t2, 0(a2)
    bne   t2, t0, fail

    .rept 8
        nop
    .endr

    li    TESTNUM, 6
    li    t1, 0x76543210
    sw    t1, 0(a3)
    lw    t2, 0(a3)
    bne   t2, t1, fail

    .rept 8
        nop
    .endr

    // ================================================================
    // Part 4: drained partial stores.
    // LBU/LHU are fully covered; LW must refill and merge the stored bytes.
    // ================================================================
    li    TESTNUM, 7
    li    t0, 0xAA
    sb    t0, 1(a4)
    .rept 8
        nop
    .endr
    lbu   t1, 1(a4)
    bne   t1, t0, fail

    li    TESTNUM, 8
    lw    t2, 0(a4)
    li    t3, 0x1122AA44
    bne   t2, t3, fail

    li    TESTNUM, 9
    li    t0, 0xBEEF
    sh    t0, 2(a5)
    .rept 8
        nop
    .endr
    lhu   t1, 2(a5)
    bne   t1, t0, fail

    li    TESTNUM, 10
    lw    t2, 0(a5)
    li    t3, 0xBEEF3344
    bne   t2, t3, fail

    // ================================================================
    // Part 5: both entries match one word. The younger byte store wins.
    // ================================================================
    li    TESTNUM, 11
    li    t0, 0xA1B2C3D4
    li    t1, 0x66
    sw    t0, 0(a6)
    sb    t1, 1(a6)
    lw    t2, 0(a6)
    li    t3, 0xA1B266D4
    bne   t2, t3, fail

    // The next store can reuse a drained slot without losing the other entry.
    li    TESTNUM, 12
    li    t4, 0x0BADF00D
    sw    t4, 0(a7)
    lw    t2, 0(a6)
    bne   t2, t3, fail

    li    TESTNUM, 13
    lw    t2, 0(a7)
    bne   t2, t4, fail

    // ================================================================
    // Part 6: three consecutive stores exercise steady-state push/pop overlap.
    // ================================================================
    .rept 12
        nop
    .endr

    li    TESTNUM, 14
    li    t0, 0x13579BDF
    li    t1, 0x2468ACE0
    li    t4, 0x55AA33CC
    sw    t0, 4(a0)
    sw    t1, 4(a1)
    sw    t4, 4(a2)

    // The first store is no longer recent, but it was written before its slot
    // was reused and therefore must be visible through refill.
    lw    t2, 4(a0)
    bne   t2, t0, fail

    li    TESTNUM, 15
    lw    t2, 4(a1)
    bne   t2, t1, fail

    li    TESTNUM, 16
    lw    t2, 4(a2)
    bne   t2, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 10
mb_line0:
    .word 0x01020304, 0x11121314, 0x21222324, 0x31323334
    .space 1008
mb_line1:
    .word 0x41424344, 0x51525354, 0x61626364, 0x71727374
    .space 1008
mb_line2:
    .word 0x81828384, 0x91929394, 0xA1A2A3A4, 0xB1B2B3B4
    .space 1008
mb_line3:
    .word 0xC1C2C3C4, 0xD1D2D3D4, 0xE1E2E3E4, 0xF1F2F3F4
    .space 1008
mb_line4:
    .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00
    .space 1008
mb_line5:
    .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00
    .space 1008
mb_line6:
    .word 0x01234567, 0x89ABCDEF, 0x10293847, 0x56473829
    .space 1008
mb_line7:
    .word 0xFFEEDDCC, 0xBBAA9988, 0x77665544, 0x33221100
RVTEST_DATA_END
