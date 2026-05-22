`timescale 1ns / 1ps

module mmio_bridge (
    input  logic         clk,
    input  logic         cnt_clk,
    input  logic         rst,

    input  logic [31:0]  addr,
    input  logic [31:0]  wr_addr,
    input  logic [3:0]   wea,
    input  logic [31:0]  wdata,
    output logic [31:0]  rdata,

    input  logic [63:0]  sw,
    input  logic [7:0]   key,
    output logic [31:0]  led,
    output logic [39:0]  seg
);

    localparam logic [31:0] SW0_ADDR = 32'h8020_0000;
    localparam logic [31:0] SW1_ADDR = 32'h8020_0004;
    localparam logic [31:0] KEY_ADDR = 32'h8020_0010;
    localparam logic [31:0] SEG_ADDR = 32'h8020_0020;
    localparam logic [31:0] LED_ADDR = 32'h8020_0040;
    localparam logic [31:0] CNT_ADDR = 32'h8020_0050;

    logic [31:0] mem_addr;
    logic [31:0] led_reg;
    logic [31:0] seg_wdata;
    logic        cnt_enable_cfg;
    logic [31:0] cnt_rdata;

    always_ff @(posedge clk) begin
        mem_addr <= addr;
    end

    wire mmio_wr = |wea;
    wire wr_seg  = mmio_wr && (wr_addr == SEG_ADDR);
    wire wr_led  = mmio_wr && (wr_addr == LED_ADDR);
    wire wr_cnt  = mmio_wr && (wr_addr == CNT_ADDR);

    always_ff @(posedge clk) begin
        if (rst)
            led_reg <= 32'd0;
        else if (wr_led)
            led_reg <= wdata;
    end

    always_ff @(posedge clk) begin
        if (rst)
            seg_wdata <= 32'd0;
        else if (wr_seg)
            seg_wdata <= wdata;
    end

    always_ff @(posedge clk) begin
        if (rst)
            cnt_enable_cfg <= 1'b0;
        else if (wr_cnt && wdata[31] && !wdata[0])
            cnt_enable_cfg <= 1'b1;
        else if (wr_cnt && wdata[31] && wdata[0])
            cnt_enable_cfg <= 1'b0;
    end

    counter u_counter (
        .cpu_clk        (clk),
        .cnt_clk        (cnt_clk),
        .rst            (rst),
        .cnt_enable_cpu (cnt_enable_cfg),
        .perip_rdata    (cnt_rdata)
    );

    assign rdata = ({32{mem_addr == SW0_ADDR}} & sw[31:0])
                 | ({32{mem_addr == SW1_ADDR}} & sw[63:32])
                 | ({32{mem_addr == KEY_ADDR}} & {24'd0, key})
                 | ({32{mem_addr == SEG_ADDR}} & seg_wdata)
                 | ({32{mem_addr == CNT_ADDR}} & cnt_rdata);

    assign led = led_reg;
    assign seg = {7'd0, cnt_enable_cfg, seg_wdata};

endmodule

