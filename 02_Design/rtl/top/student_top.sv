`timescale 1ns / 1ps

module student_top #(
    parameter P_SW_CNT  = 64,
    parameter P_LED_CNT = 32,
    parameter P_SEG_CNT = 40,
    parameter P_KEY_CNT = 8
) (
    input                       w_cpu_clk,
    input                       w_clk_50Mhz,
    input                       w_clk_rst,
    input  [P_KEY_CNT - 1:0]    virtual_key,
    input  [P_SW_CNT  - 1:0]    virtual_sw,

    output [P_LED_CNT - 1:0]    virtual_led,
    output [P_SEG_CNT - 1:0]    virtual_seg
);

    logic [31:0] pc;
    logic [11:0] inst_addr;
    logic [31:0] instruction;

    logic [31:0] perip_addr;
    logic [31:0] perip_wdata;
    logic [31:0] perip_rdata;
    logic        perip_wen;
    logic [1:0]  perip_mask;

    // Official shell IROM: retained to keep the contest template interface exact.
    assign inst_addr = pc[13:2];

    myCPU Core_cpu (
        .cpu_rst    (w_clk_rst),
        .cpu_clk    (w_cpu_clk),
        .irom_addr  (pc),
        .irom_data  (instruction),
        .perip_addr (perip_addr),
        .perip_wen  (perip_wen),
        .perip_mask (perip_mask),
        .perip_wdata(perip_wdata),
        .perip_rdata(perip_rdata)
    );

    IROM Mem_IROM (
        .a  (inst_addr),
        .spo(instruction)
    );

    perip_bridge bridge_inst (
        .clk               (w_cpu_clk),
        .cnt_clk           (w_clk_50Mhz),
        .rst               (w_clk_rst),
        .perip_addr        (perip_addr),
        .perip_wdata       (perip_wdata),
        .perip_wen         (perip_wen),
        .perip_mask        (perip_mask),
        .perip_rdata       (perip_rdata),
        .virtual_sw_input  (virtual_sw),
        .virtual_key_input (virtual_key),
        .virtual_seg_output(virtual_seg),
        .virtual_led_output(virtual_led)
    );

endmodule
