`timescale 1ns/1ps

module tb_frontend_stage1_direction;

    localparam logic [31:0] BASE = 32'h8000_0000;

    logic clk;
    logic rst_n;
    logic [31:0] predict_pc;
    logic [7:0] lookup_ghr;
    logic [7:0] bank0_index;
    logic [1:0] bank0_counter;
    logic bank0_taken;
    logic [7:0] bank1_index;
    logic [1:0] bank1_counter;
    logic bank1_taken;
    logic update_valid;
    logic [7:0] update_index;
    logic [1:0] update_counter;
    logic update_actual_taken;
    logic [7:0] committed_ghr;
    logic [31:0] expected_bank0_pc;
    logic [31:0] expected_bank1_pc;
    integer case_count;

    frontend_stage1_direction dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .predict_pc          (predict_pc),
        .lookup_ghr          (lookup_ghr),
        .bank0_index         (bank0_index),
        .bank0_counter       (bank0_counter),
        .bank0_taken         (bank0_taken),
        .bank1_index         (bank1_index),
        .bank1_counter       (bank1_counter),
        .bank1_taken         (bank1_taken),
        .update_valid        (update_valid),
        .update_index        (update_index),
        .update_counter      (update_counter),
        .update_actual_taken (update_actual_taken),
        .committed_ghr       (committed_ghr)
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

    task automatic select_index(
        input logic [7:0] index,
        output logic use_bank1
    );
        logic [7:0] pc_hash;
        begin
            pc_hash = index ^ committed_ghr;
            predict_pc = BASE | {22'd0, pc_hash[7:1], 3'b000};
            use_bank1 = pc_hash[0];
            #1;
            check((use_bank1 ? bank1_index : bank0_index) == index,
                  "lookup PC did not reproduce requested PHT index");
        end
    endtask

    task automatic check_counter_at(
        input logic [7:0] index,
        input logic [1:0] expected
    );
        logic use_bank1;
        begin
            select_index(index, use_bank1);
            check((use_bank1 ? bank1_counter : bank0_counter) == expected,
                  $sformatf("PHT counter mismatch index=%02x", index));
        end
    endtask

    task automatic confirmed_update(
        input logic [7:0] index,
        input logic [1:0] snapshot,
        input logic actual_taken,
        input logic [1:0] expected_counter,
        input logic [7:0] expected_ghr
    );
        begin
            @(negedge clk);
            update_valid = 1'b1;
            update_index = index;
            update_counter = snapshot;
            update_actual_taken = actual_taken;
            @(posedge clk);
            #1;
            update_valid = 1'b0;
            check(committed_ghr == expected_ghr,
                  "confirmed update produced wrong committed GHR");
            check_counter_at(index, expected_counter);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        predict_pc = BASE;
        update_valid = 1'b0;
        update_index = 8'd0;
        update_counter = 2'b01;
        update_actual_taken = 1'b0;
        case_count = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        #1;

        check(committed_ghr == 8'd0
              && lookup_ghr == 8'd0
              && bank0_counter == 2'b01
              && bank1_counter == 2'b01,
              "reset state is not weakly-not-taken with zero GHR");
        pass_case("reset initializes GHR and all observed counters");

        predict_pc = BASE + 32'h120;
        expected_bank0_pc = {predict_pc[31:3], 3'b000};
        expected_bank1_pc = expected_bank0_pc + 32'd4;
        #1;
        check(bank0_index == (expected_bank0_pc[9:2] ^ 8'd0),
              "bank0 index formula mismatch");
        check(bank1_index == (expected_bank1_pc[9:2] ^ 8'd0),
              "bank1 index formula mismatch");
        check(bank0_index != bank1_index,
              "parallel bank indices unexpectedly collapsed");
        pass_case("bank0 and bank1 use independent PC/GHR hashes");

        confirmed_update(8'h40, 2'b01, 1'b1, 2'b10, 8'h01);
        confirmed_update(8'h40, 2'b10, 1'b1, 2'b11, 8'h03);
        confirmed_update(8'h40, 2'b11, 1'b1, 2'b11, 8'h07);
        pass_case("taken updates saturate at strongly-taken");

        confirmed_update(8'h40, 2'b11, 1'b0, 2'b10, 8'h0e);
        confirmed_update(8'h40, 2'b10, 1'b0, 2'b01, 8'h1c);
        confirmed_update(8'h40, 2'b01, 1'b0, 2'b00, 8'h38);
        confirmed_update(8'h40, 2'b00, 1'b0, 2'b00, 8'h70);
        pass_case("not-taken updates saturate at strongly-not-taken");
        pass_case("taken and not-taken outcomes shift committed GHR");

        @(negedge clk);
        update_valid = 1'b0;
        update_actual_taken = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        check(committed_ghr == 8'h70,
              "non-confirmed redirect/stall-like cycles changed GHR");
        pass_case("cycles without confirmed update do not recover or shift GHR");

        check_counter_at(8'h40, 2'b00);
        @(negedge clk);
        update_valid = 1'b1;
        update_index = 8'h40;
        update_counter = 2'b00;
        update_actual_taken = 1'b1;
        #1;
        check_counter_at(8'h40, 2'b00);
        @(posedge clk);
        #1;
        update_valid = 1'b0;
        check_counter_at(8'h40, 2'b01);
        pass_case("PHT write is visible only after the update edge");

        check_counter_at(8'ha4, 2'b01);
        confirmed_update(8'ha4, 2'b01, 1'b1, 2'b10,
                         {committed_ghr[6:0], 1'b1});
        check_counter_at(8'ha4, 2'b10);
        pass_case("different PC/GHR combinations alias through one 8-bit index");

        // Two in-flight branches may have captured the same old counter. The
        // current one-port policy applies each snapshot independently, so the
        // second update can overwrite rather than accumulate the first.
        check_counter_at(8'hb5, 2'b01);
        confirmed_update(8'hb5, 2'b01, 1'b1, 2'b10,
                         {committed_ghr[6:0], 1'b1});
        confirmed_update(8'hb5, 2'b01, 1'b1, 2'b10,
                         {committed_ghr[6:0], 1'b1});
        pass_case("same-row in-flight snapshots document lost-update risk");

        check(case_count == 9, "direction TB did not run all cases");
        $display("[PASS] frontend Stage-1 direction directed test (%0d cases)",
                 case_count);
        $finish;
    end

endmodule
