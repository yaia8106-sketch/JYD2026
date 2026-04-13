`timescale 1ns / 1ps
// ============================================================
// Module: perip_bridge
// Description: 自研外设桥，用于 JYD2025 数字孪生平台
//
// ⚠ [UNVERIFIED] 2026-04-13 MMIO 写时序改动尚未通过功能验证
//    改动内容：MMIO 写从 EX→MEM 沿推迟到 MEM→WB 沿
//    目的：消除 ALU→MMIO 写的 15 级 LUT 关键路径
//    待验证：riscv-tests ISA 合规测试 + MMIO 读写功能
//
// 时序模型:
//   EX 阶段 (addr/wea/wdata 组合线有效)
//     → Edge (EX→MEM): BRAM 锁存写入 / EX→MEM 打拍
//   MEM 阶段: BRAM Clk-to-Q + MMIO 组合读 → MUX → rdata
//     → Edge (MEM→WB): MMIO 寄存器写入（用 mem_* 信号）
//                       cpu_top 内 MEM/WB 寄存器捕获 rdata
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

    // CPU 接口 (EX 阶段信号)
    input  logic [31:0]  addr,            // = alu_result（EX 组合）
    input  logic [3:0]   wea,             // 字节写使能（EX 组合）
    input  logic [31:0]  wdata,           // 写数据（EX 组合，已移位）
    output logic [31:0]  rdata,           // 读数据（MEM 阶段有效）

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
    //  地址译码 (EX 阶段，组合)
    // ================================================================
    wire is_dram = (addr[31:18] == 14'b1000_0000_0001_00);  // 0x8010_0000 ~ 0x8013_FFFF

    // ================================================================
    //  EX → MEM 打拍（给 MMIO 读/写 和输出 MUX 用）
    // ================================================================
    logic [31:0] mem_addr;
    logic        mem_is_dram;
    logic [3:0]  mem_wea;
    logic [31:0] mem_wdata;

    always_ff @(posedge clk) begin
        mem_addr    <= addr;
        mem_is_dram <= is_dram;
        mem_wea     <= wea;
        mem_wdata   <= wdata;
    end

    // ================================================================
    //  DRAM: BRAM (无 output register, 1 拍读延迟)
    // ================================================================
    //  IP: Block Memory Generator, Single Port RAM
    //  配置: 32bit, 65536 depth (可调), 4-bit Byte Write Enable
    //  无 output register, 无 enable port
    // ================================================================
    logic [31:0] dram_douta;

    DRAM4MyOwn u_dram (
        .clka  (clk),
        .addra (addr[17:2]),             // word 地址，EX 阶段直连
        .wea   ({4{is_dram}} & wea),     // DRAM 范围外禁止写
        .dina  (wdata),
        .douta (dram_douta)              // MEM 阶段 Clk-to-Q 有效
    );

    // ================================================================
    //  MMIO 写 (MEM→WB 时钟沿采样，使用打拍后的 mem_* 信号)
    //  目的：将 MMIO 写从 EX 组合路径移出，消除 ALU 依赖
    //  安全性：MMIO 读为组合逻辑 (wire)，write-first 行为保证
    //          同周期 Store+Load 到同地址可读到新值
    // ================================================================
    logic [31:0] led_reg;
    logic [31:0] seg_wdata;
    logic        cnt_enable_cfg;

    always_ff @(posedge clk) begin
        if (rst) begin
            led_reg        <= 32'd0;
            seg_wdata      <= 32'd0;
            cnt_enable_cfg <= 1'b0;
        end else if (|mem_wea && !mem_is_dram) begin
            case (mem_addr)
                LED_ADDR: led_reg <= mem_wdata;
                SEG_ADDR: seg_wdata <= mem_wdata;
                CNT_ADDR: begin
                    if (mem_wdata == CNT_START_CMD)
                        cnt_enable_cfg <= 1'b1;
                    else if (mem_wdata == CNT_STOP_CMD)
                        cnt_enable_cfg <= 1'b0;
                end
                default: ;
            endcase
        end
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
