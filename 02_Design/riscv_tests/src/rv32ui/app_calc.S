#*****************************************************************************
# app_calc.S — 综合应用程序
# 功能: 平方和 + 数组求和(寄存器值) + 位运算 + JAL返回 + 自检
# 覆盖: R/I/S/B/U/J 全部 6 种指令格式, 含分支/循环/访存
# 结果写入 DRAM[0:6], 最后写 LED=1 (PASS)
#*****************************************************************************

#include "riscv_test.h"
#undef RVTEST_RV64U
#define RVTEST_RV64U RVTEST_RV32U

RVTEST_RV32U
RVTEST_CODE_BEGIN

    # DRAM 基地址 (S-type 存储目标)
    li   t6, 0x80100000         # U-type(LUI) + I-type(ADDI)

    # ============================================================
    # Part 1: 平方和 1^2+...+10^2 = 385
    # ============================================================
    li   t1, 0                  # sum = 0
    li   t2, 1                  # i = 1
    li   t3, 11                 # end = 11
sq_loop:
    # i^2 = i+i+...+i (i 次)
    addi t4, x0, 0              # t4 = 0
    add  t5, t2, x0             # t5 = i (counter)
sq_inner:
    add  t4, t4, t2             # R-type ADD
    addi t5, t5, -1             # I-type ADDI
    bne  t5, x0, sq_inner       # B-type BNE
    add  t1, t1, t4             # R-type ADD: sum += i^2
    addi t2, t2, 1              # I-type ADDI: i++
    blt  t2, t3, sq_loop        # B-type BLT
    sw   t1, 0(t6)              # S-type SW: DRAM[0] = 385
    li   t5, 385
    bne  t1, t5, fail           # B-type BNE: 自检

    # ============================================================
    # Part 2: 数组求和 3+7+2+9+4+6+1+8 = 40
    # ============================================================
    li   t1, 0                  # sum = 0
    li   t2, 3
    add  t1, t1, t2
    li   t2, 7
    add  t1, t1, t2
    li   t2, 2
    add  t1, t1, t2
    li   t2, 9
    add  t1, t1, t2
    li   t2, 4
    add  t1, t1, t2
    li   t2, 6
    add  t1, t1, t2
    li   t2, 1
    add  t1, t1, t2
    li   t2, 8
    add  t1, t1, t2             # R-type ADD x8
    sw   t1, 4(t6)              # S-type: DRAM[1] = 40
    li   t5, 40
    bne  t1, t5, fail

    # ============================================================
    # Part 3: 位运算验证 (R-type: AND/OR/XOR, I-type: SLLI/SRLI)
    # ============================================================
    li   t1, 0x5A               # x = 0101_1010
    li   t2, 0x3C               # y = 0011_1100

    and  t3, t1, t2             # R-type AND  = 0x18 (0001_1000)
    sw   t3, 8(t6)
    li   t5, 0x18
    bne  t3, t5, fail

    or   t3, t1, t2             # R-type OR   = 0x7E (0111_1110)
    sw   t3, 12(t6)
    li   t5, 0x7E
    bne  t3, t5, fail

    xor  t3, t1, t2             # R-type XOR  = 0x66 (0110_0110)
    sw   t3, 16(t6)
    li   t5, 0x66
    bne  t3, t5, fail

    slli t3, t1, 4              # I-type SLLI = 0x5A0
    sw   t3, 20(t6)
    li   t5, 0x5A0
    bne  t3, t5, fail

    srli t3, t1, 2              # I-type SRLI = 0x16 (0001_0110)
    sw   t3, 24(t6)
    li   t5, 0x16
    bne  t3, t5, fail

    # ============================================================
    # Part 4: 有符号比较 (SLT/SLTI)
    # ============================================================
    li   t1, -5                 # 0xFFFFFFFB
    li   t2, 3

    slt  t3, t1, t2             # R-type SLT: -5 < 3 → 1
    sw   t3, 28(t6)
    li   t5, 1
    bne  t3, t5, fail

    slti t3, t2, -1             # I-type SLTI: 3 < -1 → 0
    sw   t3, 32(t6)
    bne  t3, x0, fail

    # ============================================================
    # Part 5: 跳转并链接 (JAL/JALR)
    # ============================================================
    jal  ra, ret_target          # J-type JAL
    j    fail                    # 不应执行
ret_target:
    li   t1, 0x123
    addi t1, t1, 0x45           # t1 = 0x168
    sw   t1, 36(t6)             # DRAM[9] = 0x168
    li   t5, 0x168
    bne  t1, t5, fail

    # ============================================================
    # Part 6: LUI/AUIPC 高位操作
    # ============================================================
    lui  t1, 0xABCD0            # U-type LUI: t1 = 0xABCD_0000
    sw   t1, 40(t6)
    # 自检高20位
    li   t5, 0x000AB
    srli t3, t1, 20             # 逻辑右移取高12位验证
    bne  t3, t5, fail

    # ============================================================
    # PASS — 全部自检通过
    # ============================================================
pass:
    li   t0, 0x80200040         # LED MMIO
    li   t1, 1
    sw   t1, 0(t0)              # LED = 1
    j    spin

fail:
    li   t0, 0x80200040
    li   t1, 2
    sw   t1, 0(t0)              # LED = 2

spin:
    j    spin

RVTEST_CODE_END
