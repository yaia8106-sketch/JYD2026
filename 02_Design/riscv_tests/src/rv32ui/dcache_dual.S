#include "riscv_test.h"

// Test: DCache miss + dual-issue interaction
// DCache: 2KB 2-way 16B line. Tag=addr[17:10], Index=addr[9:4].
// Addrs +0x400 apart share the same set index but have different tags.
// Three writes to the same set evict one way → guaranteed load miss.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100         // base = 0x80100000 (set 0, tag 0)
    addi  a1, a0, 0x400       // a1   = 0x80100400 (set 0, tag 1)
    addi  a2, a1, 0x400       // a2   = 0x80100800 (set 0, tag 2)

    // ================================================================
    // Part 1: Evict then load miss + dual-issue S1
    // Fill both ways of set 0, then a third tag evicts one.
    // Load the evicted address → miss. S1 ALU must survive stall.
    // ================================================================
    .align 3
    li    TESTNUM, 1

    li    t0, 0xAA
    sw    t0, 0(a0)           // set 0, tag 0 → way 0
    li    t0, 0xBB
    sw    t0, 0(a1)           // set 0, tag 1 → way 1
    li    t0, 0xCC
    sw    t0, 0(a2)           // set 0, tag 2 → evicts tag 0 or 1

    addi  s0, x0, 0
    addi  s1, x0, 0

    // Load from a0 (tag 0) → likely evicted → cache miss!
    .align 3
    addi  t1, x0, 0
    addi  t2, x0, 0
    lw    t1, 0(a0)           // S0: cache miss → refill stall
    addi  t2, x0, 77          // S1: ALU, must survive stall

    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    li    t4, 0xAA
    bne   t1, t4, fail

    li    TESTNUM, 2
    li    t4, 77
    bne   t2, t4, fail

    // ================================================================
    // Part 2: Cache miss, S1 result forwarded to next instruction
    // lw(miss) + addi t3 → after stall → next reads t3 via forwarding
    // ================================================================
    .align 3
    li    TESTNUM, 3

    // Re-evict: fill tag 0 and tag 2 → tag 1 evicted
    li    t0, 0xDD
    sw    t0, 0(a1)           // refresh tag 1 value
    sw    t0, 0(a0)           // tag 0 fills way
    sw    t0, 0(a2)           // tag 2 fills way → tag 1 evicted

    addi  s0, x0, 0
    addi  s1, x0, 0

    .align 3
    addi  t3, x0, 0
    addi  t5, x0, 0
    lw    t1, 0(a1)           // S0: miss on tag 1
    addi  t3, x0, 50          // S1: t3=50 (survives stall)
    add   t5, t3, t1          // reads t3(fwd) + t1(load)

    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    li    t4, 0xDD
    bne   t1, t4, fail

    li    TESTNUM, 4
    li    t4, 50
    bne   t3, t4, fail

    li    TESTNUM, 5
    // t5 = 50 + 0xDD(221) = 271
    li    t4, 271
    bne   t5, t4, fail

    // ================================================================
    // Part 3: Store miss + write-allocate
    // Evict tag 2, then store to it → write-allocate refill.
    // Read back to verify.
    // ================================================================
    .align 3
    li    TESTNUM, 6

    li    t0, 0x11
    sw    t0, 0(a0)           // tag 0
    sw    t0, 0(a1)           // tag 1 → tag 2 evicted

    addi  s0, x0, 0
    addi  s1, x0, 0

    li    t0, 0xEF
    sw    t0, 0(a2)           // miss → refill → store

    addi  s0, x0, 0
    addi  s1, x0, 0
    addi  s2, x0, 0
    addi  s3, x0, 0

    lw    t1, 0(a2)
    addi  t1, t1, 0
    addi  t1, t1, 0
    addi  t1, t1, 0
    li    t4, 0xEF
    bne   t1, t4, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
