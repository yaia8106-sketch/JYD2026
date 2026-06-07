#include "riscv_test.h"

# AXI/backend-oriented DCache test.
# It verifies that byte/half/word stores are written back through the memory
# backend and survive eviction/refill. The last-word case also checks refill
# forwarding when the requested word is the final beat of a cache line.

RVTEST_RV32U
RVTEST_CODE_BEGIN

    lui   a0, 0x80100          # cacheable DRAM base: 0x80100000

    # Fill base line and verify normal store hit/load hit.
    li    TESTNUM, 1
    li    t0, 0x11223344
    sw    t0, 0(a0)
    lw    t1, 0(a0)
    bne   t1, t0, fail

    # Byte writeback: update byte lane 1, evict the line, then force refill.
    li    TESTNUM, 2
    li    t0, 0x000000AA
    sb    t0, 1(a0)
    li    t2, 0x1122AA44
    lw    t1, 0(a0)
    bne   t1, t2, fail
    jal   ra, evict_base_line
    lw    t1, 0(a0)
    bne   t1, t2, fail

    # Halfword writeback: update upper halfword, evict, refill, recheck.
    li    TESTNUM, 3
    li    t0, 0x000055CC
    sh    t0, 2(a0)
    li    t2, 0x55CCAA44
    lw    t1, 0(a0)
    bne   t1, t2, fail
    jal   ra, evict_base_line
    lw    t1, 0(a0)
    bne   t1, t2, fail

    # Last word of the line: refill must forward the final returned beat.
    li    TESTNUM, 4
    li    t0, 0xA5A5F00D
    sw    t0, 12(a0)
    lw    t1, 12(a0)
    bne   t1, t0, fail
    jal   ra, evict_base_line
    lw    t1, 12(a0)
    bne   t1, t0, fail

    # Back-to-back stores force store-buffer drain ordering before refill.
    li    TESTNUM, 5
    li    t0, 0x01020304
    li    t1, 0xAABBCCDD
    sw    t0, 4(a0)
    sw    t1, 8(a0)
    jal   ra, evict_base_line
    lw    t2, 4(a0)
    bne   t2, t0, fail
    lw    t2, 8(a0)
    bne   t2, t1, fail

pass:
    RVTEST_PASS

fail:
    RVTEST_FAIL

evict_base_line:
    addi  a1, a0, 1024        # same index, other tag
    li    a2, 2048
    add   a2, a0, a2          # same index, third tag
    lw    s0, 0(a1)
    lw    s1, 0(a2)
    ret

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
