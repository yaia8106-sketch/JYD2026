# ============================================================
# DCache Stress Test: exercises scenarios that may fail on hw
#   1. Store-then-load forwarding (same cache line)
#   2. Cache miss during back-to-back loads
#   3. Branch + cache miss interaction
#   4. MMIO read interleaved with cacheable ops
#   5. Store buffer drain timing
# ============================================================

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    # Initialize registers
    INIT_XREG

    # Base address in DRAM (cacheable region)
    lui   a0, 0x80100        # a0 = 0x80100000 (DRAM base)

    # ---- Test 1: Store then immediate load (same word) ----
    li    t0, 0xDEADBEEF
    sw    t0, 0(a0)          # store to DRAM[0]
    lw    t1, 0(a0)          # load from DRAM[0] (should forward or hit)
    bne   t0, t1, fail

    # ---- Test 2: Store then load different word, same cache line ----
    li    t0, 0xCAFEBABE
    sw    t0, 4(a0)          # store to DRAM[1]
    li    t2, 0x12345678
    sw    t2, 8(a0)          # store to DRAM[2]
    lw    t1, 4(a0)          # load DRAM[1]
    bne   t0, t1, fail
    lw    t1, 8(a0)          # load DRAM[2]
    bne   t2, t1, fail

    # ---- Test 3: Force cache miss (access far-apart addresses) ----
    # Cache is 2KB 2-way, line=4 words. Access stride = 1 cache way = 1KB
    # Addresses that will conflict: base+0, base+1024, base+2048
    li    t0, 0x11111111
    sw    t0, 0(a0)          # set 0, way 0
    li    t0, 0x22222222
    addi  a1, a0, 1024       # a1 = base + 1024 (conflicts with set 0)
    sw    t0, 0(a1)          # set 0, way 1
    li    t0, 0x33333333
    lui   a2, %hi(2048)
    addi  a2, a2, %lo(2048)
    add   a2, a0, a2         # a2 = base + 2048 (evicts one from set 0)
    sw    t0, 0(a2)          # MISS → refill → evict

    # Now load back the evicted value (miss again)
    lw    t1, 0(a0)          # should read 0x11111111 (might be evicted)
    li    t3, 0x11111111
    bne   t1, t3, fail

    # ---- Test 4: MMIO read between cacheable ops ----
    # Access SW0 at 0x8020_0000
    lui   a3, 0x80200        # a3 = 0x80200000 (MMIO SW0)
    li    t0, 0xAAAA5555
    sw    t0, 16(a0)         # cacheable store
    lw    t4, 0(a3)          # MMIO read (non-cacheable) — don't care about value
    lw    t1, 16(a0)         # cacheable load (verify store persisted)
    li    t3, 0xAAAA5555
    bne   t1, t3, fail

    # ---- Test 5: Rapid store-load pattern (stress store buffer) ----
    li    t0, 100
    addi  a4, a0, 256        # offset to avoid previous data
loop:
    sw    t0, 0(a4)
    lw    t1, 0(a4)
    bne   t0, t1, fail
    addi  t0, t0, -1
    addi  a4, a4, 4
    bnez  t0, loop

    # ---- Test 6: Branch over cache miss ----
    li    t5, 1
    bnez  t5, skip_miss      # taken branch
    lui   a5, 1              # a5 = 4096, this should NOT execute
    add   a5, a0, a5         # a5 = base + 4096
    lw    t0, 0(a5)          # neither should this (cache miss)
skip_miss:
    # Verify branch was taken correctly
    li    t0, 0xBEEF
    sw    t0, 20(a0)
    lw    t1, 20(a0)
    li    t3, 0xBEEF
    bne   t1, t3, fail

    # ---- Test 7: Multiple consecutive misses (different sets) ----
    li    s0, 0x01010101
    li    s1, 0x02020202
    li    s2, 0x03030303
    li    s3, 0x04040404
    sw    s0, 64(a0)        # set 1 (assuming 4-word lines, set = offset[?])
    sw    s1, 128(a0)       # set 2
    sw    s2, 192(a0)       # set 3
    sw    s3, 256(a0)       # set 4
    # Read back in reverse order to cause misses
    lw    t0, 256(a0)
    bne   t0, s3, fail
    lw    t0, 192(a0)
    bne   t0, s2, fail
    lw    t0, 128(a0)
    bne   t0, s1, fail
    lw    t0, 64(a0)
    bne   t0, s0, fail

pass:
    RVTEST_PASS
fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
