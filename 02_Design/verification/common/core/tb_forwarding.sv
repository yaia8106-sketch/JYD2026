`timescale 1ns/1ps

module tb_forwarding;
    logic [ 4:0] id_rs1_addr;
    logic [ 4:0] id_rs2_addr;
    logic        id_rs1_used;
    logic        id_rs2_used;
    logic        id_s0_alu_only;
    logic        id_s0_indirect_control;
    logic        id_s0_conditional_control;
    logic        id_s0_mem_read;
    logic        id_s0_mem_write;
    logic        id_s0_is_mul;
    logic [31:0] id_s0_pc;
    logic [31:0] id_s0_imm;
    logic [ 1:0] id_s0_alu_src1_sel;
    logic        id_s0_alu_src2_sel;
    logic [31:0] rf_rs1_data;
    logic [31:0] rf_rs2_data;

    logic        id_s1_valid;
    logic [ 4:0] id_s1_rs1_addr;
    logic [ 4:0] id_s1_rs2_addr;
    logic        id_s1_rs1_used;
    logic        id_s1_rs2_used;
    logic        id_s1_repair_ok;
    logic [31:0] id_s1_pc;
    logic [31:0] id_s1_imm;
    logic [ 1:0] id_s1_alu_src1_sel;
    logic        id_s1_alu_src2_sel;
    logic [31:0] rf_s1_rs1_data;
    logic [31:0] rf_s1_rs2_data;

    logic        ex_valid;
    logic        ex_reg_write;
    logic        ex_is_muldiv;
    logic        ex_mem_read;
    logic [ 4:0] ex_rd;
    logic [31:0] ex_alu_result;
    logic [31:0] ex_pc_plus_4;
    logic [ 1:0] ex_wb_sel;
    wire         ex_fast_alu = ~ex_is_muldiv & (ex_wb_sel != 2'b10);

    logic        ex_s1_valid;
    logic        ex_s1_reg_write;
    logic        ex_s1_mem_read;
    logic [ 4:0] ex_s1_rd;
    logic [31:0] ex_s1_alu_result;
    logic [31:0] ex_s1_pc_plus_4;
    logic [ 1:0] ex_s1_wb_sel;

    logic        mem_valid;
    logic        mem_reg_write;
    logic        mem_is_load;
    logic        mem_is_mul;
    logic [ 4:0] mem_rd;
    logic [31:0] mem_alu_result;
    logic [31:0] mem_mul_result;
    logic [31:0] mem_pc_plus_4;
    logic        mem_load_ready;
    logic [ 1:0] mem_wb_sel;

    logic        mem_s1_valid;
    logic        mem_s1_reg_write;
    logic        mem_s1_is_load;
    logic [ 4:0] mem_s1_rd;
    logic [31:0] mem_s1_alu_result;
    logic [31:0] mem_s1_pc_plus_4;
    logic [ 1:0] mem_s1_wb_sel;

    logic        wb_valid;
    logic        wb_reg_write;
    logic [ 4:0] wb_rd;
    logic [31:0] wb_write_data;

    logic        wb_s1_valid;
    logic        wb_s1_reg_write;
    logic [ 4:0] wb_s1_rd;
    logic [31:0] wb_s1_write_data;

    logic [31:0] id_rs1_data;
    logic [31:0] id_rs2_data;
    logic [31:0] id_s1_rs1_data;
    logic [31:0] id_s1_rs2_data;
    logic [31:0] id_s0_alu_src1;
    logic [31:0] id_s0_alu_src2;
    logic [31:0] id_s1_alu_src1;
    logic [31:0] id_s1_alu_src2;
    logic [31:0] mul_rs1_data;
    logic [31:0] mul_rs2_data;
    logic        id_rs1_wb_repair;
    logic        id_rs2_wb_repair;
    logic        id_s1_rs1_wb_repair;
    logic        id_s1_rs2_wb_repair;
    logic        id_rs1_wb_repair_s1;
    logic        id_rs2_wb_repair_s1;
    logic        id_s1_rs1_wb_repair_s1;
    logic        id_s1_rs2_wb_repair_s1;
    logic        id_ready_go;

    forwarding dut (
        .id_rs1_addr      (id_rs1_addr),
        .id_rs2_addr      (id_rs2_addr),
        .id_rs1_used      (id_rs1_used),
        .id_rs2_used      (id_rs2_used),
        .id_s0_alu_only   (id_s0_alu_only),
        .id_s0_indirect_control(id_s0_indirect_control),
        .id_s0_conditional_control(id_s0_conditional_control),
        .id_s0_mem_read   (id_s0_mem_read),
        .id_s0_mem_write  (id_s0_mem_write),
        .id_s0_is_mul     (id_s0_is_mul),
        .id_s0_pc         (id_s0_pc),
        .id_s0_imm        (id_s0_imm),
        .id_s0_alu_src1_sel(id_s0_alu_src1_sel),
        .id_s0_alu_src2_sel(id_s0_alu_src2_sel),
        .rf_rs1_data      (rf_rs1_data),
        .rf_rs2_data      (rf_rs2_data),
        .id_s1_valid      (id_s1_valid),
        .id_s1_rs1_addr   (id_s1_rs1_addr),
        .id_s1_rs2_addr   (id_s1_rs2_addr),
        .id_s1_rs1_used   (id_s1_rs1_used),
        .id_s1_rs2_used   (id_s1_rs2_used),
        .id_s1_repair_ok  (id_s1_repair_ok),
        .id_s1_pc         (id_s1_pc),
        .id_s1_imm        (id_s1_imm),
        .id_s1_alu_src1_sel(id_s1_alu_src1_sel),
        .id_s1_alu_src2_sel(id_s1_alu_src2_sel),
        .rf_s1_rs1_data   (rf_s1_rs1_data),
        .rf_s1_rs2_data   (rf_s1_rs2_data),
        .ex_valid         (ex_valid),
        .ex_reg_write     (ex_reg_write),
        .ex_is_muldiv     (ex_is_muldiv),
        .ex_mem_read      (ex_mem_read),
        .ex_result_repair (1'b0),
        .ex_rd            (ex_rd),
        .ex_alu_result    (ex_alu_result),
        .ex_fast_alu      (ex_fast_alu),
        .ex_fast_alu_result(ex_alu_result),
        .ex_pc_plus_4     (ex_pc_plus_4),
        .ex_wb_sel        (ex_wb_sel),
        .ex_s1_valid      (ex_s1_valid),
        .ex_s1_reg_write  (ex_s1_reg_write),
        .ex_s1_mem_read   (ex_s1_mem_read),
        .ex_s1_result_repair(1'b0),
        .ex_s1_rd         (ex_s1_rd),
        .ex_s1_alu_result (ex_s1_alu_result),
        .ex_s1_pc_plus_4  (ex_s1_pc_plus_4),
        .ex_s1_wb_sel     (ex_s1_wb_sel),
        .mem_valid        (mem_valid),
        .mem_reg_write    (mem_reg_write),
        .mem_is_load      (mem_is_load),
        .mem_is_mul       (mem_is_mul),
        .mem_rd           (mem_rd),
        .mem_alu_result   (mem_alu_result),
        .mem_mul_result   (mem_mul_result),
        .mem_pc_plus_4    (mem_pc_plus_4),
        .mem_load_ready   (mem_load_ready),
        .mem_wb_sel       (mem_wb_sel),
        .mem_s1_valid     (mem_s1_valid),
        .mem_s1_reg_write (mem_s1_reg_write),
        .mem_s1_is_load   (mem_s1_is_load),
        .mem_s1_rd        (mem_s1_rd),
        .mem_s1_alu_result(mem_s1_alu_result),
        .mem_s1_pc_plus_4 (mem_s1_pc_plus_4),
        .mem_s1_wb_sel    (mem_s1_wb_sel),
        .wb_valid         (wb_valid),
        .wb_reg_write     (wb_reg_write),
        .wb_rd            (wb_rd),
        .wb_write_data    (wb_write_data),
        .wb_s1_valid      (wb_s1_valid),
        .wb_s1_reg_write  (wb_s1_reg_write),
        .wb_s1_rd         (wb_s1_rd),
        .wb_s1_write_data (wb_s1_write_data),
        .id_rs1_data      (id_rs1_data),
        .id_rs2_data      (id_rs2_data),
        .id_s1_rs1_data   (id_s1_rs1_data),
        .id_s1_rs2_data   (id_s1_rs2_data),
        .id_s0_alu_src1   (id_s0_alu_src1),
        .id_s0_alu_src2   (id_s0_alu_src2),
        .id_s1_alu_src1   (id_s1_alu_src1),
        .id_s1_alu_src2   (id_s1_alu_src2),
        .id_rs1_wb_repair (id_rs1_wb_repair),
        .id_rs2_wb_repair (id_rs2_wb_repair),
        .id_rs1_wb_repair_s1(id_rs1_wb_repair_s1),
        .id_rs2_wb_repair_s1(id_rs2_wb_repair_s1),
        .id_s1_rs1_wb_repair(id_s1_rs1_wb_repair),
        .id_s1_rs2_wb_repair(id_s1_rs2_wb_repair),
        .id_s1_rs1_wb_repair_s1(id_s1_rs1_wb_repair_s1),
        .id_s1_rs2_wb_repair_s1(id_s1_rs2_wb_repair_s1),
        .id_ready_go      (id_ready_go)
    );

    mul_operand_forwarding mul_dut (
        .id_rs1_addr       (id_rs1_addr),
        .id_rs2_addr       (id_rs2_addr),
        .rf_rs1_data       (rf_rs1_data),
        .rf_rs2_data       (rf_rs2_data),
        .mem_valid         (mem_valid),
        .mem_reg_write     (mem_reg_write),
        .mem_is_load       (mem_is_load),
        .mem_is_mul        (mem_is_mul),
        .mem_rd            (mem_rd),
        .mem_alu_result    (mem_alu_result),
        .mem_mul_result    (mem_mul_result),
        .mem_pc_plus_4     (mem_pc_plus_4),
        .mem_wb_sel        (mem_wb_sel),
        .mem_s1_valid      (mem_s1_valid),
        .mem_s1_reg_write  (mem_s1_reg_write),
        .mem_s1_is_load    (mem_s1_is_load),
        .mem_s1_rd         (mem_s1_rd),
        .mem_s1_alu_result (mem_s1_alu_result),
        .mem_s1_pc_plus_4  (mem_s1_pc_plus_4),
        .mem_s1_wb_sel     (mem_s1_wb_sel),
        .wb_valid          (wb_valid),
        .wb_reg_write      (wb_reg_write),
        .wb_rd             (wb_rd),
        .wb_write_data     (wb_write_data),
        .wb_s1_valid       (wb_s1_valid),
        .wb_s1_reg_write   (wb_s1_reg_write),
        .wb_s1_rd          (wb_s1_rd),
        .wb_s1_write_data  (wb_s1_write_data),
        .mul_rs1_data      (mul_rs1_data),
        .mul_rs2_data      (mul_rs2_data)
    );

    task automatic clear_inputs;
        begin
            id_rs1_addr = 5'd0;
            id_rs2_addr = 5'd0;
            id_rs1_used = 1'b0;
            id_rs2_used = 1'b0;
            id_s0_alu_only = 1'b0;
            id_s0_indirect_control = 1'b0;
            id_s0_conditional_control = 1'b0;
            id_s0_mem_read = 1'b0;
            id_s0_mem_write = 1'b0;
            id_s0_is_mul = 1'b0;
            id_s0_pc = 32'h1000_0000;
            id_s0_imm = 32'h0000_0010;
            id_s0_alu_src1_sel = 2'b00;
            id_s0_alu_src2_sel = 1'b0;
            rf_rs1_data = 32'h1111_0001;
            rf_rs2_data = 32'h2222_0002;

            id_s1_valid = 1'b0;
            id_s1_rs1_addr = 5'd0;
            id_s1_rs2_addr = 5'd0;
            id_s1_rs1_used = 1'b0;
            id_s1_rs2_used = 1'b0;
            id_s1_repair_ok = 1'b1;
            id_s1_pc = 32'h1000_0004;
            id_s1_imm = 32'h0000_0020;
            id_s1_alu_src1_sel = 2'b00;
            id_s1_alu_src2_sel = 1'b0;
            rf_s1_rs1_data = 32'h3333_0003;
            rf_s1_rs2_data = 32'h4444_0004;

            ex_valid = 1'b0;
            ex_reg_write = 1'b0;
            ex_is_muldiv = 1'b0;
            ex_mem_read = 1'b0;
            ex_rd = 5'd0;
            ex_alu_result = 32'hAAAA_0000;
            ex_pc_plus_4 = 32'hAAAA_0004;
            ex_wb_sel = 2'b00;

            ex_s1_valid = 1'b0;
            ex_s1_reg_write = 1'b0;
            ex_s1_mem_read = 1'b0;
            ex_s1_rd = 5'd0;
            ex_s1_alu_result = 32'hBBBB_0000;
            ex_s1_pc_plus_4 = 32'hBBBB_0004;
            ex_s1_wb_sel = 2'b00;

            mem_valid = 1'b0;
            mem_reg_write = 1'b0;
            mem_is_load = 1'b0;
            mem_is_mul = 1'b0;
            mem_rd = 5'd0;
            mem_alu_result = 32'hCCCC_0000;
            mem_mul_result = 32'hC0DE_0000;
            mem_pc_plus_4 = 32'hCCCC_0004;
            mem_load_ready = 1'b0;
            mem_wb_sel = 2'b00;

            mem_s1_valid = 1'b0;
            mem_s1_reg_write = 1'b0;
            mem_s1_is_load = 1'b0;
            mem_s1_rd = 5'd0;
            mem_s1_alu_result = 32'hDDDD_0000;
            mem_s1_pc_plus_4 = 32'hDDDD_0004;
            mem_s1_wb_sel = 2'b00;

            wb_valid = 1'b0;
            wb_reg_write = 1'b0;
            wb_rd = 5'd0;
            wb_write_data = 32'hEEEE_0000;

            wb_s1_valid = 1'b0;
            wb_s1_reg_write = 1'b0;
            wb_s1_rd = 5'd0;
            wb_s1_write_data = 32'hFFFF_0000;
        end
    endtask

    task automatic check(input logic cond, input string msg);
        begin
            if (!cond) begin
                $display("[FAIL] %s", msg);
                $finish;
            end
        end
    endtask

    task automatic check_no_wb_repair(input string msg);
        begin
            check(!id_rs1_wb_repair, {msg, ": s0 rs1 repair should be off"});
            check(!id_rs2_wb_repair, {msg, ": s0 rs2 repair should be off"});
            check(!id_rs1_wb_repair_s1, {msg, ": s0 rs1 s1 repair should be off"});
            check(!id_rs2_wb_repair_s1, {msg, ": s0 rs2 s1 repair should be off"});
            check(!id_s1_rs1_wb_repair, {msg, ": s1 rs1 repair should be off"});
            check(!id_s1_rs2_wb_repair, {msg, ": s1 rs2 repair should be off"});
            check(!id_s1_rs1_wb_repair_s1, {msg, ": s1 rs1 s1 repair should be off"});
            check(!id_s1_rs2_wb_repair_s1, {msg, ": s1 rs2 s1 repair should be off"});
        end
    endtask

    function automatic logic [31:0] reference_forward(
        input logic [ 4:0] src_addr,
        input logic [31:0] rf_data
    );
        begin
            if (ex_s1_valid && ex_s1_reg_write && (ex_s1_rd != 5'd0)
                    && (ex_s1_rd == src_addr))
                reference_forward = (ex_s1_wb_sel == 2'b10)
                                  ? ex_s1_pc_plus_4 : ex_s1_alu_result;
            else if (ex_valid && ex_reg_write
                    && (ex_rd != 5'd0) && (ex_rd == src_addr))
                reference_forward = (ex_wb_sel == 2'b10)
                                  ? ex_pc_plus_4 : ex_alu_result;
            else if (mem_s1_valid && mem_s1_reg_write && !mem_s1_is_load
                    && (mem_s1_rd != 5'd0) && (mem_s1_rd == src_addr))
                reference_forward = (mem_s1_wb_sel == 2'b10)
                                  ? mem_s1_pc_plus_4 : mem_s1_alu_result;
            else if (mem_valid && mem_reg_write && !mem_is_load
                    && (mem_rd != 5'd0) && (mem_rd == src_addr))
                reference_forward = (mem_wb_sel == 2'b10)
                                  ? mem_pc_plus_4
                                  : (mem_is_mul
                                     ? mem_mul_result : mem_alu_result);
            else if (wb_s1_valid && wb_s1_reg_write && (wb_s1_rd != 5'd0)
                    && (wb_s1_rd == src_addr))
                reference_forward = wb_s1_write_data;
            else if (wb_valid && wb_reg_write && (wb_rd != 5'd0)
                    && (wb_rd == src_addr))
                reference_forward = wb_write_data;
            else
                reference_forward = rf_data;
        end
    endfunction

    function automatic logic [31:0] reference_mul_forward(
        input logic [ 4:0] src_addr,
        input logic [31:0] rf_data
    );
        begin
            if (mem_s1_valid && mem_s1_reg_write && !mem_s1_is_load
                    && (mem_s1_rd != 5'd0) && (mem_s1_rd == src_addr))
                reference_mul_forward = (mem_s1_wb_sel == 2'b10)
                                      ? mem_s1_pc_plus_4
                                      : mem_s1_alu_result;
            else if (mem_valid && mem_reg_write && !mem_is_load
                    && (mem_rd != 5'd0) && (mem_rd == src_addr))
                reference_mul_forward = (mem_wb_sel == 2'b10)
                                      ? mem_pc_plus_4
                                      : (mem_is_mul
                                         ? mem_mul_result : mem_alu_result);
            else if (wb_s1_valid && wb_s1_reg_write && (wb_s1_rd != 5'd0)
                    && (wb_s1_rd == src_addr))
                reference_mul_forward = wb_s1_write_data;
            else if (wb_valid && wb_reg_write && (wb_rd != 5'd0)
                    && (wb_rd == src_addr))
                reference_mul_forward = wb_write_data;
            else
                reference_mul_forward = rf_data;
        end
    endfunction

    function automatic logic [31:0] reference_alu_src1(
        input logic [ 1:0] source_select,
        input logic [31:0] rs1_data,
        input logic [31:0] pc_data
    );
        case (source_select)
            2'b00:   reference_alu_src1 = rs1_data;
            2'b01:   reference_alu_src1 = pc_data;
            default: reference_alu_src1 = 32'd0;
        endcase
    endfunction

    function automatic logic [31:0] reference_alu_src2(
        input logic        source_select,
        input logic [31:0] rs2_data,
        input logic [31:0] imm_data
    );
        reference_alu_src2 = source_select ? imm_data : rs2_data;
    endfunction

    initial begin
        clear_inputs();
        #1;
        check(id_ready_go, "baseline should be ready");
        check(id_rs1_data == rf_rs1_data, "baseline rs1 should come from RF");
        check(id_s0_alu_src1 == rf_rs1_data,
              "baseline S0 ALU src1 should come from RF");
        check(id_s0_alu_src2 == rf_rs2_data,
              "baseline S0 ALU src2 should come from RF");
        check(mul_rs1_data == rf_rs1_data,
              "baseline MUL rs1 should come from RF");

        clear_inputs();
        id_s0_alu_src1_sel = 2'b01;
        id_s0_alu_src2_sel = 1'b1;
        id_s1_alu_src1_sel = 2'b10;
        id_s1_alu_src2_sel = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_rd = 5'd1;
        id_rs1_addr = 5'd1;
        id_rs2_addr = 5'd1;
        #1;
        check(id_s0_alu_src1 == id_s0_pc,
              "S0 PC candidate must bypass forwarded rs1 payload");
        check(id_s0_alu_src2 == id_s0_imm,
              "S0 immediate candidate must bypass forwarded rs2 payload");
        check(id_s1_alu_src1 == 32'd0,
              "S1 zero candidate must bypass forwarded rs1 payload");
        check(id_s1_alu_src2 == id_s1_imm,
              "S1 immediate candidate must bypass forwarded rs2 payload");

        clear_inputs();
        id_rs1_addr = 5'd5;
        id_rs1_used = 1'b1;
        id_s0_conditional_control = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_rd = 5'd5;
        ex_alu_result = 32'h1234_5678;
        #1;
        check(id_ready_go, "repaired S0 EX producer should not stall S0 branch");
        check(id_rs1_data == 32'h1234_5678, "repaired S0 EX value should forward to rs1");

        clear_inputs();
        id_rs1_addr = 5'd5;
        id_rs1_used = 1'b1;
        id_s0_indirect_control = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_rd = 5'd5;
        ex_alu_result = 32'h8765_4321;
        #1;
        check(id_ready_go, "repaired S0 EX producer should not stall S0 JALR");
        check(id_rs1_data == 32'h8765_4321,
              "indirect control should use ordinary forwarded source 0");

        clear_inputs();
        id_rs1_addr = 5'd6;
        id_rs1_used = 1'b1;
        id_s0_conditional_control = 1'b1;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_is_load = 1'b1;
        mem_load_ready = 1'b1;
        mem_rd = 5'd6;
        #1;
        check(id_ready_go, "ready MEM load should repair S0 branch");
        check(id_rs1_wb_repair, "S0 branch rs1 should select S0 WB load repair");
        check(!id_rs1_wb_repair_s1, "S0 branch rs1 repair source should be Slot0");

        clear_inputs();
        id_rs2_addr = 5'd7;
        id_rs2_used = 1'b1;
        id_s0_mem_write = 1'b1;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_is_load = 1'b1;
        mem_load_ready = 1'b1;
        mem_rd = 5'd7;
        #1;
        check(id_ready_go, "ready MEM load should repair S0 store data");
        check(id_rs2_wb_repair, "S0 store rs2 should select S0 WB load repair");
        check(!id_rs2_wb_repair_s1, "S0 store rs2 repair source should be Slot0");

        clear_inputs();
        id_rs1_addr = 5'd8;
        id_rs1_used = 1'b1;
        id_s0_mem_read = 1'b1;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_is_load = 1'b1;
        mem_load_ready = 1'b0;
        mem_rd = 5'd8;
        #1;
        check(!id_ready_go, "not-ready MEM load should still stall S0 load address");
        check_no_wb_repair("not-ready S0 MEM load / S0 load address");

        clear_inputs();
        id_s1_valid = 1'b1;
        id_s1_rs1_addr = 5'd9;
        id_s1_rs1_used = 1'b1;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_is_load = 1'b1;
        mem_load_ready = 1'b1;
        mem_rd = 5'd9;
        #1;
        check(id_ready_go, "ready S0 MEM load should repair S1 rs1 consumer");
        check(id_s1_rs1_wb_repair, "S1 rs1 should select S0 WB load repair");
        check(!id_s1_rs1_wb_repair_s1, "S1 rs1 repair source should be Slot0");

        clear_inputs();
        id_s1_valid = 1'b1;
        id_s1_rs2_addr = 5'd12;
        id_s1_rs2_used = 1'b1;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_is_load = 1'b1;
        mem_load_ready = 1'b1;
        mem_rd = 5'd12;
        #1;
        check(id_ready_go, "ready S0 MEM load should repair S1 rs2 consumer");
        check(id_s1_rs2_wb_repair, "S1 rs2 should select S0 WB load repair");
        check(!id_s1_rs2_wb_repair_s1, "S1 rs2 repair source should be Slot0");

        clear_inputs();
        id_s1_valid = 1'b1;
        id_s1_rs1_addr = 5'd9;
        id_s1_rs1_used = 1'b1;
        id_s1_repair_ok = 1'b0;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_is_load = 1'b1;
        mem_load_ready = 1'b1;
        mem_rd = 5'd9;
        #1;
        check(!id_ready_go, "S1 consumer without repair path should still stall");
        check_no_wb_repair("S1 consumer without repair path");

        clear_inputs();
        id_rs1_addr = 5'd10;
        id_rs1_used = 1'b1;
        id_s0_conditional_control = 1'b1;
        mem_s1_valid = 1'b1;
        mem_s1_reg_write = 1'b1;
        mem_s1_is_load = 1'b1;
        mem_s1_rd = 5'd10;
        mem_load_ready = 1'b1;
        #1;
        check(id_ready_go, "ready S1 MEM load should repair S0 consumer");
        check(id_rs1_wb_repair, "S0 rs1 should select WB load repair");
        check(id_rs1_wb_repair_s1, "S0 rs1 repair source should be Slot1");

        clear_inputs();
        id_s1_valid = 1'b1;
        id_s1_rs2_addr = 5'd13;
        id_s1_rs2_used = 1'b1;
        mem_s1_valid = 1'b1;
        mem_s1_reg_write = 1'b1;
        mem_s1_is_load = 1'b1;
        mem_s1_rd = 5'd13;
        mem_load_ready = 1'b1;
        #1;
        check(id_ready_go, "ready S1 MEM load should repair S1 consumer");
        check(id_s1_rs2_wb_repair, "S1 rs2 should select WB load repair");
        check(id_s1_rs2_wb_repair_s1, "S1 rs2 repair source should be Slot1");

        clear_inputs();
        id_rs1_addr = 5'd10;
        id_rs1_used = 1'b1;
        id_s0_conditional_control = 1'b1;
        mem_s1_valid = 1'b1;
        mem_s1_reg_write = 1'b1;
        mem_s1_is_load = 1'b1;
        mem_s1_rd = 5'd10;
        mem_load_ready = 1'b0;
        #1;
        check(!id_ready_go, "not-ready S1 MEM load should still stall S0 consumer");
        check_no_wb_repair("not-ready S1 MEM load / S0 consumer");

        clear_inputs();
        id_s1_valid = 1'b1;
        id_s1_rs1_addr = 5'd14;
        id_s1_rs1_used = 1'b1;
        id_s1_repair_ok = 1'b0;
        mem_s1_valid = 1'b1;
        mem_s1_reg_write = 1'b1;
        mem_s1_is_load = 1'b1;
        mem_s1_rd = 5'd14;
        mem_load_ready = 1'b1;
        #1;
        check(!id_ready_go, "S1 consumer without repair path should still stall on S1 MEM load");
        check_no_wb_repair("S1 consumer without repair path / S1 MEM load");

        clear_inputs();
        id_rs1_addr = 5'd11;
        id_rs1_used = 1'b1;
        id_s0_conditional_control = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_mem_read = 1'b1;
        ex_rd = 5'd11;
        #1;
        check(!id_ready_go, "EX load should still stall branch consumer");

        clear_inputs();
        id_s0_is_mul = 1'b1;
        id_rs1_addr = 5'd14;
        id_rs1_used = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_rd = 5'd14;
        #1;
        check(!id_ready_go,
              "MUL with a Slot-0 EX RAW dependency must wait for MEM");

        clear_inputs();
        id_s0_is_mul = 1'b1;
        id_rs2_addr = 5'd15;
        id_rs2_used = 1'b1;
        ex_s1_valid = 1'b1;
        ex_s1_reg_write = 1'b1;
        ex_s1_rd = 5'd15;
        #1;
        check(!id_ready_go,
              "MUL with a Slot-1 EX RAW dependency must wait for MEM");

        clear_inputs();
        id_s0_is_mul = 1'b1;
        id_rs1_addr = 5'd14;
        id_rs1_used = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_rd = 5'd15;
        #1;
        check(id_ready_go, "independent MUL must not acquire an EX bubble");

        clear_inputs();
        id_rs1_addr = 5'd16;
        id_rs1_used = 1'b1;
        ex_valid = 1'b1;
        ex_is_muldiv = 1'b1;
        ex_rd = 5'd16;
        #1;
        check(!id_ready_go,
              "not-yet-forwardable EX MUL must stall matching S0 consumer");
        check(id_rs1_data == rf_rs1_data,
              "EX MUL must not expose an unregistered result");

        clear_inputs();
        id_s1_valid = 1'b1;
        id_s1_rs2_addr = 5'd17;
        id_s1_rs2_used = 1'b1;
        ex_valid = 1'b1;
        ex_is_muldiv = 1'b1;
        ex_rd = 5'd17;
        #1;
        check(!id_ready_go,
              "not-yet-forwardable EX MUL must stall matching S1 consumer");

        clear_inputs();
        id_rs1_addr = 5'd18;
        id_rs1_used = 1'b1;
        ex_valid = 1'b1;
        ex_is_muldiv = 1'b1;
        ex_rd = 5'd19;
        #1;
        check(id_ready_go, "unrelated EX MUL must not stall ID");

        clear_inputs();
        id_rs1_addr = 5'd20;
        id_rs1_used = 1'b1;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_is_mul = 1'b1;
        mem_rd = 5'd20;
        mem_alu_result = 32'hBAD0_0020;
        mem_mul_result = 32'h600D_0020;
        #1;
        check(id_ready_go, "registered MEM MUL should be forwardable");
        check(id_rs1_data == 32'h600D_0020,
              "MEM MUL must select the registered product candidate");
        check(mul_rs1_data == 32'h600D_0020,
              "MUL-local forwarding must select the MEM product candidate");

        clear_inputs();
        id_rs1_addr = 5'd21;
        id_rs1_used = 1'b1;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_is_mul = 1'b1;
        mem_rd = 5'd21;
        mem_wb_sel = 2'b10;
        mem_pc_plus_4 = 32'h7000_0021;
        mem_mul_result = 32'hBAD0_0021;
        #1;
        check(id_rs1_data == 32'h7000_0021,
              "MEM PC+4 candidate must retain priority over MUL tagging");
        check(mul_rs1_data == 32'h7000_0021,
              "MUL-local MEM PC+4 candidate must beat MUL tagging");

        clear_inputs();
        id_rs1_addr = 5'd5;
        id_rs1_used = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_rd = 5'd5;
        ex_alu_result = 32'hA100_0005;
        wb_valid = 1'b1;
        wb_reg_write = 1'b1;
        wb_rd = 5'd5;
        wb_write_data = 32'hB100_0005;
        #1;
        check(id_rs1_data == 32'hA100_0005,
              "S0 EX producer must beat S0 WB");

        clear_inputs();
        id_rs1_addr = 5'd6;
        id_rs1_used = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_rd = 5'd6;
        ex_alu_result = 32'hA100_0006;
        ex_s1_valid = 1'b1;
        ex_s1_reg_write = 1'b1;
        ex_s1_rd = 5'd6;
        ex_s1_alu_result = 32'hA200_0006;
        #1;
        check(id_rs1_data == 32'hA200_0006,
              "S1 EX producer must retain youngest priority");

        clear_inputs();
        id_rs1_addr = 5'd7;
        id_rs1_used = 1'b1;
        ex_s1_valid = 1'b1;
        ex_s1_reg_write = 1'b1;
        ex_s1_rd = 5'd7;
        ex_s1_wb_sel = 2'b10;
        ex_s1_alu_result = 32'hBAD0_0007;
        ex_s1_pc_plus_4 = 32'hA200_0007;
        #1;
        check(id_rs1_data == 32'hA200_0007,
              "S1 link must remain on the architectural fallback");

        clear_inputs();
        id_rs1_addr = 5'd8;
        id_rs1_used = 1'b1;
        wb_valid = 1'b1;
        wb_reg_write = 1'b1;
        wb_rd = 5'd8;
        wb_write_data = 32'hB100_0008;
        #1;
        check(id_rs1_data == 32'hB100_0008,
              "S0 WB producer selected wrong payload");

        clear_inputs();
        id_rs1_addr = 5'd9;
        id_rs1_used = 1'b1;
        mem_valid = 1'b1;
        mem_reg_write = 1'b1;
        mem_rd = 5'd9;
        mem_alu_result = 32'hC100_0009;
        wb_valid = 1'b1;
        wb_reg_write = 1'b1;
        wb_rd = 5'd9;
        wb_write_data = 32'hB100_0009;
        #1;
        check(id_rs1_data == 32'hC100_0009,
              "younger MEM producer must beat S0 WB");

        clear_inputs();
        id_rs1_addr = 5'd10;
        id_rs1_used = 1'b1;
        wb_s1_valid = 1'b1;
        wb_s1_reg_write = 1'b1;
        wb_s1_rd = 5'd10;
        wb_s1_write_data = 32'hB200_0010;
        wb_valid = 1'b1;
        wb_reg_write = 1'b1;
        wb_rd = 5'd10;
        wb_write_data = 32'hB100_0010;
        #1;
        check(id_rs1_data == 32'hB200_0010,
              "S1 WB producer must beat S0 WB");

        // Randomized equivalence check against the architectural priority
        // tree for every operand output.
        for (int trial = 0; trial < 1000; trial = trial + 1) begin
            clear_inputs();
            id_rs1_addr = $urandom_range(0, 31);
            id_rs2_addr = $urandom_range(0, 31);
            id_s1_rs1_addr = $urandom_range(0, 31);
            id_s1_rs2_addr = $urandom_range(0, 31);
            rf_rs1_data = $urandom;
            rf_rs2_data = $urandom;
            rf_s1_rs1_data = $urandom;
            rf_s1_rs2_data = $urandom;
            id_s0_pc = $urandom;
            id_s0_imm = $urandom;
            id_s0_alu_src1_sel = $urandom_range(0, 3);
            id_s0_alu_src2_sel = $urandom_range(0, 1);
            id_s1_pc = $urandom;
            id_s1_imm = $urandom;
            id_s1_alu_src1_sel = $urandom_range(0, 3);
            id_s1_alu_src2_sel = $urandom_range(0, 1);

            ex_valid = $urandom_range(0, 1);
            ex_reg_write = $urandom_range(0, 1);
            ex_mem_read = $urandom_range(0, 1);
            ex_rd = $urandom_range(0, 31);
            ex_wb_sel = $urandom_range(0, 2);
            ex_alu_result = $urandom;
            ex_pc_plus_4 = $urandom;

            ex_s1_valid = $urandom_range(0, 1);
            ex_s1_reg_write = $urandom_range(0, 1);
            ex_s1_mem_read = $urandom_range(0, 1);
            ex_s1_rd = $urandom_range(0, 31);
            ex_s1_wb_sel = $urandom_range(0, 2);
            ex_s1_alu_result = $urandom;
            ex_s1_pc_plus_4 = $urandom;

            mem_valid = $urandom_range(0, 1);
            mem_reg_write = $urandom_range(0, 1);
            mem_is_load = $urandom_range(0, 1);
            mem_is_mul = $urandom_range(0, 1);
            mem_rd = $urandom_range(0, 31);
            mem_wb_sel = $urandom_range(0, 2);
            mem_alu_result = $urandom;
            mem_mul_result = $urandom;
            mem_pc_plus_4 = $urandom;

            mem_s1_valid = $urandom_range(0, 1);
            mem_s1_reg_write = $urandom_range(0, 1);
            mem_s1_is_load = $urandom_range(0, 1);
            mem_s1_rd = $urandom_range(0, 31);
            mem_s1_wb_sel = $urandom_range(0, 2);
            mem_s1_alu_result = $urandom;
            mem_s1_pc_plus_4 = $urandom;

            wb_valid = $urandom_range(0, 1);
            wb_reg_write = $urandom_range(0, 1);
            wb_rd = $urandom_range(0, 31);
            wb_write_data = $urandom;
            wb_s1_valid = $urandom_range(0, 1);
            wb_s1_reg_write = $urandom_range(0, 1);
            wb_s1_rd = $urandom_range(0, 31);
            wb_s1_write_data = $urandom;
            #1;

            check(id_rs1_data === reference_forward(id_rs1_addr, rf_rs1_data),
                  "random S0 rs1 forwarding mismatch");
            check(id_rs2_data === reference_forward(id_rs2_addr, rf_rs2_data),
                  "random S0 rs2 forwarding mismatch");
            check(id_s1_rs1_data
                    === reference_forward(id_s1_rs1_addr, rf_s1_rs1_data),
                  "random S1 rs1 forwarding mismatch");
            check(id_s1_rs2_data
                    === reference_forward(id_s1_rs2_addr, rf_s1_rs2_data),
                  "random S1 rs2 forwarding mismatch");
            check(id_s0_alu_src1 === reference_alu_src1(
                      id_s0_alu_src1_sel,
                      reference_forward(id_rs1_addr, rf_rs1_data), id_s0_pc),
                  "random S0 ALU src1 mismatch");
            check(id_s0_alu_src2 === reference_alu_src2(
                      id_s0_alu_src2_sel,
                      reference_forward(id_rs2_addr, rf_rs2_data), id_s0_imm),
                  "random S0 ALU src2 mismatch");
            check(id_s1_alu_src1 === reference_alu_src1(
                      id_s1_alu_src1_sel,
                      reference_forward(id_s1_rs1_addr, rf_s1_rs1_data),
                      id_s1_pc),
                  "random S1 ALU src1 mismatch");
            check(id_s1_alu_src2 === reference_alu_src2(
                      id_s1_alu_src2_sel,
                      reference_forward(id_s1_rs2_addr, rf_s1_rs2_data),
                      id_s1_imm),
                  "random S1 ALU src2 mismatch");
            check(mul_rs1_data === reference_mul_forward(
                      id_rs1_addr, rf_rs1_data),
                  "random MUL rs1 forwarding mismatch");
            check(mul_rs2_data === reference_mul_forward(
                      id_rs2_addr, rf_rs2_data),
                  "random MUL rs2 forwarding mismatch");
        end

        $display("[PASS] forwarding directed test");
        $finish;
    end
endmodule
