`timescale 1ns/1ps

module tb_frontend_ftq_canonical;
    import cpu_defs::*;

    localparam logic [31:0] BASE = 32'h8000_0000;
    localparam logic [1:0] TYPE_JAL = 2'b00;
    localparam logic [1:0] TYPE_BRANCH = 2'b10;

    logic clk;
    logic rst_n;
    logic id_allowin;
    logic ex_redirect_valid;
    logic [31:0] ex_redirect_target;
    logic [11:0] irom_addr;
    logic [63:0] irom_data;

    logic abtb_bank0_hit;
    logic abtb_bank0_way;
    logic [1:0] abtb_bank0_cfi_type;
    logic [31:0] abtb_bank0_abtb_pred_target;
    logic abtb_bank0_pred_taken;
    logic [31:0] abtb_bank0_final_pred_target;
    logic abtb_bank1_hit;
    logic abtb_bank1_way;
    logic [1:0] abtb_bank1_cfi_type;
    logic [31:0] abtb_bank1_abtb_pred_target;
    logic abtb_bank1_pred_taken;
    logic [31:0] abtb_bank1_final_pred_target;

    logic if_valid;
    logic if_s1_valid;
    wire if_id_payload_t if_payload;
    wire if_pred_taken = if_payload.slot0.prediction.taken;
    wire [31:0] if_pred_target = if_payload.slot0.prediction.target;
    wire if_pred_source_abtb = if_payload.slot0.prediction.source_abtb;
    wire if_stage1_branch_owned =
        if_payload.slot0.prediction.stage1_branch_owned;
    wire if_s1_pred_taken = if_payload.slot1.prediction.taken;
    wire [31:0] if_s1_pred_target = if_payload.slot1.prediction.target;
    wire if_s1_pred_source_abtb = if_payload.slot1.prediction.source_abtb;
    wire if_s1_stage1_branch_owned =
        if_payload.slot1.prediction.stage1_branch_owned;
    logic [31:0] current_pc;
    logic stage1_steer_valid;
    logic stage1_steer_source_abtb;
    logic stage1_steer_branch_owned;
    logic stage1_steer_branch_owned_nt;
    logic stage1_steer_taken;
    logic stage1_steer_bank;
    logic [1:0] stage1_steer_cfi_type;
    logic [31:0] stage1_steer_target;
    logic [31:0] stage1_steer_next_pc;
    integer case_count;

    frontend_ftq dut (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .id_allowin                  (id_allowin),
        .ex_redirect_valid           (ex_redirect_valid),
        .ex_redirect_target          (ex_redirect_target),
        .irom_addr                   (irom_addr),
        .irom_data                   (irom_data),
        .abtb_bank0_lookup_hit       (abtb_bank0_hit),
        .abtb_bank0_hit              (abtb_bank0_hit),
        .abtb_bank0_way              (abtb_bank0_way),
        .abtb_bank0_cfi_type         (abtb_bank0_cfi_type),
        .abtb_bank0_abtb_pred_target           (abtb_bank0_abtb_pred_target),
        .abtb_bank0_pred_taken       (abtb_bank0_pred_taken),
        .abtb_bank0_final_pred_target      (abtb_bank0_final_pred_target),
        .abtb_bank1_lookup_hit       (abtb_bank1_hit),
        .abtb_bank1_hit              (abtb_bank1_hit),
        .abtb_bank1_way              (abtb_bank1_way),
        .abtb_bank1_cfi_type         (abtb_bank1_cfi_type),
        .abtb_bank1_abtb_pred_target           (abtb_bank1_abtb_pred_target),
        .abtb_bank1_pred_taken       (abtb_bank1_pred_taken),
        .abtb_bank1_final_pred_target      (abtb_bank1_final_pred_target),
        .stage1_bank0_pht_index      (8'h10),
        .stage1_bank0_pht_counter    (2'b01),
        .stage1_bank1_pht_index      (8'h11),
        .stage1_bank1_pht_counter    (2'b10),
        .if_valid                    (if_valid),
        .if_ready_go                 (),
        .if_s1_valid                 (if_s1_valid),
        .if_payload                  (if_payload),
        .current_pc                  (current_pc),
        .abtb_lookup_accept          (),
        .stage1_steer_valid          (stage1_steer_valid),
        .stage1_steer_source_abtb    (stage1_steer_source_abtb),
        .stage1_steer_branch_owned   (stage1_steer_branch_owned),
        .stage1_steer_branch_owned_nt(stage1_steer_branch_owned_nt),
        .stage1_steer_taken          (stage1_steer_taken),
        .stage1_steer_bank           (stage1_steer_bank),
        .stage1_steer_cfi_type       (stage1_steer_cfi_type),
        .stage1_steer_target         (stage1_steer_target),
        .stage1_steer_next_pc        (stage1_steer_next_pc),
        .can_dual_issue              (),
        .raw_pair_raw                (),
        .predict_dual                (),
        .irom_held_valid             (),
        .if_skip_out                 ()
    );

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "[FAIL] %s", message);
    endtask

    task automatic pass_case(input string message);
        begin
            case_count = case_count + 1;
            $display("[INFO] case %0d: %s", case_count, message);
        end
    endtask

    task automatic drive_defaults;
        begin
            id_allowin = 1'b1;
            ex_redirect_valid = 1'b0;
            ex_redirect_target = 32'd0;
            irom_data = {32'h0000_0013, 32'h0000_0013};
            abtb_bank0_hit = 1'b0;
            abtb_bank0_way = 1'b0;
            abtb_bank0_cfi_type = 2'd0;
            abtb_bank0_abtb_pred_target = 32'd0;
            abtb_bank0_pred_taken = 1'b0;
            abtb_bank0_final_pred_target = 32'd0;
            abtb_bank1_hit = 1'b1;
            abtb_bank1_way = 1'b0;
            abtb_bank1_cfi_type = TYPE_JAL;
            abtb_bank1_abtb_pred_target = BASE + 32'h80;
            abtb_bank1_pred_taken = 1'b1;
            abtb_bank1_final_pred_target = BASE + 32'h80;
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            #1;
        end
    endtask

    task automatic accept_taken_and_check(
        input logic expected_source_abtb,
        input logic expected_bank,
        input logic [31:0] expected_next
    );
        begin
            #1;
            check(stage1_steer_valid
                  && stage1_steer_source_abtb == expected_source_abtb
                  && stage1_steer_taken
                  && stage1_steer_bank == expected_bank
                  && stage1_steer_next_pc == expected_next,
                  "BP0 canonical steering mismatch");
            @(posedge clk);
            #1;
            check(current_pc == expected_next
                  && dut.f0_steer_source_abtb_r == expected_source_abtb
                  && dut.f0_steer_bank_r == expected_bank
                  && dut.f0_steer_next_pc_r == expected_next,
                  "accepted canonical snapshot and current_pc diverged");
        end
    endtask

    task automatic accept_sequential_and_check(input logic [31:0] expected_next);
        begin
            #1;
            check(stage1_steer_valid
                  && !stage1_steer_source_abtb
                  && !stage1_steer_branch_owned
                  && !stage1_steer_branch_owned_nt
                  && !stage1_steer_taken
                  && stage1_steer_next_pc == expected_next,
                  "BP0 canonical sequential fallback mismatch");
            @(posedge clk);
            #1;
            check(current_pc == expected_next
                  && !dut.f0_steer_taken_r
                  && !dut.f0_steer_source_abtb_r
                  && dut.f0_steer_next_pc_r == expected_next,
                  "accepted sequential snapshot and current_pc diverged");
        end
    endtask

    task automatic scenario_cold_miss_fetches_sequential;
        logic [31:0] seq_target;
        begin
            drive_defaults();
            seq_target = BASE + 32'd8;
            abtb_bank1_hit = 1'b0;
            reset_dut();

            accept_sequential_and_check(seq_target);
            check(!dut.f0_final_taken
                  && dut.f0_final_next_pc == seq_target,
                  "ABTB cold miss changed canonical sequential result");
            pass_case("cold miss fetches sequentially");
        end
    endtask

    task automatic scenario_bank1_abtb_selected_under_stall;
        logic [31:0] bank1_abtb_pred_target;
        logic [31:0] held_pc;
        logic held_s1_source;
        begin
            drive_defaults();
            id_allowin = 1'b0;
            bank1_abtb_pred_target = BASE + 32'h80;
            abtb_bank1_final_pred_target = bank1_abtb_pred_target;
            reset_dut();

            accept_taken_and_check(1'b1, 1'b1, bank1_abtb_pred_target);
            check(dut.f0_final_taken
                  && dut.f0_final_source_abtb
                  && dut.f0_final_bank
                  && dut.f0_final_next_pc == bank1_abtb_pred_target,
                  "bank1 ABTB steering was not selected");
            @(posedge clk);
            #1;
            check(if_valid && !if_pred_taken && !if_pred_source_abtb
                  && if_s1_valid && if_s1_pred_taken
                  && if_s1_pred_source_abtb
                  && if_s1_pred_target == bank1_abtb_pred_target,
                  "bank1 ABTB metadata was bound to the wrong FQ slot");

            // Stop creating new ABTB events, then wait until the blocked FQ
            // consumes all remaining credits and any accepted F0 request has
            // drained before checking the actual hold interval.
            abtb_bank0_hit = 1'b0;
            abtb_bank0_pred_taken = 1'b0;
            abtb_bank1_hit = 1'b0;
            abtb_bank1_pred_taken = 1'b0;
            while (dut.bp0_fire || dut.f0_valid_r || dut.redirect_valid)
                @(posedge clk);
            #1;
            held_pc = current_pc;
            held_s1_source = if_s1_pred_source_abtb;
            repeat (3) begin
                @(posedge clk);
                #1;
                check(current_pc == held_pc
                      && if_s1_pred_source_abtb == held_s1_source,
                      "frontend stall changed canonical PC or FQ metadata");
            end
            pass_case("bank1 ABTB remains canonical under stall");
        end
    endtask

    task automatic scenario_first_abtb_direct_priority;
        logic [31:0] abtb_target;
        begin
            drive_defaults();
            abtb_target = BASE + 32'hc0;
            abtb_bank0_hit = 1'b1;
            abtb_bank0_cfi_type = TYPE_JAL;
            abtb_bank0_abtb_pred_target = abtb_target;
            // Direct direction is intrinsic to JAL/CALL. Keep the shadow
            // direction result low to prove it cannot gate canonical steering.
            abtb_bank0_pred_taken = 1'b0;
            abtb_bank0_final_pred_target = abtb_target;
            reset_dut();

            accept_taken_and_check(1'b1, 1'b0, abtb_target);
            check(dut.f0_final_source_abtb
                  && dut.f0_final_bank == 1'b0
                  && dut.f0_final_next_pc == abtb_target,
                  "first ABTB direct was not canonical");
            pass_case("first ABTB direct is canonical");
        end
    endtask

    task automatic scenario_ex_redirect_priority;
        logic [31:0] ex_target;
        begin
            drive_defaults();
            ex_target = BASE + 32'h140;
            reset_dut();

            ex_redirect_valid = 1'b1;
            ex_redirect_target = ex_target;
            #1;
            check(dut.redirect_valid
                  && dut.redirect_target == ex_target
                  && !dut.bp0_fire,
                  "EX redirect did not override Stage-1 steering");
            @(posedge clk);
            #1;
            check(current_pc == ex_target && dut.fq_count == 0,
                  "EX redirect did not flush FQ and update current_pc");
            ex_redirect_valid = 1'b0;
            pass_case("EX redirect has priority over Stage-1 steering");
        end
    endtask

    task automatic scenario_branch_owned_taken;
        logic [31:0] branch_target;
        begin
            drive_defaults();
            branch_target = BASE + 32'h60;
            irom_data = {32'h0000_0013, 32'h0000_0063};
            abtb_bank0_hit = 1'b1;
            abtb_bank0_cfi_type = TYPE_BRANCH;
            abtb_bank0_abtb_pred_target = branch_target;
            abtb_bank0_pred_taken = 1'b1;
            abtb_bank0_final_pred_target = branch_target;
            reset_dut();

            accept_taken_and_check(1'b1, 1'b0, branch_target);
            check(dut.f0_slot0_stage1_branch_owned,
                  "owned taken branch lost Stage-1 ownership");
            @(posedge clk);
            #1;
            check(if_valid && if_pred_taken && if_pred_source_abtb
                  && if_stage1_branch_owned
                  && if_pred_target == branch_target
                  && !if_s1_valid,
                  "owned taken branch metadata or slot kill was incorrect");
            pass_case("owned taken branch kills slot1");
        end
    endtask

    task automatic scenario_branch_owned_nt_then_bank1;
        logic [31:0] bank1_abtb_pred_target;
        begin
            drive_defaults();
            bank1_abtb_pred_target = BASE + 32'h80;
            irom_data = {32'h0000_0013, 32'h0000_0063};
            abtb_bank0_hit = 1'b1;
            abtb_bank0_cfi_type = TYPE_BRANCH;
            abtb_bank0_abtb_pred_target = BASE + 32'h40;
            abtb_bank0_pred_taken = 1'b0;
            abtb_bank0_final_pred_target = BASE + 32'h40;
            reset_dut();

            accept_taken_and_check(1'b1, 1'b1, bank1_abtb_pred_target);
            check(dut.f0_slot0_stage1_branch_owned,
                  "owned not-taken branch lost Stage-1 ownership");
            @(posedge clk);
            #1;
            check(if_valid && !if_pred_taken && !if_pred_source_abtb
                  && if_stage1_branch_owned
                  && if_s1_valid && if_s1_pred_taken
                  && if_s1_pred_source_abtb
                  && !if_s1_stage1_branch_owned
                  && if_s1_pred_target == bank1_abtb_pred_target,
                  "owned branch NT did not expose younger bank1 direct metadata");
            pass_case("owned branch NT continues to younger bank1 direct");
        end
    endtask

    task automatic scenario_dual_branch_owned_nt;
        begin
            drive_defaults();
            irom_data = {32'h0000_0063, 32'h0000_0063};
            abtb_bank0_hit = 1'b1;
            abtb_bank0_cfi_type = TYPE_BRANCH;
            abtb_bank0_abtb_pred_target = BASE + 32'h40;
            abtb_bank0_pred_taken = 1'b0;
            abtb_bank1_hit = 1'b1;
            abtb_bank1_cfi_type = TYPE_BRANCH;
            abtb_bank1_abtb_pred_target = BASE + 32'h80;
            abtb_bank1_pred_taken = 1'b0;
            reset_dut();

            #1;
            check(stage1_steer_valid
                  && !stage1_steer_taken
                  && !stage1_steer_source_abtb
                  && stage1_steer_next_pc == BASE + 32'd8,
                  "dual owned NT branches did not choose sequential PC");
            @(posedge clk);
            #1;
            check(current_pc == BASE + 32'd8
                  && dut.f0_slot0_stage1_branch_owned
                  && dut.f0_slot1_stage1_branch_owned,
                  "dual branch ownership was not captured with canonical PC");
            @(posedge clk);
            #1;
            check(if_valid && !if_pred_taken && if_stage1_branch_owned
                  && !if_s1_pred_taken && if_s1_stage1_branch_owned,
                  "dual owned NT metadata was not bound to both FQ entries");
            pass_case("dual owned NT branches retain per-slot ownership");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        case_count = 0;
        drive_defaults();

        scenario_cold_miss_fetches_sequential();
        scenario_bank1_abtb_selected_under_stall();
        scenario_first_abtb_direct_priority();
        scenario_ex_redirect_priority();

        scenario_branch_owned_taken();
        scenario_branch_owned_nt_then_bank1();
        scenario_dual_branch_owned_nt();
        check(case_count == 7, "canonical branch TB did not run all scenarios");
        $display("[PASS] frontend FTQ canonical steering test (%0d cases)",
                 case_count);
        $finish;
    end

endmodule
