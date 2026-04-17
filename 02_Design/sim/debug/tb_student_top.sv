`timescale 1ns / 1ps
module tb_student_top;

    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    reg  [63:0] sw  = 64'h0;
    reg  [ 7:0] key = 8'h0;
    wire [31:0] led;
    wire [39:0] seg;

    student_top #(
        .P_SW_CNT  (64),
        .P_LED_CNT (32),
        .P_SEG_CNT (40),
        .P_KEY_CNT (8)
    ) u_dut (
        .w_cpu_clk    (clk),
        .w_clk_50Mhz  (clk),
        .w_clk_rst    (rst),
        .virtual_key  (key),
        .virtual_sw   (sw),
        .virtual_led  (led),
        .virtual_seg  (seg)
    );

    wire [31:0] tb_pc         = u_dut.u_cpu.pc;
    wire        tb_flush      = u_dut.u_cpu.branch_flush;
    wire [31:0] tb_flush_tgt  = u_dut.u_cpu.branch_target;
    wire        tb_ex_valid   = u_dut.u_cpu.ex_valid;
    wire        tb_ex_pred_tk = u_dut.u_cpu.ex_pred_taken;
    wire        tb_actual_tk  = u_dut.u_cpu.branch_actual_taken;

    initial begin
        rst = 1;
        #100;
        rst = 0;
        #2000000;    // 100000 cycles
        $display("===== TIMEOUT (100000 cycles) =====");
        $display("LED = %08h, SEG = %010h", led, seg);
        $finish;
    end

    integer cycle_cnt = 0;
    integer flush_cnt = 0;
    integer pred_ok_cnt = 0;
    integer wrong_tgt_cnt = 0;

    always @(posedge clk) begin
        if (!rst) begin
            cycle_cnt <= cycle_cnt + 1;

            if (tb_ex_valid && tb_ex_pred_tk && !tb_flush)
                pred_ok_cnt <= pred_ok_cnt + 1;

            if (tb_flush) begin
                flush_cnt <= flush_cnt + 1;
                if (tb_actual_tk && tb_ex_pred_tk)
                    wrong_tgt_cnt <= wrong_tgt_cnt + 1;
            end

            if (cycle_cnt > 0 && cycle_cnt % 10000 == 0)
                $display("[cyc=%0d] flushes=%0d pred_ok=%0d wrong_tgt=%0d LED=%08h SEG=%010h",
                         cycle_cnt, flush_cnt, pred_ok_cnt, wrong_tgt_cnt, led, seg);

            if (tb_pc < 32'h80000000 || tb_pc > 32'h80010000) begin
                $display("[cyc=%0d] *** PC OUT OF RANGE: %h ***", cycle_cnt, tb_pc);
                $display("LED=%08h SEG=%010h flushes=%0d", led, seg, flush_cnt);
                #100; $finish;
            end
        end
    end

    reg [31:0] prev_led = 0;
    always @(posedge clk) begin
        if (!rst && led != prev_led) begin
            $display("[cyc=%0d] LED: %08h → %08h", cycle_cnt, prev_led, led);
            prev_led <= led;
        end
    end

endmodule
