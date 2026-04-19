`timescale 1ns / 1ps
// ============================================================
// Module: perip_bridge
// Description: 自研外设桥，用于 JYD2025 数字孪生平台
//
// 时序模型 (A-C-B):
//   EX 阶段 (addr/wea/wdata 组合线有效)
//     → Edge (EX→MEM): BRAM 锁存 / MMIO 写入
//   MEM 阶段: BRAM Clk-to-Q + MMIO 组合读 → MUX → rdata
//     → Edge (MEM→WB): cpu_top 内 MEM/WB 寄存器捕获 rdata
//
// 依赖的模板模块 (不可修改):
//   - counter.sv (含 CDC gray 码同步)
//   - display_seg.sv + seg7.sv
//
// 依赖的 IP (需重新生成为 Block Memory Generator):
//   - DRAM: Single Port RAM, 32bit, 4-bit WEA, 无 output register
// ============================================================

module perip_bridge (
    input  logic         clk,
    input  logic         cnt_clk,         // 50MHz，counter CDC 用
    input  logic         rst,             // 高有效

    // CPU 接口
    //   Read path (EX stage): addr → DRAM 读端口 + is_dram 判断
    //   Write path (MEM stage, FIX-C): wr_addr/wea/wdata 已打拍
    input  logic [31:0]  addr,            // EX stage: 读地址 (= alu_addr)
    input  logic [31:0]  wr_addr,         // MEM stage: 写地址 (= mem_alu_result, 已打拍)
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
    localparam DRAM_ADDR_START = 32'h8010_0000;
    localparam DRAM_ADDR_END   = 32'h8014_0000;  // 不含，256KB
    localparam SW0_ADDR  = 32'h8020_0000;
    localparam SW1_ADDR  = 32'h8020_0004;
    localparam KEY_ADDR  = 32'h8020_0010;
    localparam SEG_ADDR  = 32'h8020_0020;
    localparam LED_ADDR  = 32'h8020_0040;
    localparam CNT_ADDR  = 32'h8020_0050;

    localparam CNT_START_CMD = 32'h8000_0000;
    localparam CNT_STOP_CMD  = 32'hFFFF_FFFF;

    // ================================================================
    //  地址译码
    // ================================================================

    // 读侧 is_dram：用 EX 级 addr（给 mem_is_dram 打拍，用于输出 MUX）
    wire is_dram = (addr[31:18] == 14'b1000_0000_0001_00);

    // 写侧 is_dram：用 MEM 级 wr_addr（已打拍，用于 DRAM 写端口和 MMIO 写）
    wire wr_is_dram = (wr_addr[31:18] == 14'b1000_0000_0001_00);

    // ================================================================
    //  地址打拍 (EX → MEM，给 MMIO 组合读和输出 MUX 用)
    // ================================================================
    logic [31:0] mem_addr;
    logic        mem_is_dram;

    always_ff @(posedge clk) begin
        mem_addr    <= addr;
        mem_is_dram <= is_dram;
    end

    // ================================================================
    //  DRAM: Simple Dual Port BRAM (FIX-C)
    //   Port A = 写端口 (MEM 级，已打拍，无组合路径)
    //   Port B = 读端口 (EX 级，保持原有 load 时序)
    //   IP 配置: Byte Write Enable, Byte Size=8, Width=32, Depth=65536
    // ================================================================
    logic [31:0] dram_douta;

    DRAM4MyOwn u_dram (
        // 写端口 (Port A, MEM stage)
        .clka  (clk),
        .wea   ({4{wr_is_dram}} & wea),    // MEM 级已打拍 WEA [3:0]
        .addra (wr_addr[17:2]),            // MEM 级已打拍地址
        .dina  (wdata),                    // MEM 级已打拍数据

        // 读端口 (Port B, EX stage)
        .clkb  (clk),
        .enb   (1'b1),                     // 读端口常使能
        .addrb (addr[17:2]),               // EX 级组合地址
        .doutb (dram_douta)                // MEM 级 Clk-to-Q 有效
    );

    // ================================================================
    //  MMIO 写 (MEM stage, FIX-C: 用已打拍信号)
    //  wr_addr/wea/wdata 均来自 EX/MEM 寄存器，无组合路径压力
    // ================================================================
    logic [31:0] led_reg;
    logic [31:0] seg_wdata;
    logic        cnt_enable_cfg;

    // ---- 并行译码（one-hot，组合逻辑，用 MEM 级信号）----
    wire mmio_wr = |wea & ~wr_is_dram;
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
    // wdata 命令解码：只需 2 bit 即可区分
    //   START = 0x8000_0000: wdata[31]=1, wdata[0]=0
    //   STOP  = 0xFFFF_FFFF: wdata[31]=1, wdata[0]=1
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
        .perip_rdata    (cnt_rdata)       // gray_to_bin 组合输出，~2.5ns
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
    //  与或式：每个地址匹配独立 AND，最终 OR 合并
    // ================================================================
    wire [31:0] mmio_rdata = ({32{mem_addr == SW0_ADDR}} & sw[31:0])
                           | ({32{mem_addr == SW1_ADDR}} & sw[63:32])
                           | ({32{mem_addr == KEY_ADDR}} & {24'd0, key})
                           | ({32{mem_addr == SEG_ADDR}} & seg_wdata)
                           | ({32{mem_addr == CNT_ADDR}} & cnt_rdata);

    // ================================================================
    //  输出 MUX (MEM 阶段，与或式)
    //  BRAM 路径 ~3.5ns, MMIO 路径 ~3.0ns, MUX ~0.3ns
    //  总计 ~3.8ns @ 4.5ns 周期 → 余量 ~0.7ns
    // ================================================================
    assign rdata = ({32{mem_is_dram}}  & dram_douta)
                 | ({32{~mem_is_dram}} & mmio_rdata);

    // ================================================================
    //  平台输出
    // ================================================================
    assign led = led_reg;
    assign seg = seg_output;

endmodule
