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
    localparam logic [23:0] SELFTEST_DISPLAY = 24'h123456;
    localparam logic [7:0]  SELFTEST_LED     = 8'b0101_1010;
    localparam logic [7:0]  BOOT_LED         = 8'b0000_0001;
    localparam logic [7:0]  RUNNING_LED      = 8'b0000_0011;
    localparam logic [7:0]  PASS_LED         = 8'b1000_0000;
    localparam logic [7:0]  FAIL_LED         = 8'b0100_0000;

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
        .value (rst_sw ? SELFTEST_DISPLAY : virtual_seg[23:0]),
        .seg   (seg),
        .dp    (dp),
        .an    (an)
    );

    wire pass = (virtual_led == PASS_LED_PATTERN);
    wire fail = (virtual_led == FAIL_LED_PATTERN);
    wire counter_running = virtual_seg[32];

    always_comb begin
        if (rst_sw)
            led = SELFTEST_LED;
        else if (pass)
            led = PASS_LED;
        else if (fail)
            led = FAIL_LED;
        else if (counter_running)
            led = RUNNING_LED;
        else
            led = BOOT_LED;
    end

endmodule
