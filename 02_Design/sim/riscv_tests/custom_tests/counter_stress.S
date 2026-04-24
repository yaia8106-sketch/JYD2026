# ============================================================
# Counter Stress Test: repeated load-modify-store to same addr
# Mimics the current program's ISA test pass counter pattern:
#   DRAM[0]++ executed N times, then verified
# ============================================================

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    INIT_XREG

    # Base address in DRAM (cacheable region)
    lui   a0, 0x80100        # a0 = 0x80100000 (DRAM base)

    # ---- Test 1: Single increment ----
    # DRAM[0] starts at 0 (from DRAM init)
    lw    t0, 0(a0)          # load counter (cold miss → refill)
    addi  t0, t0, 1          # increment
    sw    t0, 0(a0)          # store back
    # Verify
    lw    t1, 0(a0)
    li    t2, 1
    bne   t1, t2, fail

    # ---- Test 2: Increment 36 more times (total 37, like current program) ----
    # Each iteration: lw, addi, sw with function-call-like overhead
    li    s0, 36             # loop counter
    lui   s1, 0x80100        # s1 = 0x80100000 (recompute like real program)
inc_loop:
    # Simulate the auipc+addi pattern from the real program
    lw    t1, 0(s1)          # load current count
    addi  t1, t1, 1          # increment
    sw    t1, 0(s1)          # store back

    # Simulate some work between increments (like function returns)
    nop
    nop
    nop
    nop

    addi  s0, s0, -1
    bnez  s0, inc_loop

    # ---- Test 3: Final verification — should be 37 ----
    lw    t0, 0(a0)
    li    t1, 37
    bne   t0, t1, fail

    # ---- Test 4: Read after many nops (cold pipeline) ----
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lw    t0, 0(a0)
    li    t1, 37
    bne   t0, t1, fail

    # ---- Test 5: Increment with function-call-like stack ops ----
    # Simulate the function call overhead that display_seg_hex has
    addi  sp, sp, -16
    sw    ra, 12(sp)
    sw    s0, 8(sp)

    lui   a5, 0x80100
    lw    a5, 0(a5)          # this is the exact pattern in display_seg_hex
    li    t1, 37
    bne   a5, t1, fail

    lw    s0, 8(sp)
    lw    ra, 12(sp)
    addi  sp, sp, 16

pass:
    RVTEST_PASS
fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
