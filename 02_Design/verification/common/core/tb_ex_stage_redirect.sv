`timescale 1ns/1ps

module tb_ex_stage_redirect;
    import cpu_defs::*;

    logic [31:0] ex_pc, ex_s1_pc;
    logic ex_valid;
    logic ex_rs1_wb_repair, ex_rs2_wb_repair;
    logic [31:0] wb_load_data, ex_alu_src1, ex_alu_src2;
    logic ex_alu_src1_wb_repair, ex_alu_src2_wb_repair;
    logic [31:0] ex_rs1_data, ex_rs2_data;
    control_flow_t ex_control_flow;
    logic [1:0] ex_target_clear_mask;
    logic ex_is_priv_reg;
    logic [31:0] ex_priv_rdata;
    logic ex_is_muldiv;
    logic [31:0] ex_muldiv_result, alu_result;
    logic ex_s1_valid;
    control_flow_t ex_s1_control_flow;
    branch_op_t ex_s1_branch_op;
    logic [1:0] ex_s1_target_clear_mask;
    logic ex_s1_rs1_wb_repair, ex_s1_rs2_wb_repair;
    logic [31:0] ex_s1_alu_src1, ex_s1_alu_src2;
    logic ex_s1_alu_src1_wb_repair, ex_s1_alu_src2_wb_repair;
    logic [31:0] ex_s1_rs1_data, ex_s1_rs2_data;
    logic ex_s1_predicted_taken;
    logic [31:0] ex_s1_predicted_target;
    logic ex_s1_addr_replay;
    logic mem_branch_flush, ex_ready_go, mem_allowin;
    logic ex_branch_redirect;
    logic [31:0] branch_target;
    logic ex_priv_redirect;
    logic [31:0] ex_priv_target;

    logic [31:0] ex_pc_plus_4, ex_s1_pc_plus_4;
    logic [31:0] ex_alu_src1_repair, ex_alu_src2_repair;
    logic [31:0] ex_s1_alu_src1_repair, ex_s1_alu_src2_repair;
    logic [31:0] ex_rs1_data_repair, ex_rs2_data_repair;
    logic [31:0] ex_s1_rs1_data_repair, ex_s1_rs2_data_repair;
    logic [31:0] ex_forward_result, ex_pipe_alu_result;
    logic [31:0] ex_control_target, ex_s1_branch_target;
    logic ex_s1_actual_taken, ex_s1_branch_redirect;
    logic ex_registered_branch_flush;
    logic [31:0] ex_registered_branch_target;

    ex_stage_ctrl dut (.*);

    task automatic expect_target(input logic [31:0] expected,
                                 input string name);
        #1;
        if (!ex_registered_branch_flush
            || ex_registered_branch_target !== expected) begin
            $fatal(1, "%s: flush=%0b target=%08x expected=%08x",
                   name, ex_registered_branch_flush,
                   ex_registered_branch_target, expected);
        end
    endtask

    initial begin
        ex_pc = 32'h1c00_1000;
        ex_s1_pc = 32'h1c00_1004;
        ex_valid = 1'b1;
        ex_rs1_wb_repair = 1'b0;
        ex_rs2_wb_repair = 1'b0;
        wb_load_data = 32'b0;
        ex_alu_src1 = 32'b0;
        ex_alu_src2 = 32'b0;
        ex_alu_src1_wb_repair = 1'b0;
        ex_alu_src2_wb_repair = 1'b0;
        ex_rs1_data = 32'b0;
        ex_rs2_data = 32'b0;
        ex_control_flow = CF_NONE;
        ex_target_clear_mask = 2'b0;
        ex_is_priv_reg = 1'b0;
        ex_priv_rdata = 32'b0;
        ex_is_muldiv = 1'b0;
        ex_muldiv_result = 32'b0;
        alu_result = 32'b0;
        ex_s1_valid = 1'b1;
        ex_s1_control_flow = CF_NONE;
        ex_s1_branch_op = BR_NONE;
        ex_s1_target_clear_mask = 2'b0;
        ex_s1_rs1_wb_repair = 1'b0;
        ex_s1_rs2_wb_repair = 1'b0;
        ex_s1_alu_src1 = 32'b0;
        ex_s1_alu_src2 = 32'b0;
        ex_s1_alu_src1_wb_repair = 1'b0;
        ex_s1_alu_src2_wb_repair = 1'b0;
        ex_s1_rs1_data = 32'b0;
        ex_s1_rs2_data = 32'b0;
        ex_s1_predicted_taken = 1'b1;
        ex_s1_predicted_target = 32'h1c01_0000;
        ex_s1_addr_replay = 1'b0;
        mem_branch_flush = 1'b0;
        ex_ready_go = 1'b1;
        mem_allowin = 1'b1;
        ex_branch_redirect = 1'b0;
        branch_target = 32'h1c00_1004;
        ex_priv_redirect = 1'b0;
        ex_priv_target = 32'h1c00_3000;

        // A false-positive S1 BTB hit is repaired to the instruction after S1.
        expect_target(32'h1c00_1008, "S1 false-positive BTB repair");
        if (!ex_s1_branch_redirect || ex_s1_actual_taken)
            $fatal(1, "S1 false-positive was not classified as a redirect");

        // A faulting S1 LSU is replayed from S1 itself so the older S0 can
        // retire before the instruction re-enters as a precise S0 exception.
        ex_s1_predicted_taken = 1'b0;
        ex_s1_addr_replay = 1'b1;
        expect_target(32'h1c00_1004, "S1 address-exception replay");

        // The older S0 redirect wins if both slots request repair.
        ex_branch_redirect = 1'b1;
        branch_target = 32'h1c00_2000;
        expect_target(32'h1c00_2000, "S0 age priority");

        // A synchronous privilege redirect has highest priority.
        ex_priv_redirect = 1'b1;
        expect_target(32'h1c00_3000, "privilege priority");

        $display("[PASS] EX-stage redirect source selection");
        $finish;
    end
endmodule
