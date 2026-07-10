`timescale 1ns/1ps

module tb_forwarding;
    logic [ 4:0] id_rs1_addr;
    logic [ 4:0] id_rs2_addr;
    logic        id_rs1_used;
    logic        id_rs2_used;
    logic        id_s0_alu_only;
    logic        id_s0_jalr;
    logic        id_s0_branch;
    logic        id_s0_mem_read;
    logic        id_s0_mem_write;
    logic [31:0] rf_rs1_data;
    logic [31:0] rf_rs2_data;

    logic        id_s1_valid;
    logic [ 4:0] id_s1_rs1_addr;
    logic [ 4:0] id_s1_rs2_addr;
    logic        id_s1_rs1_used;
    logic        id_s1_rs2_used;
    logic        id_s1_repair_ok;
    logic [31:0] rf_s1_rs1_data;
    logic [31:0] rf_s1_rs2_data;

    logic        ex_valid;
    logic        ex_reg_write;
    logic        ex_is_bitmanip;
    logic        ex_mem_read;
    logic [ 4:0] ex_rd;
    logic [31:0] ex_alu_result;
    logic [31:0] ex_pc_plus_4;
    logic [ 1:0] ex_wb_sel;

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
    logic [ 4:0] mem_rd;
    logic [31:0] mem_alu_result;
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
    logic [31:0] id_branch_rs1_data;
    logic [31:0] id_branch_rs2_data;
    logic [31:0] id_rs1_jalr_data;
    logic [31:0] id_s1_rs1_data;
    logic [31:0] id_s1_rs2_data;
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
        .id_s0_jalr       (id_s0_jalr),
        .id_s0_branch     (id_s0_branch),
        .id_s0_mem_read   (id_s0_mem_read),
        .id_s0_mem_write  (id_s0_mem_write),
        .rf_rs1_data      (rf_rs1_data),
        .rf_rs2_data      (rf_rs2_data),
        .id_s1_valid      (id_s1_valid),
        .id_s1_rs1_addr   (id_s1_rs1_addr),
        .id_s1_rs2_addr   (id_s1_rs2_addr),
        .id_s1_rs1_used   (id_s1_rs1_used),
        .id_s1_rs2_used   (id_s1_rs2_used),
        .id_s1_repair_ok  (id_s1_repair_ok),
        .rf_s1_rs1_data   (rf_s1_rs1_data),
        .rf_s1_rs2_data   (rf_s1_rs2_data),
        .ex_valid         (ex_valid),
        .ex_reg_write     (ex_reg_write),
        .ex_is_bitmanip   (ex_is_bitmanip),
        .ex_mem_read      (ex_mem_read),
        .ex_rd            (ex_rd),
        .ex_alu_result    (ex_alu_result),
        .ex_pc_plus_4     (ex_pc_plus_4),
        .ex_wb_sel        (ex_wb_sel),
        .ex_s1_valid      (ex_s1_valid),
        .ex_s1_reg_write  (ex_s1_reg_write),
        .ex_s1_mem_read   (ex_s1_mem_read),
        .ex_s1_rd         (ex_s1_rd),
        .ex_s1_alu_result (ex_s1_alu_result),
        .ex_s1_pc_plus_4  (ex_s1_pc_plus_4),
        .ex_s1_wb_sel     (ex_s1_wb_sel),
        .mem_valid        (mem_valid),
        .mem_reg_write    (mem_reg_write),
        .mem_is_load      (mem_is_load),
        .mem_rd           (mem_rd),
        .mem_alu_result   (mem_alu_result),
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
        .id_branch_rs1_data(id_branch_rs1_data),
        .id_branch_rs2_data(id_branch_rs2_data),
        .id_rs1_jalr_data (id_rs1_jalr_data),
        .id_s1_rs1_data   (id_s1_rs1_data),
        .id_s1_rs2_data   (id_s1_rs2_data),
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

    task automatic clear_inputs;
        begin
            id_rs1_addr = 5'd0;
            id_rs2_addr = 5'd0;
            id_rs1_used = 1'b0;
            id_rs2_used = 1'b0;
            id_s0_alu_only = 1'b0;
            id_s0_jalr = 1'b0;
            id_s0_branch = 1'b0;
            id_s0_mem_read = 1'b0;
            id_s0_mem_write = 1'b0;
            rf_rs1_data = 32'h1111_0001;
            rf_rs2_data = 32'h2222_0002;

            id_s1_valid = 1'b0;
            id_s1_rs1_addr = 5'd0;
            id_s1_rs2_addr = 5'd0;
            id_s1_rs1_used = 1'b0;
            id_s1_rs2_used = 1'b0;
            id_s1_repair_ok = 1'b1;
            rf_s1_rs1_data = 32'h3333_0003;
            rf_s1_rs2_data = 32'h4444_0004;

            ex_valid = 1'b0;
            ex_reg_write = 1'b0;
            ex_is_bitmanip = 1'b0;
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
            mem_rd = 5'd0;
            mem_alu_result = 32'hCCCC_0000;
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

    initial begin
        clear_inputs();
        #1;
        check(id_ready_go, "baseline should be ready");
        check(id_rs1_data == rf_rs1_data, "baseline rs1 should come from RF");

        clear_inputs();
        id_rs1_addr = 5'd5;
        id_rs1_used = 1'b1;
        id_s0_branch = 1'b1;
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
        id_s0_jalr = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_rd = 5'd5;
        ex_alu_result = 32'h8765_4321;
        #1;
        check(id_ready_go, "repaired S0 EX producer should not stall S0 JALR");
        check(id_rs1_jalr_data == 32'h8765_4321, "JALR rs1 should use ordinary forwarded rs1");

        clear_inputs();
        id_rs1_addr = 5'd6;
        id_rs1_used = 1'b1;
        id_s0_branch = 1'b1;
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
        id_s0_branch = 1'b1;
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
        id_s0_branch = 1'b1;
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
        id_s0_branch = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_mem_read = 1'b1;
        ex_rd = 5'd11;
        #1;
        check(!id_ready_go, "EX load should still stall branch consumer");

        clear_inputs();
        id_rs1_addr = 5'd12;
        id_rs1_used = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_is_bitmanip = 1'b1;
        ex_rd = 5'd12;
        ex_alu_result = 32'hb17b_17b1;
        #1;
        check(!id_ready_go, "completed EX B producer should stall S0 consumer");
        check(id_rs1_data == rf_rs1_data,
              "EX B result must not enter the forwarding payload mux");

        clear_inputs();
        id_s1_valid = 1'b1;
        id_s1_rs2_addr = 5'd13;
        id_s1_rs2_used = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_is_bitmanip = 1'b1;
        ex_rd = 5'd13;
        #1;
        check(!id_ready_go, "completed EX B producer should stall S1 consumer");

        clear_inputs();
        id_rs1_addr = 5'd14;
        id_rs1_used = 1'b1;
        ex_valid = 1'b1;
        ex_reg_write = 1'b1;
        ex_is_bitmanip = 1'b1;
        ex_rd = 5'd15;
        #1;
        check(id_ready_go, "unrelated EX B producer must not stall ID");

        $display("[PASS] forwarding directed test");
        $finish;
    end
endmodule
