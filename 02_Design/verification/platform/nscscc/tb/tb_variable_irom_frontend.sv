`timescale 1ns/1ps

module tb_variable_irom_frontend;
    import cpu_defs::*;

    logic clk;
    logic rst_n;
    logic id_allowin;
    logic redirect_valid;
    logic [31:0] redirect_target;
    logic [11:0] irom_addr;
    logic irom_req_valid;
    logic [31:0] irom_req_addr;
    logic irom_req_ready;
    logic irom_resp_valid;
    logic [63:0] irom_data;
    logic if_valid;
    logic if_ready_go;
    logic if_s1_valid;
    if_id_payload_t if_payload;
    logic [31:0] current_pc;
    integer errors;

    frontend_ftq #(
        .VARIABLE_IROM_LATENCY(1'b1),
        .RESET_PC(32'h1c00_0000)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .id_allowin(id_allowin),
        .ex_redirect_valid(redirect_valid),
        .ex_redirect_target(redirect_target),
        .irom_addr(irom_addr),
        .irom_req_valid(irom_req_valid),
        .irom_req_addr(irom_req_addr),
        .irom_req_ready(irom_req_ready),
        .irom_resp_valid(irom_resp_valid),
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
        .abtb_lookup_accept(),
        .stage1_steer_valid(),
        .stage1_steer_source_abtb(),
        .stage1_steer_branch_owned(),
        .stage1_steer_branch_owned_nt(),
        .stage1_steer_taken(),
        .stage1_steer_bank(),
        .stage1_steer_cfi_type(),
        .stage1_steer_target(),
        .stage1_steer_next_pc(),
        .can_dual_issue(),
        .raw_pair_raw(),
        .predict_dual(),
        .irom_held_valid(),
        .if_skip_out()
    );

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        begin
            if (!condition) begin
                errors = errors + 1;
                $display("[FAIL] %s at %0t", message, $time);
            end
        end
    endtask

    task automatic accept_request(input logic [31:0] expected_addr);
        begin
            wait (irom_req_valid);
            check(irom_req_addr == expected_addr, "IROM request address mismatch");
            @(negedge clk);
            irom_req_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            irom_req_ready = 1'b0;
        end
    endtask

    task automatic return_packet(input logic [63:0] packet);
        begin
            @(negedge clk);
            irom_data = packet;
            irom_resp_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            irom_resp_valid = 1'b0;
        end
    endtask

    task automatic redirect(input logic [31:0] target);
        begin
            @(negedge clk);
            redirect_target = target;
            redirect_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            redirect_valid = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        id_allowin = 1'b0;
        redirect_valid = 1'b0;
        redirect_target = 32'd0;
        irom_req_ready = 1'b0;
        irom_resp_valid = 1'b0;
        irom_data = 64'd0;
        errors = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        check(current_pc == 32'h1c00_0000,
              "NSCSCC reset PC is not the LA32R boot address");
        check(irom_req_valid && irom_req_addr == 32'h1c00_0000,
              "initial AXI IROM request missing");

        accept_request(32'h1c00_0000);
        repeat (4) begin
            @(posedge clk);
            check(!irom_req_valid,
                  "frontend issued a second request while one was outstanding");
            check(!if_valid, "frontend consumed instruction data before response");
        end

        return_packet(64'h0340_0000_0280_0021);
        #1;
        check(if_valid, "frontend did not enqueue delayed IROM response");
        check(if_payload.pc == 32'h1c00_0000,
              "delayed response lost its request PC");
        check(if_payload.slot0.inst == 32'h0280_0021,
              "delayed response slot 0 mismatch");
        check(if_payload.slot1.inst == 32'h0340_0000,
              "delayed response slot 1 mismatch");

        // Flush the queued packet, accept a request at 0x40, then redirect it
        // while outstanding.  Its stale response must not enter the FQ.
        redirect(32'h1c00_0040);
        accept_request(32'h1c00_0040);
        redirect(32'h1c00_0080);
        return_packet(64'h1111_1111_2222_2222);
        #1;
        check(!if_valid, "stale pre-redirect IROM response was not dropped");

        accept_request(32'h1c00_0080);
        return_packet(64'h0340_0000_0280_0042);
        #1;
        check(if_valid && if_payload.pc == 32'h1c00_0080,
              "redirect target response did not reach the FQ");
        check(if_payload.slot0.inst == 32'h0280_0042,
              "redirect target instruction mismatch");

        if (errors == 0)
            $display("[PASS] NSCSCC variable-latency IROM frontend test");
        else
            $display("[FAIL] NSCSCC variable-latency IROM errors=%0d", errors);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "[FAIL] variable-latency IROM frontend timeout");
    end

endmodule
