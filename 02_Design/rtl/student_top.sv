`timescale 1ns / 1ps
// ============================================================
// Module: student_top
// Description: 顶层连线，集成 cpu_top + IROM + DCache + DRAM + mmio_bridge
//
// 层次结构:
//   top.sv (模板，不可修改)
//     └── student_top (本文件)
//           ├── cpu_top         (自研 RV32I 五级流水线)
//           ├── IROM            (BRAM ROM, 无 output register, 1 拍)
//           ├── dcache          (2KB 2-way WT+WA data cache)
//           │     └── DRAM      (BRAM RAM, SDP, 65536×32)
//           └── mmio_bridge     (LED/SEG/SW/KEY/CNT)
//
// 复位约定:
//   top.sv 传入 w_clk_rst = ~pll_locked (高有效)
//   cpu_top 需要 rst_n (低有效) → 取反
//   mmio_bridge 需要 rst (高有效) → 直连
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
    logic [31:0] irom_addr_plus4;
    logic [63:0] irom_data;
    logic [31:0] irom_data_inst0;
    logic [31:0] irom_data_inst1;
    logic [11:0] irom_word_addr;
    logic [11:0] irom_plus4_word_addr;

    // CPU ↔ DCache
    logic        cache_req;
    logic        cache_wr;
    logic [31:0] cache_addr;
    logic [ 3:0] cache_wea;
    logic [31:0] cache_wdata;
    logic [31:0] cache_rdata;
    logic        cache_ready;

    // CPU ↔ MMIO bridge
    logic [31:0] mmio_addr;
    logic [31:0] mmio_wr_addr;
    logic [ 3:0] mmio_wea;
    logic [31:0] mmio_wdata;
    logic [31:0] mmio_rdata;

    // DCache ↔ DRAM BRAM
    logic [15:0] dram_rd_addr;
    logic [31:0] dram_rdata;
    logic [15:0] dram_wr_addr;
    logic [ 3:0] dram_wea;
    logic [31:0] dram_wdata;

    // DCache flush — driven by cpu_top's cache_flush output
    logic dcache_flush;

    // DCache pipeline sync — driven by cpu_top's ~mem_allowin
    logic cache_pipeline_stall;

    // ================================================================
    //  CPU Core
    // ================================================================
    cpu_top u_cpu (
        .clk         (w_cpu_clk),
        .rst_n       (~w_clk_rst),

        // IROM 接口 (IF stage)
        .irom_addr       (irom_addr),
        .irom_addr_plus4 (irom_addr_plus4),
        .irom_data       (irom_data),

        // DCache 接口
        .cache_req   (cache_req),
        .cache_wr    (cache_wr),
        .cache_addr  (cache_addr),
        .cache_wea   (cache_wea),
        .cache_wdata (cache_wdata),
        .cache_rdata (cache_rdata),
        .cache_ready (cache_ready),
        .cache_flush (dcache_flush),
        .cache_pipeline_stall (cache_pipeline_stall),

        // MMIO 接口
        .mmio_addr    (mmio_addr),
        .mmio_wr_addr (mmio_wr_addr),
        .mmio_wea     (mmio_wea),
        .mmio_wdata   (mmio_wdata),
        .mmio_rdata   (mmio_rdata)
    );

    // ================================================================
    //  IROM fetch window
    //  Reuse the existing 32-bit ROM IP as two read-only banks to present the
    //  same sliding 64-bit window used by the simulation model:
    //    irom_data[31:0]  = inst at PC
    //    irom_data[63:32] = inst at PC + 4
    //  地址: word 地址 = irom_addr[13:2], 12 bit
    // ================================================================
    assign irom_word_addr       = irom_addr[13:2];
    assign irom_plus4_word_addr = irom_addr_plus4[13:2];
    assign irom_data = {irom_data_inst1, irom_data_inst0};

    IROM4MyOwn u_irom_inst0 (
        .clka  (w_cpu_clk),
        .addra (irom_word_addr),
        .douta (irom_data_inst0)
    );

    IROM4MyOwn u_irom_inst1 (
        .clka  (w_cpu_clk),
        .addra (irom_plus4_word_addr),
        .douta (irom_data_inst1)
    );

    // ================================================================
    //  DCache (2KB, 2-way, WT+WA, 16B line)
    // ================================================================
    dcache u_dcache (
        .clk         (w_cpu_clk),
        .rst_n       (~w_clk_rst),

        // CPU interface
        .cpu_req     (cache_req),
        .cpu_wr      (cache_wr),
        .cpu_addr    (cache_addr),
        .cpu_wea     (cache_wea),
        .cpu_wdata   (cache_wdata),
        .cpu_rdata   (cache_rdata),
        .cpu_ready   (cache_ready),

        // Pipeline synchronization
        .pipeline_stall (cache_pipeline_stall),

        // Flush
        .flush       (dcache_flush),

        // DRAM BRAM interface (SDP)
        .dram_rd_addr(dram_rd_addr),
        .dram_rdata  (dram_rdata),
        .dram_wr_addr(dram_wr_addr),
        .dram_wea    (dram_wea),
        .dram_wdata  (dram_wdata)
    );

    // ================================================================
    //  DRAM (Block Memory Generator RAM, SDP)
    //  配置: 32bit, 65536 depth (256KB), 4-bit WEA, 有 output register (DOB_REG=1, 2-cycle read latency)
    //  Port A = 写端口 (from DCache store buffer drain)
    //  Port B = 读端口 (from DCache refill FSM)
    // ================================================================
    DRAM4MyOwn u_dram (
        // 写端口 (Port A)
        .clka  (w_cpu_clk),
        .wea   (dram_wea),
        .addra (dram_wr_addr),
        .dina  (dram_wdata),

        // 读端口 (Port B)
        .clkb  (w_cpu_clk),
        .enb   (1'b1),
        .addrb (dram_rd_addr),
        .doutb (dram_rdata)
    );

    // ================================================================
    //  MMIO Bridge (LED/SEG/SW/KEY/CNT)
    // ================================================================
    mmio_bridge u_mmio (
        .clk     (w_cpu_clk),
        .cnt_clk (w_clk_50Mhz),
        .rst     (w_clk_rst),

        // CPU MMIO bus
        .addr     (mmio_addr),
        .wr_addr  (mmio_wr_addr),
        .wea      (mmio_wea),
        .wdata    (mmio_wdata),
        .rdata    (mmio_rdata),

        // 平台 I/O
        .sw      (virtual_sw),
        .key     (virtual_key),
        .led     (virtual_led),
        .seg     (virtual_seg)
    );

endmodule
