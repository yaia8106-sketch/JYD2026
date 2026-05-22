`timescale 1ns / 1ps

module board_top (
    input  logic        clk_100mhz,
    input  logic        cpu_resetn,

    input  logic [15:0] sw,
    input  logic        btnc,
    input  logic        btnu,
    input  logic        btnl,
    input  logic        btnr,
    input  logic        btnd,
    input  logic        uart_rx,

    output logic        uart_tx,
    output logic [15:0] led,
    output logic [6:0]  seg,
    output logic        dp,
    output logic [7:0]  an
);

    localparam logic [31:0] PASS_LED_PATTERN = 32'h2004_1808;
    localparam logic [31:0] FAIL_LED_PATTERN = 32'h2000_4824;
    localparam logic [31:0] SELFTEST_DISPLAY = 32'h1234_5678;
    localparam logic [15:0] SELFTEST_LED     = 16'h5a5a;
    localparam logic [15:0] BOOT_LED         = 16'h0001;
    localparam logic [15:0] RUNNING_LED      = 16'h0003;
    localparam logic [15:0] PASS_LED         = 16'h8000;
    localparam logic [15:0] FAIL_LED         = 16'h4000;

    logic clk_50mhz;
    logic clk_feedback;
    logic clk_feedback_buf;
    logic clk_50mhz_unbuf;
    logic mmcm_locked;

    wire board_reset = ~cpu_resetn;
    wire system_reset = board_reset | ~mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(10.000),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(10.000),
        .CLKFBOUT_PHASE(0.000),
        .CLKOUT0_DIVIDE_F(20.000),
        .CLKOUT0_PHASE(0.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(clk_100mhz),
        .CLKFBIN(clk_feedback_buf),
        .CLKFBOUT(clk_feedback),
        .CLKFBOUTB(),
        .CLKOUT0(clk_50mhz_unbuf),
        .CLKOUT0B(),
        .CLKOUT1(),
        .CLKOUT1B(),
        .CLKOUT2(),
        .CLKOUT2B(),
        .CLKOUT3(),
        .CLKOUT3B(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .LOCKED(mmcm_locked),
        .PWRDWN(1'b0),
        .RST(board_reset)
    );

    BUFG u_clkfb_bufg (
        .I(clk_feedback),
        .O(clk_feedback_buf)
    );

    BUFG u_clk50_bufg (
        .I(clk_50mhz_unbuf),
        .O(clk_50mhz)
    );

    logic [31:0] virtual_led;
    logic [39:0] virtual_seg;

    wire [63:0] virtual_sw = {48'd0, sw};
    wire [ 7:0] virtual_key = {3'd0, btnd, btnr, btnl, btnu, btnc};

    student_top u_student_top (
        .w_cpu_clk   (clk_50mhz),
        .w_clk_50Mhz (clk_50mhz),
        .w_clk_rst   (system_reset),
        .virtual_key (virtual_key),
        .virtual_sw  (virtual_sw),
        .virtual_led (virtual_led),
        .virtual_seg (virtual_seg)
    );

    seg8_hex_scan u_display (
        .clk   (clk_50mhz),
        .rst   (system_reset),
        .value (system_reset ? SELFTEST_DISPLAY : virtual_seg[31:0]),
        .seg   (seg),
        .dp    (dp),
        .an    (an)
    );

    wire pass = (virtual_led == PASS_LED_PATTERN);
    wire fail = (virtual_led == FAIL_LED_PATTERN);
    wire counter_running = virtual_seg[32];

    always_comb begin
        if (system_reset)
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

    assign uart_tx = 1'b1;
    wire unused_uart_rx = uart_rx;

endmodule

