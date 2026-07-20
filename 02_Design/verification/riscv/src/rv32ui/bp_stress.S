# ============================================================
# BP Stress Test: exercises branch predictor edge cases
#   1.  Simple tight loop (100 iterations)
#   2.  Nested loop (10x10 = 100)
#   3.  Alternating taken/not-taken (odd/even)
#   4.  Multi-way branch (3-level if-else chain)
#   5.  Call chain: func_a / func_b(->a) / func_c(->b) (RAS)
#   6.  Recursive function (depth=8, sum=36)
#   7.  Indirect jumps (JALR to computed targets)
#   8.  Long beqz-always-taken chain (35 branches x2)
#   9.  Load-branch interleave (bnez/beqz after lw)
#   10. Nested alternating + correlated branches
#   11. Mixed condition types (bgtz/blez/beqz/bnez/bltu/bgeu)
#   12. Fibonacci loop (14 iterations)
#   13. Hot loop then alternating pattern
# ============================================================

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

    # ---- Test 1: Simple tight loop ----
    li    gp, 1
    li    s0, 0
    li    t0, 100
test1_loop:
    addi  s0, s0, 1
    bne   s0, t0, test1_loop
    li    t0, 100
    bne   s0, t0, fail

    # ---- Test 2: Nested loop (10x10) ----
    li    gp, 2
    li    s0, 0
    li    t0, 10
test2_outer:
    li    t1, 10
test2_inner:
    addi  s0, s0, 1
    addi  t1, t1, -1
    bnez  t1, test2_inner
    addi  t0, t0, -1
    bnez  t0, test2_outer
    li    t0, 100
    bne   s0, t0, fail

    # ---- Test 3: Alternating direction ----
    li    gp, 3
    li    s0, 0
    li    t0, 0
    li    t1, 20
test3_loop:
    andi  t2, t0, 1
    beqz  t2, test3_even
    addi  s0, s0, 1
    j     test3_next
test3_even:
    addi  s0, s0, 2
test3_next:
    addi  t0, t0, 1
    bne   t0, t1, test3_loop
    li    t0, 30
    bne   s0, t0, fail

    # ---- Test 4: Multi-way branch ----
    li    gp, 4
    li    s0, 0
    li    t0, 0
    li    t1, 32
test4_loop:
    li    t2, 16
    blt   t0, t2, test4_small
    li    t2, 24
    blt   t0, t2, test4_mid
    addi  s0, s0, 4
    j     test4_next
test4_mid:
    addi  s0, s0, 2
    j     test4_next
test4_small:
    addi  s0, s0, 1
test4_next:
    addi  t0, t0, 1
    bne   t0, t1, test4_loop
    li    t0, 64
    bne   s0, t0, fail

    j     test5_start

    # ---- Helper functions for Test 5 ----
func5_a:
    addi  s0, s0, 1
    ret

func5_b:
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   func5_a
    lw    ra, 0(sp)
    addi  sp, sp, 4
    addi  s0, s0, 2
    ret

func5_c:
    addi  sp, sp, -4
    sw    ra, 0(sp)
    jal   func5_b
    lw    ra, 0(sp)
    addi  sp, sp, 4
    addi  s0, s0, 4
    ret

    # ---- Recursive helper for Test 6 ----
func6_rec:
    beqz  a0, func6_base
    addi  sp, sp, -8
    sw    ra, 4(sp)
    sw    a0, 0(sp)
    addi  a0, a0, -1
    jal   func6_rec
    lw    t0, 0(sp)
    lw    ra, 4(sp)
    addi  sp, sp, 8
    add   a0, a0, t0
    ret
func6_base:
    li    a0, 0
    ret

    # ---- Test 5: Call chain (RAS) ----
test5_start:
    li    gp, 5
    li    s0, 0
    jal   func5_a              # s0 += 1
    jal   func5_b              # s0 += 1+2 = 3
    jal   func5_c              # s0 += 1+2+4 = 7, total = 11
    li    t0, 11
    bne   s0, t0, fail

    # ---- Test 6: Recursive (depth=8, sum=36) ----
    li    gp, 6
    li    a0, 8
    jal   func6_rec
    li    t0, 36
    bne   a0, t0, fail

    # ---- Test 7: Indirect jumps (JALR) ----
    li    gp, 7
    li    s0, 0
    auipc t0, 0
    addi  t0, t0, 16          # -> test7_tgt1
    jr    t0
    j     fail
