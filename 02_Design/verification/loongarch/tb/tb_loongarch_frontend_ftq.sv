`timescale 1ns/1ps

module tb_loongarch_frontend_ftq;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam int IMEM_WORDS = 4096;
    localparam logic [31:0] LOONGARCH_NOP = 32'h0340_0000;

    logic clk;
    logic rst_n;
    logic id_allowin;
    logic ex_redirect_valid;
    logic [31:0] ex_redirect_target;
    logic [11:0] irom_addr;
    logic [63:0] irom_data;
    logic [63:0] imem [0:IMEM_WORDS-1];

    logic if_valid;
    logic if_ready_go;
    logic if_s1_valid;
    wire if_id_payload_t if_payload;
    logic [31:0] current_pc;
    logic abtb_lookup_accept;
    logic can_dual_issue;
    logic raw_pair_raw;
    logic predict_dual;
    logic irom_held_valid;
    logic if_skip_out;

    wire [31:0] if_pc = if_payload.pc;
    wire [31:0] if_inst0 = if_payload.slot0.inst;
    wire [31:0] if_inst1 = if_payload.slot1.inst;
    wire issue0_is_muldiv = if_payload.slot0.issue_hint.is_muldiv;
    wire issue0_is_mul = if_payload.slot0.issue_hint.is_mul;
    wire issue1_is_muldiv = if_payload.slot1.issue_hint.is_muldiv;
    wire issue1_is_mul = if_payload.slot1.issue_hint.is_mul;

    integer case_count;
    integer fail_count;

    frontend_ftq dut (
        .clk(clk),
        .rst_n(rst_n),
        .id_allowin(id_allowin),
        .ex_redirect_valid(ex_redirect_valid),
        .ex_redirect_target(ex_redirect_target),
        .irom_addr(irom_addr),
        .irom_req_valid(),
        .irom_req_addr(),
        .irom_req_ready(1'b0),
        .irom_resp_valid(1'b0),
        .irom_data(irom_data),
        .abtb_bank0_lookup_hit(1'b0),
        .abtb_bank0_hit(1'b0),
        .abtb_bank0_way(1'b0),
        .abtb_bank0_cfi_type(2'd0),
        .abtb_bank0_abtb_pred_target(32'd0),
        .abtb_bank0_pred_taken(1'b0),
        .abtb_bank0_final_pred_target(32'd0),
        .abtb_bank1_lookup_hit(1'b0),
        .abtb_bank1_hit(1'b0),
        .abtb_bank1_way(1'b0),
        .abtb_bank1_cfi_type(2'd0),
        .abtb_bank1_abtb_pred_target(32'd0),
        .abtb_bank1_pred_taken(1'b0),
        .abtb_bank1_final_pred_target(32'd0),
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
        .stage1_steer_valid(),
        .stage1_steer_source_abtb(),
        .stage1_steer_branch_owned(),
        .stage1_steer_branch_owned_nt(),
        .stage1_steer_taken(),
        .stage1_steer_bank(),
        .stage1_steer_cfi_type(),
        .stage1_steer_target(),
        .stage1_steer_next_pc(),
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
            irom_data <= {LOONGARCH_NOP, LOONGARCH_NOP};
        else
            irom_data <= imem[irom_addr];
    end

    function automatic int unsigned block_idx(input logic [31:0] pc);
        block_idx = int'(pc[14:3]);
    endfunction

    function automatic logic [31:0] enc_rr(
        input logic [1:0] op_21_20,
        input logic [4:0] op_19_15,
        input logic [4:0] rk,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_rr = {6'h00, 4'h0, op_21_20, op_19_15, rk, rj, rd};
    endfunction

    function automatic logic [31:0] enc_i12(
        input logic [5:0] op_31_26,
        input logic [3:0] op_25_22,
        input logic [11:0] immediate,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_i12 = {op_31_26, op_25_22, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] enc_i16(
        input logic [5:0] op_31_26,
        input logic [15:0] immediate,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_i16 = {op_31_26, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] add_w(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [4:0] rk
    );
        add_w = enc_rr(2'h1, 5'h00, rk, rj, rd);
    endfunction

    function automatic logic [31:0] mul_w(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [4:0] rk
    );
        mul_w = enc_rr(2'h1, 5'h18, rk, rj, rd);
    endfunction

    function automatic logic [31:0] div_w(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [4:0] rk
    );
        div_w = enc_rr(2'h2, 5'h00, rk, rj, rd);
    endfunction

    function automatic logic [31:0] st_w(
        input logic [4:0] data_rd,
        input logic [4:0] base_rj
    );
        st_w = enc_i12(6'h0a, 4'h6, 12'd0, base_rj, data_rd);
    endfunction

    function automatic logic [31:0] beq(
        input logic [4:0] rj,
        input logic [4:0] compare_rd
    );
        beq = enc_i16(6'h16, 16'd1, rj, compare_rd);
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            if (condition !== 1'b1) begin
                fail_count++;
                $fatal(1, "[FAIL] %s at time %0t", message, $time);
            end
        end
    endtask

    task automatic clear_imem;
        begin
            for (int i = 0; i < IMEM_WORDS; i++)
                imem[i] = {LOONGARCH_NOP, LOONGARCH_NOP};
        end
    endtask

    task automatic set_block(
        input logic [31:0] pc,
        input logic [31:0] slot0,
        input logic [31:0] slot1
    );
        imem[block_idx(pc)] = {slot1, slot0};
    endtask

    task automatic begin_case(input string name);
        begin
            case_count++;
            rst_n = 1'b0;
            id_allowin = 1'b0;
            ex_redirect_valid = 1'b0;
            ex_redirect_target = 32'd0;
            clear_imem();
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
            for (int t = 0; t < 80; t++) begin
                @(negedge clk);
                if (if_valid && (if_pc == pc)) begin
                    found = 1'b1;
                    break;
                end
            end
            check(found, $sformatf("timeout waiting for head pc %08x", pc));
        end
    endtask

    task automatic run_pair_case(
        input string       name,
        input logic [31:0] slot0,
        input logic [31:0] slot1,
        input logic        expected_pair
    );
        begin
            begin_case(name);
            set_block(RESET_PC, slot0, slot1);
            release_reset();
            wait_head(RESET_PC);
            check(if_inst0 == slot0, "slot0 instruction changed in FTQ");
            check(if_inst1 == slot1, "slot1 instruction changed in FTQ");
            check(if_s1_valid == expected_pair,
                  $sformatf("pair expected %0d got %0d",
                            expected_pair, if_s1_valid));
            check(can_dual_issue == expected_pair,
                  "can_dual_issue disagrees with pair result");
            check(predict_dual == expected_pair,
                  "predict_dual disagrees with pair result");
        end
    endtask

    initial begin
        logic [31:0] mul_leak_guard;
        logic [31:0] div_leak_guard;

        case_count = 0;
        fail_count = 0;
        rst_n = 1'b0;
        id_allowin = 1'b0;
        ex_redirect_valid = 1'b0;
        ex_redirect_target = 32'd0;
        clear_imem();

        // rk=20 forces inst[14]=1.  The old common-core shortcut would
        // misclassify this real LoongArch multiply as a divide.
        mul_leak_guard = mul_w(5'd3, 5'd4, 5'd20);
        check(mul_leak_guard[14] == 1'b1,
              "MUL leak guard does not set inst[14]");
        run_pair_case("MUL semantic bit survives F0/FTQ/IF-ID",
                      mul_leak_guard,
                      add_w(5'd6, 5'd7, 5'd8), 1'b1);
        check(issue0_is_muldiv && issue0_is_mul,
              "MUL semantic issue hint was lost in the FTQ");

        // rk=5 forces inst[14]=0.  The old shortcut would misclassify this
        // real LoongArch divide as a multiply and permit unsafe pairing.
        div_leak_guard = div_w(5'd3, 5'd4, 5'd5);
        check(div_leak_guard[14] == 1'b0,
              "DIV leak guard does not clear inst[14]");
        run_pair_case("DIV remains semantic force-single through FTQ",
                      div_leak_guard,
                      add_w(5'd6, 5'd7, 5'd8), 1'b0);
        check(issue0_is_muldiv && !issue0_is_mul,
              "DIV semantic issue hint was changed in the FTQ");

        run_pair_case("MUL result RAW blocks younger ALU",
                      mul_leak_guard,
                      add_w(5'd6, 5'd3, 5'd8), 1'b0);
        run_pair_case("MUL result cannot use ALU-to-store-data bypass",
                      mul_leak_guard,
                      st_w(5'd3, 5'd9), 1'b0);
        run_pair_case("LoongArch ALU-to-store-data bypass remains legal",
                      add_w(5'd3, 5'd4, 5'd5),
                      st_w(5'd3, 5'd9), 1'b1);
        run_pair_case("LoongArch store-address RAW remains blocked",
                      add_w(5'd9, 5'd4, 5'd5),
                      st_w(5'd3, 5'd9), 1'b0);
        run_pair_case("LoongArch ALU-to-branch rd-field RAW uses EX2",
                      add_w(5'd3, 5'd4, 5'd5),
                      beq(5'd9, 5'd3), 1'b1);
        run_pair_case("r0 destination does not create a false RAW",
                      add_w(5'd0, 5'd4, 5'd5),
                      add_w(5'd6, 5'd0, 5'd8), 1'b1);
        run_pair_case("slot1 LoongArch MUL remains unsupported",
                      add_w(5'd3, 5'd4, 5'd5),
                      mul_w(5'd6, 5'd7, 5'd20), 1'b0);
        check(issue1_is_muldiv && issue1_is_mul,
              "slot1 MUL semantic metadata was not retained");

        $display("[PASS] LoongArch frontend FTQ semantic/pairing test (%0d cases)",
                 case_count);
        $finish;
    end

endmodule
