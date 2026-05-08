`timescale 1ns / 1ps

module board_top (
    input  logic       clk_50mhz,
    input  logic       rst_sw,

    output logic [7:0] led,
    output logic [6:0] seg,
    output logic       dp,
    output logic [5:0] an
);

    localparam logic [31:0] PASS_LED_PATTERN = 32'h2004_1808;
    localparam logic [31:0] FAIL_LED_PATTERN = 32'h2000_4824;

    logic [31:0] virtual_led;
    logic [39:0] virtual_seg;

    wire [63:0] virtual_sw  = 64'd0;
    wire [ 7:0] virtual_key = 8'd0;

    student_top u_student_top (
        .w_cpu_clk   (clk_50mhz),
        .w_clk_50Mhz (clk_50mhz),
        .w_clk_rst   (rst_sw),
        .virtual_key (virtual_key),
        .virtual_sw  (virtual_sw),
        .virtual_led (virtual_led),
        .virtual_seg (virtual_seg)
    );

    seg6_hex_scan u_display (
        .clk   (clk_50mhz),
        .rst   (rst_sw),
        .value (rst_sw ? 24'h123456 : virtual_seg[23:0]),
        .seg   (seg),
        .dp    (dp),
        .an    (an)
    );

    wire pass = (virtual_led == PASS_LED_PATTERN);
    wire fail = (virtual_led == FAIL_LED_PATTERN);

    wire [3:0] pass_tens = virtual_seg[31:28];
    wire [3:0] pass_ones = virtual_seg[27:24];
    wire [7:0] pass_count = {1'b0, pass_tens, 3'b000}
                          + {3'b000, pass_tens, 1'b0}
                          + {4'b0000, pass_ones};

    assign led = {pass, fail, pass_count[5:0]};

endmodule
