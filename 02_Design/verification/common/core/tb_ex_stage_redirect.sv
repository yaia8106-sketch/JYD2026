`timescale 1ns/1ps

module tb_ex_stage_redirect;
    import cpu_defs::*;

    logic [31:0] ex_pc, ex_s1_pc;
    logic ex_valid;
    logic ex_rs1_wb_repair, ex_rs2_wb_repair;
    logic [31:0] wb_load_data_ex_s0, wb_load_data_ex_s1;
    logic [31:0] ex_alu_src1, ex_alu_src2;
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
    logic ex_branch_request;
    logic ex_branch_actual_taken;
    logic ex_priv_redirect;
    logic ex_priv_flow;
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
    redirect_source_t ex_registered_redirect_source;
    logic ex_registered_redirect_actual_taken;

    redirect_t mem_redirect;
    ex_mem_slot0_t mem_s0_payload;
    ex_mem_slot1_t mem_s1_payload;
    logic [31:0] selected_redirect_target;

    ex_stage_ctrl dut (.*);

    always_comb begin
        mem_redirect = '0;
        mem_redirect.valid = ex_registered_branch_flush;
        mem_redirect.source = ex_registered_redirect_source;
        mem_redirect.actual_taken = ex_registered_redirect_actual_taken;

        mem_s0_payload = '0;
        mem_s0_payload.alu_result = alu_result;
        mem_s0_payload.pc = ex_pc;
        mem_s0_payload.pc_plus_4 = ex_pc_plus_4;
        mem_s0_payload.target_clear_mask = ex_target_clear_mask;
        mem_s0_payload.priv_target = ex_priv_target;

        mem_s1_payload = '0;
        mem_s1_payload.alu_result = ex_s1_branch_target;
        mem_s1_payload.pc = ex_s1_pc;
        mem_s1_payload.pc_plus_4 = ex_s1_pc_plus_4;
        mem_s1_payload.target_clear_mask = ex_s1_target_clear_mask;
    end

    redirect_target_select u_redirect_target_select (
        .redirect     (mem_redirect),
        .slot0_payload(mem_s0_payload),
        .slot1_payload(mem_s1_payload),
        .target       (selected_redirect_target)
    );

    task automatic expect_target(input logic [31:0] expected,
                                 input redirect_source_t expected_source,
                                 input string name);
        #1;
        if (!ex_registered_branch_flush
            || ex_registered_redirect_source !== expected_source
            || selected_redirect_target !== expected) begin
            $fatal(1, "%s: flush=%0b source=%0d target=%08x expected=%08x",
                   name, ex_registered_branch_flush,
                   ex_registered_redirect_source,
                   selected_redirect_target, expected);
        end
    endtask

    initial begin
        ex_pc = 32'h1c00_1000;
        ex_s1_pc = 32'h1c00_1004;
        ex_valid = 1'b1;
        ex_rs1_wb_repair = 1'b0;
        ex_rs2_wb_repair = 1'b0;
        wb_load_data_ex_s0 = 32'h5000_0000;
        wb_load_data_ex_s1 = 32'h6000_0000;
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
        ex_branch_request = 1'b0;
        ex_branch_actual_taken = 1'b0;
        ex_priv_redirect = 1'b0;
        ex_priv_flow = 1'b0;
        ex_priv_target = 32'h1c00_3000;

        // Each consumer slot uses its local repair copy. A conditional
        // branch's compare operands may be repaired, while its PC-relative
        // target must remain on the raw PC + immediate path.
        ex_rs1_wb_repair = 1'b1;
        ex_s1_rs2_wb_repair = 1'b1;
        ex_alu_src1 = 32'h1c00_1000;
        ex_alu_src2 = 32'h0000_0040;
        ex_alu_src1_wb_repair = 1'b1;
        ex_s1_alu_src1 = 32'h1c00_1004;
        ex_s1_alu_src2 = 32'h0000_0080;
        ex_s1_alu_src2_wb_repair = 1'b1;
        #1;
        if (ex_rs1_data_repair !== wb_load_data_ex_s0
            || ex_s1_rs2_data_repair !== wb_load_data_ex_s1)
            $fatal(1, "Consumer-local WB repair data selected incorrectly");
        if (ex_control_target !== 32'h1c00_1040
            || ex_s1_branch_target !== 32'h1c00_1084)
            $fatal(1, "WB repair leaked into a control target adder");

        ex_rs1_wb_repair = 1'b0;
        ex_s1_rs2_wb_repair = 1'b0;
        ex_alu_src1_wb_repair = 1'b0;
        ex_s1_alu_src2_wb_repair = 1'b0;
        ex_alu_src1 = 32'b0;
        ex_alu_src2 = 32'b0;
        ex_s1_alu_src1 = 32'b0;
        ex_s1_alu_src2 = 32'b0;

        // The Slot-1 branch comparator must consume its repaired operand in
        // the same EX cycle. Raw rs1 is deliberately unequal to rs2; only the
        // registered load repair makes this BEQ taken.
        ex_s1_control_flow = CF_CONDITIONAL;
        ex_s1_branch_op = BR_EQ;
        ex_s1_predicted_taken = 1'b0;
        ex_s1_rs1_data = 32'hBAD0_0001;
        ex_s1_rs2_data = wb_load_data_ex_s1;
        ex_s1_rs1_wb_repair = 1'b1;
        #1;
        if (!ex_s1_actual_taken || !ex_s1_branch_redirect)
            $fatal(1, "S1 conditional branch ignored WB load repair");

        ex_s1_control_flow = CF_NONE;
        ex_s1_branch_op = BR_NONE;
        ex_s1_predicted_taken = 1'b1;
        ex_s1_rs1_wb_repair = 1'b0;
        ex_s1_rs1_data = 32'b0;
        ex_s1_rs2_data = 32'b0;

        // A false-positive S1 BTB hit is repaired to the instruction after S1.
        expect_target(32'h1c00_1008, REDIRECT_S1_CONTROL,
                      "S1 false-positive BTB repair");
        if (!ex_s1_branch_redirect || ex_s1_actual_taken)
            $fatal(1, "S1 false-positive was not classified as a redirect");

        // A taken S1 repair selects its registered ALU target candidate.
        ex_s1_control_flow = CF_DIRECT;
        ex_s1_predicted_taken = 1'b0;
        ex_s1_alu_src1 = 32'h1c00_1800;
        ex_s1_alu_src2 = 32'h0000_0003;
        ex_s1_target_clear_mask = 2'b11;
        expect_target(32'h1c00_1800, REDIRECT_S1_CONTROL,
                      "S1 taken target and clear mask");

        // A faulting S1 LSU is replayed from S1 itself so the older S0 can
        // retire before the instruction re-enters as a precise S0 exception.
        ex_s1_control_flow = CF_NONE;
        ex_s1_target_clear_mask = 2'b00;
        ex_s1_predicted_taken = 1'b0;
        ex_s1_addr_replay = 1'b1;
        expect_target(32'h1c00_1004, REDIRECT_S1_REPLAY,
                      "S1 address-exception replay");

        // A false-positive S0 prediction repairs to the registered S0 PC+4.
        ex_s1_addr_replay = 1'b0;
        ex_branch_redirect = 1'b1;
        ex_branch_request = 1'b1;
        ex_branch_actual_taken = 1'b0;
        expect_target(32'h1c00_1004, REDIRECT_S0_CONTROL,
                      "S0 false-positive BTB repair");

        // The older S0 redirect wins if both slots request repair.
        ex_s1_addr_replay = 1'b1;
        ex_branch_actual_taken = 1'b1;
        ex_target_clear_mask = 2'b11;
        alu_result = 32'h1c00_2003;
        expect_target(32'h1c00_2000, REDIRECT_S0_CONTROL,
                      "S0 age priority");

        // A synchronous privilege redirect has highest priority.
        ex_priv_redirect = 1'b1;
        ex_priv_flow = 1'b1;
        expect_target(32'h1c00_3000, REDIRECT_PRIVILEGED,
                      "privilege priority");

        $display("[PASS] EX-stage redirect source selection");
        $finish;
    end
endmodule