test7_tgt1:
    addi  s0, s0, 1
    auipc t0, 0
    addi  t0, t0, 16          # -> test7_tgt2
    jr    t0
    j     fail
test7_tgt2:
    addi  s0, s0, 2
    auipc t0, 0
    addi  t0, t0, 16          # -> test7_tgt3
    jr    t0
    j     fail
test7_tgt3:
    addi  s0, s0, 4
    li    t0, 7
    bne   s0, t0, fail

    # ---- Test 8: Long always-taken beqz chain ----
    li    gp, 8
    li    s0, 0
    li    s1, 2               # 2 outer iterations
test8_outer:
    .rept 35
    beqz  zero, 1f
    j     fail
1:  addi  s0, s0, 1
    .endr
    addi  s1, s1, -1
    bnez  s1, test8_outer
    li    t0, 70              # 35 * 2
    bne   s0, t0, fail

    # ---- Test 9: Load-branch interleave ----
    li    gp, 9
    li    s0, 0
    li    t0, 42
    sw    t0, -4(sp)
    sw    zero, -8(sp)
    li    t3, 10
test9_loop:
    lw    t0, -4(sp)
    bnez  t0, test9_ok1
    j     fail
test9_ok1:
    addi  s0, s0, 1
    lw    t1, -8(sp)
    beqz  t1, test9_ok2
    j     fail
test9_ok2:
    addi  s0, s0, 1
    addi  t3, t3, -1
    bnez  t3, test9_loop
    li    t0, 20
    bne   s0, t0, fail

    # ---- Test 10: Correlated branches ----
    li    gp, 10
    li    s0, 0
    li    t0, 0
    li    t1, 16
test10_loop:
    andi  t2, t0, 3
    beqz  t2, test10_b1t
    addi  s0, s0, 1
    j     test10_b2
test10_b1t:
    addi  s0, s0, 10
test10_b2:
    andi  t2, t0, 1
    beqz  t2, test10_b2t
    addi  s0, s0, 1
    j     test10_next
test10_b2t:
    addi  s0, s0, 100
test10_next:
    addi  t0, t0, 1
    bne   t0, t1, test10_loop
    li    t0, 860
    bne   s0, t0, fail

    # ---- Test 11: Mixed conditions ----
    li    gp, 11
    li    s0, 0
    li    t0, 5
    li    t1, -1
    li    t2, 1
    li    t3, 10
    li    t4, 20
    bgtz  t0, test11_a
    j     fail
test11_a:
    addi  s0, s0, 1
    blez  t1, test11_b
    j     fail
test11_b:
    addi  s0, s0, 1
    beqz  zero, test11_c
    j     fail
test11_c:
    addi  s0, s0, 1
    bnez  t2, test11_d
    j     fail
test11_d:
    addi  s0, s0, 1
    bltu  t3, t4, test11_e
    j     fail
test11_e:
    addi  s0, s0, 1
    bgeu  t4, t3, test11_f
    j     fail
test11_f:
    addi  s0, s0, 1
    li    t0, 6
    bne   s0, t0, fail

    # ---- Test 12: Fibonacci (14 iter, fib(16)=610) ----
    li    gp, 12
    li    t3, 0               # fib(n-2)
    li    t4, 1               # fib(n-1)
    li    t1, 2               # counter
    li    t0, 16
test12_loop:
    add   t5, t3, t4
    mv    t3, t4
    mv    t4, t5
    addi  t1, t1, 1
    bne   t1, t0, test12_loop
    li    t5, 610
    bne   t4, t5, fail

    # ---- Test 13: Hot loop then alternating ----
    li    gp, 13
    li    s0, 0
    li    t0, 30
test13_hot1:
    addi  s0, s0, 1
    addi  t0, t0, -1
    bnez  t0, test13_hot1
    li    t0, 0
    li    t1, 30
test13_hot2:
    andi  t2, t0, 1
    beqz  t2, test13_h2e
    addi  s0, s0, 1
    j     test13_h2n
test13_h2e:
    addi  s0, s0, 2
test13_h2n:
    addi  t0, t0, 1
    bne   t0, t1, test13_hot2
    li    t0, 75              # 30 + 15*1 + 15*2 = 75
    bne   s0, t0, fail

pass:
    RVTEST_PASS
fail:
    RVTEST_FAIL

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN
.align 4
RVTEST_DATA_END
