`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_frontend_abtb
// Description: Directed functional test for the standalone dual-bank ABTB.
// ============================================================

module tb_frontend_abtb;

    localparam logic [1:0] TYPE_JAL    = 2'b00;
    localparam logic [1:0] TYPE_CALL   = 2'b01;
    localparam logic [1:0] TYPE_BRANCH = 2'b10;
    localparam logic [1:0] TYPE_RET    = 2'b11;

    logic clk;
    logic rst_n;
    logic lookup_valid;
    logic [31:0] predict_pc;
    logic bank0_branch_taken;
    logic bank1_branch_taken;
    logic bank0_ret_valid;
    logic [31:0] bank0_ret_target;
    logic bank1_ret_valid;
    logic [31:0] bank1_ret_target;

    logic bank0_eligible;
    logic bank0_hit;
    logic bank0_way;
    logic [1:0] bank0_cfi_type;
    logic [31:0] bank0_abtb_pred_target;
    logic bank0_pred_taken;
    logic [31:0] bank0_final_pred_target;
    logic bank1_eligible;
    logic bank1_hit;
    logic bank1_way;
    logic [1:0] bank1_cfi_type;
    logic [31:0] bank1_abtb_pred_target;
    logic bank1_pred_taken;
    logic [31:0] bank1_final_pred_target;
    logic pred_taken;
    logic pred_bank;
    logic [1:0] pred_cfi_type;
    logic [31:0] pred_target;
    logic [31:0] pred_next_pc;

    logic update_valid;
    logic update_hit;
    logic update_way;
    logic [31:0] update_pc;
    logic [1:0] update_cfi_type;
    logic [31:0] update_target;
    logic conflict_way0;
    logic conflict_way1;

    frontend_abtb u_dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .lookup_valid         (lookup_valid),
        .predict_pc           (predict_pc),
        .bank0_branch_taken   (bank0_branch_taken),
        .bank1_branch_taken   (bank1_branch_taken),
        .bank0_ret_valid      (bank0_ret_valid),
        .bank0_ret_target     (bank0_ret_target),
        .bank1_ret_valid      (bank1_ret_valid),
        .bank1_ret_target     (bank1_ret_target),
        .bank0_eligible       (bank0_eligible),
        .bank0_hit            (bank0_hit),
        .bank0_way            (bank0_way),
        .bank0_cfi_type       (bank0_cfi_type),
        .bank0_abtb_pred_target         (bank0_abtb_pred_target),
        .bank0_pred_taken     (bank0_pred_taken),
        .bank0_final_pred_target    (bank0_final_pred_target),
        .bank1_eligible       (bank1_eligible),
        .bank1_hit            (bank1_hit),
        .bank1_way            (bank1_way),
        .bank1_cfi_type       (bank1_cfi_type),
        .bank1_abtb_pred_target         (bank1_abtb_pred_target),
        .bank1_pred_taken     (bank1_pred_taken),
        .bank1_final_pred_target    (bank1_final_pred_target),
        .pred_taken           (pred_taken),
        .pred_bank            (pred_bank),
        .pred_cfi_type        (pred_cfi_type),
        .pred_target          (pred_target),
        .pred_next_pc         (pred_next_pc),
        .update_valid         (update_valid),
        .update_hit           (update_hit),
        .update_way           (update_way),
        .update_pc            (update_pc),
        .update_cfi_type      (update_cfi_type),
        .update_target        (update_target)
    );

    always #5 clk = ~clk;

    task automatic fail(input string message);
        begin
            $fatal(1, "[FAIL] %s", message);
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            if (!condition)
                fail(message);
        end
    endtask

    task automatic train_miss(
        input logic [31:0] pc,
        input logic [1:0] cfi_type,
        input logic [31:0] target
    );
        begin
            @(negedge clk);
            update_valid = 1'b1;
            update_hit = 1'b0;
            update_way = 1'b0;
            update_pc = pc;
            update_cfi_type = cfi_type;
            update_target = target;
            @(posedge clk);
            @(negedge clk);
            update_valid = 1'b0;
        end
    endtask

    task automatic train_hit(
        input logic [31:0] pc,
        input logic hit_way,
        input logic [1:0] cfi_type,
        input logic [31:0] target
    );
        begin
            @(negedge clk);
            update_valid = 1'b1;
            update_hit = 1'b1;
            update_way = hit_way;
            update_pc = pc;
            update_cfi_type = cfi_type;
            update_target = target;
            @(posedge clk);
            @(negedge clk);
            update_valid = 1'b0;
        end
    endtask

    task automatic lookup(input logic [31:0] pc);
        begin
            @(negedge clk);
            predict_pc = pc;
            lookup_valid = 1'b1;
            #1;
        end
    endtask

    task automatic check_way_candidates(
        input logic [31:0] pc,
        input logic expected_bank,
        input logic expected_way
    );
        begin
            bank0_branch_taken = 1'b0;
            bank1_branch_taken = 1'b0;
            bank0_ret_valid = 1'b0;
            bank1_ret_valid = 1'b0;

            train_hit(pc, expected_way, TYPE_JAL, 32'h8000_3100);
            lookup(pc);
            if (!expected_bank) begin
                check(bank0_hit && bank0_way == expected_way,
                      "bank0 JAL candidate selected the wrong way");
                check(bank0_cfi_type == TYPE_JAL
                      && bank0_abtb_pred_target == 32'h8000_3100
                      && bank0_pred_taken
                      && bank0_final_pred_target == 32'h8000_3100,
                      "bank0 JAL candidate behavior mismatch");
            end else begin
                check(bank1_hit && bank1_way == expected_way,
                      "bank1 JAL candidate selected the wrong way");
                check(bank1_cfi_type == TYPE_JAL
                      && bank1_abtb_pred_target == 32'h8000_3100
                      && bank1_pred_taken
                      && bank1_final_pred_target == 32'h8000_3100,
                      "bank1 JAL candidate behavior mismatch");
            end

            train_hit(pc, expected_way, TYPE_CALL, 32'h8000_3200);
            lookup(pc);
            if (!expected_bank)
                check(bank0_cfi_type == TYPE_CALL
                      && bank0_pred_taken
                      && bank0_final_pred_target == 32'h8000_3200,
                      "bank0 CALL candidate behavior mismatch");
            else
                check(bank1_cfi_type == TYPE_CALL
                      && bank1_pred_taken
                      && bank1_final_pred_target == 32'h8000_3200,
                      "bank1 CALL candidate behavior mismatch");

            train_hit(pc, expected_way, TYPE_BRANCH, 32'h8000_3300);
            if (!expected_bank)
                bank0_branch_taken = 1'b0;
            else
                bank1_branch_taken = 1'b0;
            lookup(pc);
            if (!expected_bank) begin
                check(!bank0_pred_taken
                      && bank0_final_pred_target == 32'h8000_3300,
                      "bank0 not-taken BRANCH candidate mismatch");
                bank0_branch_taken = 1'b1;
                #1;
                check(bank0_pred_taken,
                      "bank0 taken BRANCH candidate mismatch");
            end else begin
                check(!bank1_pred_taken
                      && bank1_final_pred_target == 32'h8000_3300,
                      "bank1 not-taken BRANCH candidate mismatch");
                bank1_branch_taken = 1'b1;
                #1;
                check(bank1_pred_taken,
                      "bank1 taken BRANCH candidate mismatch");
            end

            train_hit(pc, expected_way, TYPE_RET, 32'hdead_beef);
            if (!expected_bank) begin
                bank0_ret_valid = 1'b0;
                bank0_ret_target = 32'h8000_3400;
            end else begin
                bank1_ret_valid = 1'b0;
                bank1_ret_target = 32'h8000_3400;
            end
            lookup(pc);
            if (!expected_bank) begin
                check(!bank0_pred_taken
                      && bank0_final_pred_target == 32'h8000_3400,
                      "bank0 invalid RET candidate mismatch");
                bank0_ret_valid = 1'b1;
                #1;
                check(bank0_pred_taken
                      && bank0_final_pred_target == 32'h8000_3400,
                      "bank0 valid RET candidate mismatch");
            end else begin
                check(!bank1_pred_taken
                      && bank1_final_pred_target == 32'h8000_3400,
                      "bank1 invalid RET candidate mismatch");
                bank1_ret_valid = 1'b1;
                #1;
                check(bank1_pred_taken
                      && bank1_final_pred_target == 32'h8000_3400,
                      "bank1 valid RET candidate mismatch");
            end

            bank0_branch_taken = 1'b0;
            bank1_branch_taken = 1'b0;
            bank0_ret_valid = 1'b0;
            bank1_ret_valid = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        lookup_valid = 1'b0;
        predict_pc = 32'd0;
        bank0_branch_taken = 1'b0;
        bank1_branch_taken = 1'b0;
        bank0_ret_valid = 1'b0;
        bank0_ret_target = 32'd0;
        bank1_ret_valid = 1'b0;
        bank1_ret_target = 32'd0;
        update_valid = 1'b0;
        update_hit = 1'b0;
        update_way = 1'b0;
        update_pc = 32'd0;
        update_cfi_type = 2'd0;
        update_target = 32'd0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Cold lookup: both banks miss and the sequential block is selected.
        lookup(32'h8000_0000);
        check(bank0_eligible && bank1_eligible, "both banks must be eligible at slot0");
        check(!bank0_hit && !bank1_hit, "cold ABTB lookup must miss");
        check(!pred_taken && pred_next_pc == 32'h8000_0008,
              "cold lookup must use slot0 sequential next PC");

        // Fill both CFI positions of one fetch block. Both direct CFIs are taken,
        // and program order requires bank0 to win.
        train_miss(32'h8000_0000, TYPE_JAL, 32'h8000_0100);
        train_miss(32'h8000_0004, TYPE_CALL, 32'h8000_0200);
        lookup(32'h8000_0000);
        check(bank0_hit && bank1_hit, "parallel dual-bank lookup did not hit both CFIs");
        check(bank0_cfi_type == TYPE_JAL && bank0_abtb_pred_target == 32'h8000_0100,
              "bank0 metadata mismatch");
        check(bank1_cfi_type == TYPE_CALL && bank1_abtb_pred_target == 32'h8000_0200,
              "bank1 metadata mismatch");
        check(bank0_pred_taken && bank1_pred_taken, "direct CFIs must predict taken");
        check(pred_taken && !pred_bank && pred_target == 32'h8000_0100,
              "bank0 must win when both banks predict taken");

        // Starting from slot1 masks bank0 even though its table entry still exists.
        lookup(32'h8000_0004);
        check(!bank0_eligible && !bank0_hit && !bank0_pred_taken,
              "predict_pc[2] must mask bank0");
        check(bank1_hit && pred_taken && pred_bank
              && pred_target == 32'h8000_0200,
              "slot1 lookup must remain eligible after bank0 masking");

        // Existing-entry update must keep the entry addressable and replace data.
        train_hit(32'h8000_0004, bank1_way,
                  TYPE_BRANCH, 32'h8000_0300);
        bank1_branch_taken = 1'b0;
        lookup(32'h8000_0000);
        check(bank1_hit && bank1_cfi_type == TYPE_BRANCH
              && bank1_abtb_pred_target == 32'h8000_0300,
              "existing bank1 entry update failed");
        check(!bank1_pred_taken, "not-taken branch direction input was ignored");
        check(pred_taken && !pred_bank && pred_target == 32'h8000_0100,
              "older bank0 direct CFI selection changed unexpectedly");

        // A not-taken bank0 branch must not hide a taken bank1 CFI.
        train_hit(32'h8000_0000, bank0_way,
                  TYPE_BRANCH, 32'h8000_0400);
        train_hit(32'h8000_0004, bank1_way,
                  TYPE_JAL, 32'h8000_0500);
        bank0_branch_taken = 1'b0;
        lookup(32'h8000_0000);
        check(bank0_hit && !bank0_pred_taken && bank1_pred_taken,
              "branch direction qualification failed");
        check(pred_taken && pred_bank && pred_target == 32'h8000_0500,
              "taken bank1 CFI must win after a not-taken bank0 branch");

        // When both conditional branches are taken, bank0 still has priority.
        train_hit(32'h8000_0004, bank1_way,
                  TYPE_BRANCH, 32'h8000_0600);
        bank0_branch_taken = 1'b1;
        bank1_branch_taken = 1'b1;
        lookup(32'h8000_0000);
        check(bank0_pred_taken && bank1_pred_taken,
              "both conditional candidates should predict taken");
        check(!pred_bank && pred_target == 32'h8000_0400,
              "bank0 conditional branch did not retain program-order priority");

        // RET classification uses the external uRAS boundary and ignores the
        // stored target for final steering.
        train_hit(32'h8000_0004, bank1_way,
                  TYPE_RET, 32'hdead_beef);
        bank0_branch_taken = 1'b0;
        bank1_ret_valid = 1'b0;
        lookup(32'h8000_0000);
        check(bank1_hit && !bank1_pred_taken, "invalid return target predicted taken");
        bank1_ret_valid = 1'b1;
        bank1_ret_target = 32'h8000_0700;
        #1;
        check(bank1_pred_taken && bank1_final_pred_target == 32'h8000_0700,
              "RET did not use the external uRAS target boundary");

        // Exercise every CFI type in every physical bank/way. Miss allocation
        // uses update_pc[2] directly; there is no external update-bank input.
        train_miss(32'h8000_0008, TYPE_JAL, 32'h8000_3000);
        check_way_candidates(32'h8000_0008, 1'b0, 1'b0);

        train_miss(32'h8000_0010, TYPE_JAL, 32'h8000_3000);
        train_miss(32'h8000_0090, TYPE_JAL, 32'h8000_3000);
        check_way_candidates(32'h8000_0090, 1'b0, 1'b1);

        train_miss(32'h8000_001c, TYPE_JAL, 32'h8000_3000);
        check_way_candidates(32'h8000_001c, 1'b1, 1'b0);

        train_miss(32'h8000_0024, TYPE_JAL, 32'h8000_3000);
        train_miss(32'h8000_00a4, TYPE_JAL, 32'h8000_3000);
        check_way_candidates(32'h8000_00a4, 1'b1, 1'b1);

        // Deliberately create duplicate tags using stale hit metadata. Both
        // ways match, but externally visible metadata and prediction use way0.
        train_miss(32'h8000_0050, TYPE_JAL, 32'h8000_3500);
        train_hit(32'h8000_0050, 1'b1, TYPE_CALL, 32'h8000_3600);
        lookup(32'h8000_0050);
        check(bank0_hit && !bank0_way
              && bank0_cfi_type == TYPE_JAL
              && bank0_abtb_pred_target == 32'h8000_3500
              && bank0_pred_taken
              && bank0_final_pred_target == 32'h8000_3500,
              "duplicate-tag lookup did not preserve way0 priority");

        // Two-way collision/replacement test in an otherwise unused bank0 set.
        // Addresses differ in tag but share set index PC[6:3] = 5.
        train_miss(32'h8000_0028, TYPE_JAL, 32'h8000_1100);
        train_miss(32'h8000_00a8, TYPE_JAL, 32'h8000_1200);

        // Touch the older entry so the other way becomes LRU.
        lookup(32'h8000_0028);
        check(bank0_hit && bank0_abtb_pred_target == 32'h8000_1100,
              "first colliding entry was not retained");
        @(posedge clk);

        train_miss(32'h8000_0128, TYPE_JAL, 32'h8000_1300);

        lookup(32'h8000_00a8);
        check(!bank0_hit, "LRU victim survived a three-tag set collision");
        lookup(32'h8000_0028);
        check(bank0_hit && bank0_abtb_pred_target == 32'h8000_1100,
              "recently used way was incorrectly replaced");
        lookup(32'h8000_0128);
        check(bank0_hit && bank0_abtb_pred_target == 32'h8000_1300,
              "replacement entry was not installed");

        // Repeat replacement in bank1 to verify that its LRU state is
        // independent from bank0. These slot1 PCs share set index 6.
        train_miss(32'h8000_0034, TYPE_CALL, 32'h8000_2100);
        train_miss(32'h8000_00b4, TYPE_CALL, 32'h8000_2200);
        lookup(32'h8000_0034);
        check(bank1_hit && bank1_abtb_pred_target == 32'h8000_2100,
              "first colliding bank1 entry was not retained");
        @(posedge clk);

        train_miss(32'h8000_0134, TYPE_CALL, 32'h8000_2300);
        lookup(32'h8000_00b4);
        check(!bank1_hit, "bank1 LRU victim survived a three-tag set collision");
        lookup(32'h8000_0034);
        check(bank1_hit && bank1_abtb_pred_target == 32'h8000_2100,
              "recently used bank1 way was incorrectly replaced");
        lookup(32'h8000_0134);
        check(bank1_hit && bank1_abtb_pred_target == 32'h8000_2300,
              "bank1 replacement entry was not installed");

        // A same-cycle lookup/update to the same entry observes the old payload
        // before the edge and the newly written payload after the edge.
        train_miss(32'h8000_0038, TYPE_JAL, 32'h8000_3100);
        lookup(32'h8000_0038);
        conflict_way0 = bank0_way;
        @(negedge clk);
        predict_pc = 32'h8000_0038;
        lookup_valid = 1'b1;
        update_valid = 1'b1;
        update_hit = 1'b1;
        update_way = conflict_way0;
        update_pc = 32'h8000_0038;
        update_cfi_type = TYPE_CALL;
        update_target = 32'h8000_3200;
        #1;
        check(bank0_hit && bank0_abtb_pred_target == 32'h8000_3100,
              "same-entry conflict did not expose old payload before edge");
        @(posedge clk);
        #1;
        check(bank0_hit && bank0_cfi_type == TYPE_CALL
              && bank0_abtb_pred_target == 32'h8000_3200,
              "same-entry conflict did not expose updated payload after edge");
        @(negedge clk);
        update_valid = 1'b0;

        // For two different entries in one set, update must win over lookup
        // when both write LRU. The following miss must evict the lookup way,
        // leaving the explicitly updated way resident.
        train_miss(32'h8000_0040, TYPE_JAL, 32'h8000_4100);
        train_miss(32'h8000_00c0, TYPE_JAL, 32'h8000_4200);
        lookup(32'h8000_0040);
        conflict_way0 = bank0_way;
        lookup(32'h8000_00c0);
        conflict_way1 = bank0_way;
        check(conflict_way0 != conflict_way1,
              "same-set conflict setup did not occupy both ways");

        @(negedge clk);
        predict_pc = 32'h8000_0040;
        lookup_valid = 1'b1;
        update_valid = 1'b1;
        update_hit = 1'b1;
        update_way = conflict_way1;
        update_pc = 32'h8000_00c0;
        update_cfi_type = TYPE_CALL;
        update_target = 32'h8000_4300;
        #1;
        check(bank0_hit && bank0_abtb_pred_target == 32'h8000_4100,
              "different-entry conflict lookup selected the wrong entry");
        @(posedge clk);
        @(negedge clk);
        update_valid = 1'b0;
        lookup_valid = 1'b0;

        train_miss(32'h8000_0140, TYPE_JAL, 32'h8000_4400);
        lookup(32'h8000_0040);
        check(!bank0_hit,
              "lookup LRU write incorrectly overrode same-set update priority");
        lookup(32'h8000_00c0);
        check(bank0_hit && bank0_cfi_type == TYPE_CALL
              && bank0_abtb_pred_target == 32'h8000_4300,
              "same-set updated entry was incorrectly replaced");
        lookup(32'h8000_0140);
        check(bank0_hit && bank0_abtb_pred_target == 32'h8000_4400,
              "same-set replacement after conflict was not installed");

        // A younger bank1 hit behind a taken bank0 candidate is not consumed
        // and therefore must not perturb bank1 replacement state.
        train_miss(32'h8000_0048, TYPE_JAL, 32'h8000_5100);
        train_miss(32'h8000_004c, TYPE_CALL, 32'h8000_5200);
        train_miss(32'h8000_00cc, TYPE_CALL, 32'h8000_5300);
        lookup(32'h8000_0048);
        check(bank0_pred_taken && bank1_hit,
              "wrong-path bank1 LRU test did not produce dual hits");
        @(posedge clk);
        @(negedge clk);
        lookup_valid = 1'b0;

        train_miss(32'h8000_014c, TYPE_CALL, 32'h8000_5400);
        lookup(32'h8000_004c);
        check(!bank1_hit,
              "bank1 wrong-path hit incorrectly changed replacement state");
        lookup(32'h8000_00cc);
        check(bank1_hit && bank1_abtb_pred_target == 32'h8000_5300,
              "bank1 resident entry was incorrectly replaced");
        lookup(32'h8000_014c);
        check(bank1_hit && bank1_abtb_pred_target == 32'h8000_5400,
              "bank1 replacement after wrong-path lookup was not installed");

        // Bank independence and lookup_valid qualification.
        lookup_valid = 1'b0;
        #1;
        check(!bank0_eligible && !bank1_eligible && !pred_taken,
              "lookup_valid did not suppress lookup results");
        check(pred_next_pc == 32'h8000_0150,
              "sequential next PC must remain deterministic while lookup is invalid");

        $display("[PASS] frontend_abtb directed test");
        $finish;
    end

endmodule
