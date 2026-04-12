`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_student_top
// Description: 验证 student_top 前 100 拍的行为
//              输出 PC, 指令, ALU 结果, DRAM 读写 到控制台
// 用法: Vivado → Add Simulation Source → Run Behavioral Simulation
// ============================================================

module tb_student_top;

    // ---- 时钟与复位 ----
    reg clk = 0;
    reg rst = 1;

    always #10 clk = ~clk;   // 50MHz (20ns period)

    // ---- I/O ----
    reg  [63:0] sw  = 64'h0;
    reg  [ 7:0] key = 8'h0;
    wire [31:0] led;
    wire [39:0] seg;

    // ---- DUT ----
    student_top #(
        .P_SW_CNT  (64),
        .P_LED_CNT (32),
        .P_SEG_CNT (40),
        .P_KEY_CNT (8)
    ) u_dut (
        .w_cpu_clk    (clk),
        .w_clk_50Mhz  (clk),       // 同时钟域测试
        .w_clk_rst    (rst),        // 高有效复位
        .virtual_key  (key),
        .virtual_sw   (sw),
        .virtual_led  (led),
        .virtual_seg  (seg)
    );

    // ---- 层次化引用内部信号 ----
    // CPU 核心
    wire [31:0] tb_pc         = u_dut.u_cpu.pc;
    wire [31:0] tb_next_pc    = u_dut.u_cpu.next_pc;
    wire [31:0] tb_irom_data  = u_dut.u_cpu.id_inst;   // registered instruction in ID
    wire [31:0] tb_alu_result = u_dut.u_cpu.alu_result;
    wire [31:0] tb_id_pc      = u_dut.u_cpu.id_pc;
    wire        tb_id_valid   = u_dut.u_cpu.id_valid;
    wire        tb_ex_valid   = u_dut.u_cpu.ex_valid;
    wire        tb_mem_valid  = u_dut.u_cpu.mem_valid;
    wire        tb_wb_valid   = u_dut.u_cpu.wb_valid;

    // 流水线控制
    wire        tb_branch_flush  = u_dut.u_cpu.branch_flush;
    wire [31:0] tb_branch_target = u_dut.u_cpu.branch_target;
    wire        tb_id_ready_go   = u_dut.u_cpu.id_ready_go;

    // 外设总线
    wire [31:0] tb_perip_addr  = u_dut.u_cpu.perip_addr;
    wire [ 3:0] tb_perip_wea   = u_dut.u_cpu.perip_wea;
    wire [31:0] tb_perip_wdata = u_dut.u_cpu.perip_wdata;
    wire [31:0] tb_perip_rdata = u_dut.u_cpu.perip_rdata;

    // WB 阶段
    wire [ 4:0] tb_wb_rd         = u_dut.u_cpu.wb_rd;
    wire        tb_wb_reg_write  = u_dut.u_cpu.wb_reg_write_en;
    wire [31:0] tb_wb_write_data = u_dut.u_cpu.wb_write_data;
    wire [31:0] tb_wb_dram_dout  = u_dut.u_cpu.wb_dram_dout;

    // Forwarding
    wire [31:0] tb_fwd_rs1 = u_dut.u_cpu.fwd_rs1_data;
    wire [31:0] tb_fwd_rs2 = u_dut.u_cpu.fwd_rs2_data;

    // ---- 复位序列 ----
    initial begin
        rst = 1;
        #100;
        rst = 0;
        #10000;        // 跑 500 拍 (500 × 20ns)
        $display("===== SIMULATION TIMEOUT =====");
        $finish;
    end

    // ---- 每拍打印 ----
    integer cycle_cnt = 0;

    always @(posedge clk) begin
        if (!rst) begin
            cycle_cnt <= cycle_cnt + 1;

            // 表头（只打一次）
            if (cycle_cnt == 0) begin
                $display("=== tb_student_top: simulation start ===");
                $display("CYC | PC       | inst     | id_pc    | id_v | ex_v | mem_v | wb_v | alu_res  | p_addr   | p_wea | p_rdata  | wb_rd | wb_wen | wb_data  | flush | stall");
                $display("----+----------+----------+----------+------+------+-------+------+----------+----------+-------+----------+-------+--------+----------+-------+------");
            end

            $display("%3d | %08h | %08h | %08h |  %b   |  %b   |   %b   |  %b   | %08h | %08h |  %h   | %08h |  x%-2d |   %b    | %08h |   %b   |  %b",
                cycle_cnt,
                tb_pc,
                tb_irom_data,
                tb_id_pc,
                tb_id_valid,
                tb_ex_valid,
                tb_mem_valid,
                tb_wb_valid,
                tb_alu_result,
                tb_perip_addr,
                tb_perip_wea,
                tb_perip_rdata,
                tb_wb_rd,
                tb_wb_reg_write,
                tb_wb_write_data,
                tb_branch_flush,
                ~tb_id_ready_go
            );

            // 标记关键事件
            if (tb_branch_flush)
                $display("  >>> BRANCH FLUSH to %08h", tb_branch_target);
            if (~tb_id_ready_go && tb_id_valid)
                $display("  >>> LOAD-USE STALL");
            if (tb_wb_valid && tb_wb_reg_write && tb_wb_rd != 0)
                $display("  >>> WB: x%0d <= %08h", tb_wb_rd, tb_wb_write_data);

            // 前 100 拍后自动停止（可调整）
            if (cycle_cnt >= 500) begin
                $display("===== 100 cycles reached =====");
                $finish;
            end
        end
    end

endmodule
