`timescale 1ns / 1ps
// ============================================================
// Module: mmio_bridge (formerly perip_bridge)
// Description: MMIO-only bridge for JYD2025 数字孪生平台
//   DRAM has been moved to DCache module.
//   This module handles only LED/SEG/SW/KEY/CNT.
//
// 依赖的模板模块 (不可修改):
//   - counter.sv (含 CDC gray 码同步)
//   - display_seg.sv + seg7.sv
// ============================================================

module mmio_bridge (
    input  logic         clk,
    input  logic         cnt_clk,         // 50MHz，counter CDC 用
    input  logic         rst,             // 高有效

    // CPU 接口
    input  logic [31:0]  addr,            // EX stage: 读地址 (= alu_addr)
    input  logic [31:0]  wr_addr,         // MEM stage: 写地址 (已打拍)
    input  logic [3:0]   wea,             // MEM stage: 字节写使能（已打拍）
    input  logic [31:0]  wdata,           // MEM stage: 写数据（已打拍）
    output logic [31:0]  rdata,           // MEM stage: 读数据

    // 平台 I/O
    input  logic [63:0]  sw,              // 虚拟拨码开关
    input  logic [7:0]   key,             // 虚拟按键
    output logic [31:0]  led,             // LED 输出
    output logic [39:0]  seg              // 七段数码管输出
);

    // ================================================================
    //  地址映射
    // ================================================================
    localparam SW0_ADDR  = 32'h8020_0000;
    localparam SW1_ADDR  = 32'h8020_0004;
    localparam KEY_ADDR  = 32'h8020_0010;
    localparam SEG_ADDR  = 32'h8020_0020;
    localparam LED_ADDR  = 32'h8020_0040;
    localparam CNT_ADDR  = 32'h8020_0050;

    localparam CNT_START_CMD = 32'h8000_0000;
    localparam CNT_STOP_CMD  = 32'hFFFF_FFFF;

    // ================================================================
    //  地址打拍 (EX → MEM，给 MMIO 组合读用)
    // ================================================================
    logic [31:0] mem_addr;

    always_ff @(posedge clk) begin
        mem_addr <= addr;
    end

    // ================================================================
    //  MMIO 写 (MEM stage, 用已打拍信号)
    // ================================================================
    logic [31:0] led_reg;
    logic [31:0] seg_wdata;
    logic        cnt_enable_cfg;

    // 并行译码（one-hot，用 MEM 级信号）
    wire mmio_wr = |wea;
    wire wr_led  = mmio_wr & (wr_addr[6:4] == 3'b100);   // LED  0x8020_0040
    wire wr_seg  = mmio_wr & (wr_addr[6:4] == 3'b010);   // SEG  0x8020_0020
    wire wr_cnt  = mmio_wr & (wr_addr[6:4] == 3'b101);   // CNT  0x8020_0050

    // ---- LED 寄存器 ----
    always_ff @(posedge clk) begin
        if (rst)
            led_reg <= 32'd0;
        else if (wr_led)
            led_reg <= wdata;
    end

    // ---- SEG 寄存器 ----
    always_ff @(posedge clk) begin
        if (rst)
            seg_wdata <= 32'd0;
        else if (wr_seg)
            seg_wdata <= wdata;
    end

    // ---- CNT enable 寄存器 ----
    wire cnt_start = wr_cnt & wdata[31] & ~wdata[0];
    wire cnt_stop  = wr_cnt & wdata[31] &  wdata[0];

    always_ff @(posedge clk) begin
        if (rst)
            cnt_enable_cfg <= 1'b0;
        else if (cnt_start)
            cnt_enable_cfg <= 1'b1;
        else if (cnt_stop)
            cnt_enable_cfg <= 1'b0;
    end

    // ================================================================
    //  Counter (模板模块，禁止修改)
    // ================================================================
    logic [31:0] cnt_rdata;

    counter u_counter (
        .cpu_clk        (clk),
        .cnt_clk        (cnt_clk),
        .rst            (rst),
        .cnt_enable_cpu (cnt_enable_cfg),
        .perip_rdata    (cnt_rdata)
    );

    // ================================================================
    //  Display Segment (模板模块)
    // ================================================================
    logic [39:0] seg_output;

    display_seg u_display_seg (
        .clk  (clk),
        .rst  (rst),
        .s    (seg_wdata),
        .seg1 (seg_output[6:0]),
        .seg2 (seg_output[16:10]),
        .seg3 (seg_output[26:20]),
        .seg4 (seg_output[36:30]),
        .ans  ({seg_output[39:38], seg_output[29:28],
                seg_output[19:18], seg_output[9:8]})
    );

    assign seg_output[7]  = 1'b0;
    assign seg_output[17] = 1'b0;
    assign seg_output[27] = 1'b0;
    assign seg_output[37] = 1'b0;

    // ================================================================
    //  MMIO 读 (MEM 阶段，组合逻辑，用 mem_addr 译码)
    // ================================================================
    assign rdata = ({32{mem_addr == SW0_ADDR}} & sw[31:0])
                 | ({32{mem_addr == SW1_ADDR}} & sw[63:32])
                 | ({32{mem_addr == KEY_ADDR}} & {24'd0, key})
                 | ({32{mem_addr == SEG_ADDR}} & seg_wdata)
                 | ({32{mem_addr == CNT_ADDR}} & cnt_rdata);

    // ================================================================
    //  平台输出
    // ================================================================
    assign led = led_reg;
    assign seg = seg_output;

endmodule
