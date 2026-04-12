`timescale 1ns / 1ps
// ============================================================
// Module: student_top
// Description: 顶层连线，集成 cpu_top + IROM + perip_bridge
//
// 层次结构:
//   top.sv (模板，不可修改)
//     └── student_top (本文件)
//           ├── cpu_top         (自研 RV32I 五级流水线)
//           ├── IROM            (BRAM ROM, 有 output register, 2 拍)
//           └── perip_bridge    (自研外设桥)
//                 ├── DRAM      (BRAM RAM, 无 output register, 1 拍)
//                 ├── counter   (模板，CDC)
//                 └── display_seg + seg7 (模板)
//
// 复位约定:
//   top.sv 传入 w_clk_rst = ~pll_locked (高有效)
//   cpu_top 需要 rst_n (低有效) → 取反
//   perip_bridge 需要 rst (高有效) → 直连
// ============================================================

module student_top #(
    parameter P_SW_CNT  = 64,
    parameter P_LED_CNT = 32,
    parameter P_SEG_CNT = 40,
    parameter P_KEY_CNT = 8
) (
    input                            w_cpu_clk,
    input                            w_clk_50Mhz,
    input                            w_clk_rst,      // 高有效复位
    input  [P_KEY_CNT - 1:0]         virtual_key,
    input  [P_SW_CNT  - 1:0]         virtual_sw,

    output [P_LED_CNT - 1:0]         virtual_led,
    output [P_SEG_CNT - 1:0]         virtual_seg
);

    // ================================================================
    //  内部连线
    // ================================================================

    // CPU ↔ IROM
    logic [31:0] irom_addr;
    logic [31:0] irom_data;

    // CPU ↔ perip_bridge
    logic [31:0] perip_addr;
    logic [3:0]  perip_wea;
    logic [31:0] perip_wdata;
    logic [31:0] perip_rdata;

    // ================================================================
    //  CPU Core
    // ================================================================
    cpu_top u_cpu (
        .clk         (w_cpu_clk),
        .rst_n       (~w_clk_rst),       // 复位极性反转

        // IROM 接口 (IF stage)
        .irom_addr   (irom_addr),
        .irom_data   (irom_data),

        // 外设总线 (EX stage → bridge)
        .perip_addr  (perip_addr),
        .perip_wea   (perip_wea),
        .perip_wdata (perip_wdata),
        .perip_rdata (perip_rdata)
    );

    // ================================================================
    //  IROM (Block Memory Generator ROM)
    //  配置: 32bit, 4096 depth (16KB), 有 output register (2 拍)
    //  地址: word 地址 = irom_addr[13:2], 12 bit
    // ================================================================
    IROM4MyOwn u_irom (
        .clka  (w_cpu_clk),
        .addra (irom_addr[13:2]),        // 12-bit word address
        .douta (irom_data)
    );

    // ================================================================
    //  Peripheral Bridge (DRAM + MMIO)
    // ================================================================
    perip_bridge u_bridge (
        .clk     (w_cpu_clk),
        .cnt_clk (w_clk_50Mhz),
        .rst     (w_clk_rst),            // 高有效，直连

        // CPU 总线
        .addr    (perip_addr),
        .wea     (perip_wea),
        .wdata   (perip_wdata),
        .rdata   (perip_rdata),

        // 平台 I/O
        .sw      (virtual_sw),
        .key     (virtual_key),
        .led     (virtual_led),
        .seg     (virtual_seg)
    );

endmodule
