// Custom riscv_test.h for RV32I/Zicsr CPU tests
// Pass/Fail signaling via LED MMIO (0x80200040)
//   PASS: LED = 0x00000001
//   FAIL: LED = test_num << 1 | 1

#ifndef _ENV_CUSTOM_RV32I_ZICSR_H
#define _ENV_CUSTOM_RV32I_ZICSR_H

//-----------------------------------------------------------------------
// Begin/End Macros
//-----------------------------------------------------------------------

#define RVTEST_RV32U                                                    \
  .macro init;                                                          \
  .endm

#define INIT_XREG                                                       \
  li x1, 0;                                                             \
  li x2, 0;                                                             \
  li x3, 0;                                                             \
  li x4, 0;                                                             \
  li x5, 0;                                                             \
  li x6, 0;                                                             \
  li x7, 0;                                                             \
  li x8, 0;                                                             \
  li x9, 0;                                                             \
  li x10, 0;                                                            \
  li x11, 0;                                                            \
  li x12, 0;                                                            \
  li x13, 0;                                                            \
  li x14, 0;                                                            \
  li x15, 0;                                                            \
  li x16, 0;                                                            \
  li x17, 0;                                                            \
  li x18, 0;                                                            \
  li x19, 0;                                                            \
  li x20, 0;                                                            \
  li x21, 0;                                                            \
  li x22, 0;                                                            \
  li x23, 0;                                                            \
  li x24, 0;                                                            \
  li x25, 0;                                                            \
  li x26, 0;                                                            \
  li x27, 0;                                                            \
  li x28, 0;                                                            \
  li x29, 0;                                                            \
  li x30, 0;                                                            \
  li x31, 0;

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl _start;                                                  \
_start:                                                                 \
        INIT_XREG;                                                      \
        /* Set up stack pointer in DRAM */                              \
        lui sp, %hi(0x80140000);                                        \
        addi sp, sp, %lo(0x80140000);                                   \
        li TESTNUM, 0;                                                  \
        init;

#define RVTEST_CODE_END                                                 \
        unimp

//-----------------------------------------------------------------------
// Pass/Fail Macros — write to LED MMIO, then spin
//-----------------------------------------------------------------------

#define LED_ADDR 0x80200040

#define TESTNUM gp

#define RVTEST_PASS                                                     \
        li t0, LED_ADDR;                                                \
        li t1, 1;                                                       \
        sw t1, 0(t0);                                                   \
1:      j 1b;

#define RVTEST_FAIL                                                     \
        li t0, LED_ADDR;                                                \
1:      beqz TESTNUM, 1b;                                               \
        sll TESTNUM, TESTNUM, 1;                                        \
        or TESTNUM, TESTNUM, 1;                                         \
        sw TESTNUM, 0(t0);                                              \
2:      j 2b;

//-----------------------------------------------------------------------
// Data Section Macros
//-----------------------------------------------------------------------

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN                                               \
        EXTRA_DATA                                                      \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
