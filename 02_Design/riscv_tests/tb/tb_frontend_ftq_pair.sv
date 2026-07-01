`timescale 1ns/1ps

module tb_frontend_ftq_pair;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam int IMEM_WORDS = 4096;

    logic clk;
    logic rst_n;
    logic id_allowin;
    logic ex_redirect_valid;
    logic [31:0] ex_redirect_target;
    logic [11:0] irom_addr;
    logic [63:0] irom_data;

    logic if_valid;
    logic if_ready_go;
    logic if_s1_valid;
    wire if_id_payload_t if_payload;
    wire [31:0] if_pc = if_payload.pc;
    wire [31:0] if_inst0 = if_payload.slot0.inst;
    wire [31:0] if_inst1 = if_payload.slot1.inst;
    wire if_pred_taken = if_payload.slot0.prediction.taken;
    wire [31:0] if_pred_target = if_payload.slot0.prediction.target;
    wire if_s1_pred_taken = if_payload.slot1.prediction.taken;
    wire [31:0] if_s1_pred_target = if_payload.slot1.prediction.target;
    wire if_abtb_hit = if_payload.slot0.prediction.abtb_hit;
    wire if_abtb_way = if_payload.slot0.prediction.abtb_way;
    wire [1:0] if_abtb_cfi_type = if_payload.slot0.prediction.abtb_cfi_type;
    wire [31:0] if_abtb_target = if_payload.slot0.prediction.abtb_target;
    wire if_abtb_pred_taken = if_payload.slot0.prediction.abtb_pred_taken;
    wire [31:0] if_abtb_pred_target = if_payload.slot0.prediction.abtb_pred_target;
    wire if_s1_abtb_hit = if_payload.slot1.prediction.abtb_hit;
    wire if_s1_abtb_way = if_payload.slot1.prediction.abtb_way;
    wire [1:0] if_s1_abtb_cfi_type = if_payload.slot1.prediction.abtb_cfi_type;
    wire [31:0] if_s1_abtb_target = if_payload.slot1.prediction.abtb_target;
    wire if_s1_abtb_pred_taken = if_payload.slot1.prediction.abtb_pred_taken;
    wire [31:0] if_s1_abtb_pred_target = if_payload.slot1.prediction.abtb_pred_target;
    logic [31:0] current_pc;
    logic abtb_lookup_accept;
    logic can_dual_issue;
    logic raw_pair_raw;
    logic predict_dual;
    logic irom_held_valid;
    logic if_skip_out;

    logic [63:0] imem [0:IMEM_WORDS-1];
    logic pred_taken_valid;
    logic [31:0] pred_taken_pc;
    logic [31:0] pred_taken_target;

    integer case_count;
    integer fail_count;
    integer i;

    frontend_ftq dut (
        .clk(clk),
        .rst_n(rst_n),
        .id_allowin(id_allowin),
        .ex_redirect_valid(ex_redirect_valid),
        .ex_redirect_target(ex_redirect_target),
        .irom_addr(irom_addr),
        .irom_data(irom_data),
        .abtb_bank0_lookup_hit(pred_taken_valid && (current_pc == pred_taken_pc)),
        .abtb_bank0_hit(pred_taken_valid && (current_pc == pred_taken_pc)),
        .abtb_bank0_way(1'b0),
        .abtb_bank0_cfi_type(2'd0),
        .abtb_bank0_target(pred_taken_target),
        .abtb_bank0_pred_taken(pred_taken_valid && (current_pc == pred_taken_pc)),
        .abtb_bank0_pred_target(pred_taken_target),
        .abtb_bank1_lookup_hit(1'b0),
        .abtb_bank1_hit(1'b0),
        .abtb_bank1_way(1'b0),
        .abtb_bank1_cfi_type(2'd0),
        .abtb_bank1_target(32'd0),
        .abtb_bank1_pred_taken(1'b0),
        .abtb_bank1_pred_target(32'd0),
        .stage1_bank0_pht_index(8'd0),
        .stage1_bank0_pht_counter(2'b01),
        .stage1_bank1_pht_index(8'd1),
        .stage1_bank1_pht_counter(2'b01),
        .if_valid(if_valid),
        .if_ready_go(if_ready_go),
        .if_s1_valid(if_s1_valid),
        .if_payload(if_payload),
        .current_pc(current_pc),
        .abtb_lookup_accept(abtb_lookup_accept),
        .can_dual_issue(can_dual_issue),
        .raw_pair_raw(raw_pair_raw),
        .predict_dual(predict_dual),
        .irom_held_valid(irom_held_valid),
        .if_skip_out(if_skip_out)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irom_data <= 64'd0;
        else
            irom_data <= imem[irom_addr];
    end

    function automatic int unsigned block_idx(input logic [31:0] pc);
        block_idx = int'(pc[14:3]);
    endfunction

    function automatic logic [31:0] r_add(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input logic [4:0] rs2
    );
        r_add = {7'b0000000, rs2, rs1, 3'b000, rd, OP_R_TYPE};
    endfunction

    function automatic logic [31:0] i_addi(
        input logic [4:0] rd,
        input logic [4:0] rs1
    );
        i_addi = {12'd0, rs1, 3'b000, rd, OP_I_ALU};
    endfunction

    function automatic logic [31:0] lw_inst(
        input logic [4:0] rd,
        input logic [4:0] rs1
    );
        lw_inst = {12'd0, rs1, 3'b010, rd, OP_LOAD};
    endfunction

    function automatic logic [31:0] sw_inst(
        input logic [4:0] rs2,
        input logic [4:0] rs1
    );
        sw_inst = {7'd0, rs2, rs1, 3'b010, 5'd0, OP_STORE};
    endfunction

    function automatic logic [31:0] beq_inst(
        input logic [4:0] rs1,
        input logic [4:0] rs2
    );
        beq_inst = {7'd0, rs2, rs1, 3'b000, 5'd0, OP_BRANCH};
    endfunction

    function automatic logic [31:0] jal_inst(input logic [4:0] rd);
        jal_inst = {20'd0, rd, OP_JAL};
    endfunction

    function automatic logic [31:0] jalr_inst(
        input logic [4:0] rd,
        input logic [4:0] rs1
    );
        jalr_inst = {12'd0, rs1, 3'b000, rd, OP_JALR};
    endfunction

    function automatic logic [31:0] fence_inst;
        fence_inst = 32'h0000_000f;
    endfunction

    function automatic logic [31:0] ecall_inst;
        ecall_inst = 32'h0000_0073;
    endfunction

    task automatic check(input logic cond, input string msg);
        begin
            if (!cond) begin
                fail_count++;
                $display("[FAIL] %s at time %0t", msg, $time);
                $fatal(1, "%s", msg);
            end
        end
    endtask

    task automatic clear_imem;
        begin
            for (i = 0; i < IMEM_WORDS; i = i + 1)
                imem[i] = {i_addi(5'd0, 5'd0), i_addi(5'd0, 5'd0)};
        end
    endtask

    task automatic set_block(
        input logic [31:0] pc,
        input logic [31:0] slot0,
        input logic [31:0] slot1
    );
        begin
            imem[block_idx(pc)] = {slot1, slot0};
        end
    endtask

    task automatic begin_case(input string name);
        begin
            case_count++;
            clear_imem();
            pred_taken_valid = 1'b0;
            pred_taken_pc = 32'd0;
            pred_taken_target = 32'd0;
            id_allowin = 1'b0;
            ex_redirect_valid = 1'b0;
            ex_redirect_target = 32'd0;
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            $display("[INFO] case %0d: %s", case_count, name);
        end
    endtask

    task automatic release_reset;
        begin
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic wait_head(input logic [31:0] pc);
        bit found;
        begin
            found = 1'b0;
            for (int t = 0; t < 80; t = t + 1) begin
                @(negedge clk);
                if (if_valid && (if_pc == pc)) begin
                    found = 1'b1;
                    break;
                end
            end
            check(found, $sformatf("timeout waiting for head pc %08x", pc));
        end
    endtask

    task automatic expect_pair_at_head(
        input string name,
        input logic [31:0] pc,
        input logic expected_pair
    );
        begin
            wait_head(pc);
            check(if_s1_valid == expected_pair,
                  $sformatf("%s pair expected %0d got %0d",
                            name, expected_pair, if_s1_valid));
            check(can_dual_issue == if_s1_valid,
                  $sformatf("%s can_dual_issue mismatch", name));
            check(predict_dual == if_s1_valid,
                  $sformatf("%s predict_dual mismatch", name));
        end
    endtask

    task automatic consume_current_head;
        begin
            @(negedge clk);
            id_allowin = 1'b1;
            @(posedge clk);
            @(negedge clk);
            id_allowin = 1'b0;
        end
    endtask

    task automatic run_pair_case(
        input string name,
        input logic [31:0] slot0,
        input logic [31:0] slot1,
        input logic expected_pair
    );
        begin
            begin_case(name);
            set_block(RESET_PC, slot0, slot1);
            release_reset();
            expect_pair_at_head(name, RESET_PC, expected_pair);
        end
    endtask

    task automatic run_pred_taken_case;
        begin
            begin_case("ABTB taken suppresses pair");
            set_block(RESET_PC, beq_inst(5'd1, 5'd2), r_add(5'd3, 5'd4, 5'd5));
            pred_taken_valid = 1'b1;
            pred_taken_pc = RESET_PC;
            pred_taken_target = RESET_PC + 32'd32;
            release_reset();
            expect_pair_at_head("abtb_taken", RESET_PC, 1'b0);
        end
    endtask

    task automatic run_cross_packet_case;
        begin
            begin_case("cross-packet pairing");
            set_block(RESET_PC, fence_inst(), r_add(5'd2, 5'd0, 5'd0));
            set_block(RESET_PC + 32'd8, r_add(5'd3, 5'd0, 5'd0),
                      r_add(5'd4, 5'd0, 5'd0));
            release_reset();
            expect_pair_at_head("force_single first entry", RESET_PC, 1'b0);
            consume_current_head();
            expect_pair_at_head("cross_packet", RESET_PC + 32'd4, 1'b1);
        end
    endtask

    task automatic run_stall_hold_case;
        begin
            begin_case("stall holds pair metadata");
            set_block(RESET_PC, r_add(5'd1, 5'd0, 5'd0),
                      r_add(5'd2, 5'd0, 5'd0));
            release_reset();
            wait_head(RESET_PC);
            id_allowin = 1'b0;
            repeat (6) begin
                @(negedge clk);
                check(if_valid && if_pc == RESET_PC && if_s1_valid,
                      "stall did not hold pair metadata");
            end
        end
    endtask

    task automatic run_redirect_refetch_case;
        begin
            begin_case("redirect clears old pair and same PC refetches");
            set_block(RESET_PC, r_add(5'd1, 5'd0, 5'd0),
                      r_add(5'd2, 5'd0, 5'd0));
            release_reset();
            expect_pair_at_head("before_redirect", RESET_PC, 1'b1);
            @(negedge clk);
            ex_redirect_valid = 1'b1;
            ex_redirect_target = RESET_PC;
            @(posedge clk);
            @(negedge clk);
            ex_redirect_valid = 1'b0;
            @(negedge clk);
            check(!if_valid, "redirect did not clear visible FQ valid");
            expect_pair_at_head("after_redirect_refetch", RESET_PC, 1'b1);
        end
    endtask

    task automatic run_wrap_overwrite_case;
        logic [31:0] target_pc;
        bit found;
        begin
            begin_case("FQ wrap and pair overwrite");
            for (int b = 0; b < 8; b = b + 1) begin
                set_block(RESET_PC + 32'(b * 8),
                          r_add(5'(b + 1), 5'd0, 5'd0),
                          r_add(5'(b + 9), 5'd0, 5'd0));
            end
            target_pc = RESET_PC + 32'd64;
            set_block(target_pc, lw_inst(5'd1, 5'd0), lw_inst(5'd2, 5'd0));
            for (int b = 9; b < 24; b = b + 1) begin
                set_block(RESET_PC + 32'(b * 8),
                          r_add(5'(b[4:0]), 5'd0, 5'd0),
                          r_add(5'((b + 1) & 31), 5'd0, 5'd0));
            end
            release_reset();
            repeat (12) @(posedge clk);
            id_allowin = 1'b1;
            found = 1'b0;
            for (int t = 0; t < 160; t = t + 1) begin
                @(negedge clk);
                if (if_valid && if_pc == target_pc) begin
                    found = 1'b1;
                    id_allowin = 1'b0;
                    check(!if_s1_valid,
                          "wrapped load/load entry kept stale pair_ok");
                    break;
                end
            end
            check(found, "did not observe wrapped overwrite target");
        end
    endtask

    initial begin
        case_count = 0;
        fail_count = 0;
        rst_n = 1'b0;
        id_allowin = 1'b0;
        ex_redirect_valid = 1'b0;
        ex_redirect_target = 32'd0;
        pred_taken_valid = 1'b0;
        pred_taken_pc = 32'd0;
        pred_taken_target = 32'd0;
        clear_imem();

        run_pair_case("same fetch ALU+ALU",
                      r_add(5'd1, 5'd0, 5'd0),
                      r_add(5'd2, 5'd0, 5'd0),
                      1'b1);
        run_pair_case("RAW rs1 dependency",
                      r_add(5'd5, 5'd0, 5'd0),
                      r_add(5'd6, 5'd5, 5'd0),
                      1'b0);
        run_pair_case("RAW rs2 dependency",
                      r_add(5'd5, 5'd0, 5'd0),
                      r_add(5'd6, 5'd0, 5'd5),
                      1'b0);
        run_pair_case("rd x0 does not form RAW",
                      r_add(5'd0, 5'd1, 5'd2),
                      r_add(5'd6, 5'd0, 5'd3),
                      1'b1);
        run_pair_case("force_single slot0",
                      fence_inst(),
                      r_add(5'd2, 5'd0, 5'd0),
                      1'b0);
        run_pred_taken_case();
        run_pair_case("ALU+load",
                      r_add(5'd1, 5'd0, 5'd0),
                      lw_inst(5'd2, 5'd3),
                      1'b1);
        run_pair_case("ALU+store",
                      r_add(5'd1, 5'd0, 5'd0),
                      sw_inst(5'd2, 5'd3),
                      1'b1);
        run_pair_case("ALU+JAL",
                      r_add(5'd1, 5'd0, 5'd0),
                      jal_inst(5'd1),
                      1'b1);
        run_pair_case("ALU+JALR",
                      r_add(5'd1, 5'd0, 5'd0),
                      jalr_inst(5'd0, 5'd5),
                      1'b1);
        run_pair_case("non-control+branch",
                      r_add(5'd1, 5'd0, 5'd0),
                      beq_inst(5'd2, 5'd3),
                      1'b1);
        run_pair_case("load+branch",
                      lw_inst(5'd1, 5'd0),
                      beq_inst(5'd2, 5'd3),
                      1'b1);
        run_pair_case("store+branch",
                      sw_inst(5'd2, 5'd3),
                      beq_inst(5'd4, 5'd5),
                      1'b1);
        run_pair_case("branch+load",
                      beq_inst(5'd2, 5'd3),
                      lw_inst(5'd1, 5'd4),
                      1'b1);
        run_pair_case("branch+store",
                      beq_inst(5'd2, 5'd3),
                      sw_inst(5'd4, 5'd5),
                      1'b1);
        run_pair_case("load+JAL",
                      lw_inst(5'd1, 5'd0),
                      jal_inst(5'd2),
                      1'b1);
        run_pair_case("load+JALR",
                      lw_inst(5'd1, 5'd0),
                      jalr_inst(5'd2, 5'd3),
                      1'b1);
        run_pair_case("store+JAL",
                      sw_inst(5'd2, 5'd3),
                      jal_inst(5'd1),
                      1'b1);
        run_pair_case("store+JALR",
                      sw_inst(5'd2, 5'd3),
                      jalr_inst(5'd1, 5'd4),
                      1'b1);
        run_pair_case("unsupported load+load",
                      lw_inst(5'd1, 5'd0),
                      lw_inst(5'd2, 5'd0),
                      1'b0);
        run_pair_case("unsupported store+load",
                      sw_inst(5'd2, 5'd3),
                      lw_inst(5'd1, 5'd4),
                      1'b0);
        run_pair_case("unsupported branch+JAL",
                      beq_inst(5'd1, 5'd2),
                      jal_inst(5'd3),
                      1'b0);
        run_pair_case("unsupported branch+JALR",
                      beq_inst(5'd1, 5'd2),
                      jalr_inst(5'd3, 5'd4),
                      1'b0);
        run_pair_case("slot0 JAL kills slot1",
                      jal_inst(5'd1),
                      r_add(5'd2, 5'd0, 5'd0),
                      1'b0);
        run_pair_case("slot0 JALR kills slot1",
                      jalr_inst(5'd0, 5'd1),
                      r_add(5'd2, 5'd0, 5'd0),
                      1'b0);
        run_pair_case("slot0 system redirect kills slot1",
                      ecall_inst(),
                      r_add(5'd2, 5'd0, 5'd0),
                      1'b0);
        run_cross_packet_case();
        run_stall_hold_case();
        run_redirect_refetch_case();
        run_wrap_overwrite_case();

        $display("[PASS] frontend_ftq pair policy directed test (%0d cases)",
                 case_count);
        $finish;
    end
endmodule
