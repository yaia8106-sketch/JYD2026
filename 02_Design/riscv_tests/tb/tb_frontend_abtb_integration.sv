`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_frontend_abtb_integration
// Description: Real cpu_top instruction-flow test for shadow ABTB metadata.
// ============================================================

module tb_frontend_abtb_integration;

    localparam logic [31:0] BASE        = 32'h8000_0000;
    localparam logic [31:0] NOP         = 32'h0000_0013;
    localparam logic [1:0]  TYPE_JAL    = 2'b00;
    localparam logic [1:0]  TYPE_CALL   = 2'b01;
    localparam logic [1:0]  TYPE_BRANCH = 2'b10;
    localparam logic [1:0]  TYPE_RET    = 2'b11;
    localparam integer      FQ_DEPTH    = 8;
    localparam integer      FQ_PTR_W    = $clog2(FQ_DEPTH);
    localparam integer      FQ_ROWS     = FQ_DEPTH / 2;
    localparam integer      JAL_INDEX          = 32;
    localparam integer      CALL_BLOCK_INDEX   = 48;
    localparam integer      TAKEN_BRANCH_INDEX = 64;
    localparam integer      NOT_TAKEN_INDEX    = 80;
    localparam integer      RET_BASE_INDEX     = 96;
    localparam integer      JALR_BASE_INDEX    = 112;

    logic clk;
    logic rst_n;
    logic [11:0] irom_addr;
    logic [63:0] irom_data;
    logic cache_req;
    logic cache_wr;
    logic [31:0] cache_addr;
    logic [3:0] cache_wea;
    logic [31:0] cache_wdata;
    logic [31:0] cache_rdata;
    logic cache_ready;
    logic cache_flush;
    logic cache_pipeline_stall;
    logic [31:0] mmio_addr;
    logic [31:0] mmio_wr_addr;
    logic [3:0] mmio_wea;
    logic [31:0] mmio_wdata;
    logic [31:0] mmio_rdata;
    logic timer_irq_pending;

    logic [31:0] irom [0:8191];
    logic [63:0] irom_data_r;
    integer i;

    logic wrong_path_watch;
    logic [31:0] wrong_path_pc;
    integer slot1_sidecar_kill_checks;
    integer slot1_sidecar_kill_stall_checks;
    integer slot1_sidecar_kill_wrap_checks;
    integer slot1_sidecar_kill_redirect_checks;
    integer slot1_sidecar_kill_jal_checks;
    integer slot1_sidecar_kill_jalr_checks;
    integer slot1_sidecar_kill_branch_checks;
    integer sidecar_head_even_checks;
    integer sidecar_head_odd_checks;
    integer sidecar_single_dequeue_checks;
    integer sidecar_dual_dequeue_checks;
    integer sidecar_stall_checks;
    integer sidecar_redirect_hidden_checks;
    integer sidecar_refetch_checks;
    integer sidecar_update_token_checks;
    integer ref_i;

    logic ref_even_hit [0:FQ_ROWS-1];
    logic ref_even_way [0:FQ_ROWS-1];
    logic ref_odd_hit [0:FQ_ROWS-1];
    logic ref_odd_way [0:FQ_ROWS-1];
    logic ref_entry_valid [0:FQ_DEPTH-1];
    logic [31:0] ref_entry_token [0:FQ_DEPTH-1];
    logic [31:0] ref_next_token;

    logic ref_id_valid;
    logic ref_id_s1_valid;
    logic [31:0] ref_id_token;
    logic [31:0] ref_id_s1_token;
    logic ref_id_hit;
    logic ref_id_way;
    logic ref_id_s1_hit;
    logic ref_id_s1_way;

    logic ref_ex_valid;
    logic ref_ex_s1_valid;
    logic [31:0] ref_ex_token;
    logic [31:0] ref_ex_s1_token;
    logic ref_ex_hit;
    logic ref_ex_way;
    logic ref_ex_s1_hit;
    logic ref_ex_s1_way;

    logic sidecar_stall_active;
    logic [FQ_PTR_W-1:0] sidecar_stall_head;
    logic [31:0] sidecar_stall_token;
    logic sidecar_stall_hit;
    logic sidecar_stall_way;
    logic redirect_clear_observe;
    logic killed_pc_refetch_pending;
    logic [31:0] killed_pc_for_coverage;

    cpu_top dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .irom_addr            (irom_addr),
        .irom_data            (irom_data),
        .cache_req            (cache_req),
        .cache_wr             (cache_wr),
        .cache_addr           (cache_addr),
        .cache_wea            (cache_wea),
        .cache_wdata          (cache_wdata),
        .cache_rdata          (cache_rdata),
        .cache_ready          (cache_ready),
        .cache_flush          (cache_flush),
        .cache_pipeline_stall (cache_pipeline_stall),
        .mmio_addr            (mmio_addr),
        .mmio_wr_addr         (mmio_wr_addr),
        .mmio_wea             (mmio_wea),
        .mmio_wdata           (mmio_wdata),
        .mmio_rdata           (mmio_rdata),
        .timer_irq_pending    (timer_irq_pending)
    );

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        irom_data_r <= {
            irom[{irom_addr, 1'b1}],
            irom[{irom_addr, 1'b0}]
        };
    end

    assign irom_data = irom_data_r;

    function automatic logic [31:0] enc_addi(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_addi = {imm[11:0], rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] enc_auipc(
        input logic [4:0] rd,
        input logic [19:0] imm20
    );
        enc_auipc = {imm20, rd, 7'b0010111};
    endfunction

    function automatic logic [31:0] enc_jal(
        input logic [4:0] rd,
        input integer imm
    );
        logic [20:0] off;
        begin
            off = imm[20:0];
            enc_jal = {
                off[20],
                off[10:1],
                off[11],
                off[19:12],
                rd,
                7'b1101111
            };
        end
    endfunction

    function automatic logic [31:0] enc_jalr(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_jalr = {imm[11:0], rs1, 3'b000, rd, 7'b1100111};
    endfunction

    function automatic logic [31:0] enc_branch(
        input logic [2:0] funct3,
        input logic [4:0] rs1,
        input logic [4:0] rs2,
        input integer imm
    );
        logic [12:0] off;
        begin
            off = imm[12:0];
            enc_branch = {
                off[12],
                off[10:5],
                rs2,
                rs1,
                funct3,
                off[4:1],
                off[11],
                7'b1100011
            };
        end
    endfunction

    task automatic fail(input string message);
        $fatal(1, "[FAIL] %s", message);
    endtask

    task automatic check(input logic condition, input string message);
        if (!condition)
            fail(message);
    endtask

    task automatic clear_program;
        begin
            for (i = 0; i < 8192; i = i + 1)
                irom[i] = NOP;
        end
    endtask

    task automatic reset_cpu;
        begin
            cache_ready = 1'b1;
            wrong_path_watch = 1'b0;
            rst_n = 1'b0;
            repeat (4) begin
                @(negedge clk);
                check(!dut.abtb_update_valid,
                      "reset or invalid pipeline state attempted an ABTB update");
            end
            check(dut.abtb_lookup_block_count == 32'd0
                  && dut.abtb_ex_update_count == 32'd0,
                  "shadow observation counters did not reset");
            rst_n = 1'b1;
        end
    endtask

    function automatic logic ref_hit_for_entry(
        input logic [FQ_PTR_W-1:0] entry
    );
        ref_hit_for_entry =
            entry[0] ? ref_odd_hit[entry[FQ_PTR_W-1:1]]
                     : ref_even_hit[entry[FQ_PTR_W-1:1]];
    endfunction

    function automatic logic ref_way_for_entry(
        input logic [FQ_PTR_W-1:0] entry
    );
        ref_way_for_entry =
            entry[0] ? ref_odd_way[entry[FQ_PTR_W-1:1]]
                     : ref_even_way[entry[FQ_PTR_W-1:1]];
    endfunction

    function automatic logic [FQ_PTR_W-1:0] ref_entry_next(
        input logic [FQ_PTR_W-1:0] entry
    );
        ref_entry_next = entry + 1'b1;
    endfunction

    function automatic logic [FQ_PTR_W-2:0] ref_row_for_entry(
        input logic [FQ_PTR_W-1:0] entry
    );
        ref_row_for_entry = entry[FQ_PTR_W-1:1];
    endfunction

    function automatic logic ref_slot0_src_hit;
        ref_slot0_src_hit = dut.u_frontend_ftq.f0_start_pc_r[2]
                          ? dut.u_frontend_ftq.f0_abtb_bank1_hit_r
                          : dut.u_frontend_ftq.f0_abtb_bank0_hit_r;
    endfunction

    function automatic logic ref_slot0_src_way;
        ref_slot0_src_way = dut.u_frontend_ftq.f0_start_pc_r[2]
                          ? dut.u_frontend_ftq.f0_abtb_bank1_way_r
                          : dut.u_frontend_ftq.f0_abtb_bank0_way_r;
    endfunction

    function automatic logic [1:0] ref_slot0_src_type;
        ref_slot0_src_type = dut.u_frontend_ftq.f0_start_pc_r[2]
                           ? dut.u_frontend_ftq.f0_abtb_bank1_cfi_type_r
                           : dut.u_frontend_ftq.f0_abtb_bank0_cfi_type_r;
    endfunction

    function automatic logic [31:0] ref_slot0_src_target;
        ref_slot0_src_target = dut.u_frontend_ftq.f0_start_pc_r[2]
                             ? dut.u_frontend_ftq.f0_abtb_bank1_target_r
                             : dut.u_frontend_ftq.f0_abtb_bank0_target_r;
    endfunction

    function automatic logic ref_slot0_src_pred_taken;
        ref_slot0_src_pred_taken = dut.u_frontend_ftq.f0_start_pc_r[2]
                                 ? dut.u_frontend_ftq.f0_abtb_bank1_pred_taken_r
                                 : dut.u_frontend_ftq.f0_abtb_bank0_pred_taken_r;
    endfunction

    function automatic logic [31:0] ref_slot0_src_pred_target;
        ref_slot0_src_pred_target = dut.u_frontend_ftq.f0_start_pc_r[2]
                                  ? dut.u_frontend_ftq.f0_abtb_bank1_pred_target_r
                                  : dut.u_frontend_ftq.f0_abtb_bank0_pred_target_r;
    endfunction

    task automatic ref_write_entry_payload(
        input logic [FQ_PTR_W-1:0] entry,
        input logic       hit,
        input logic       way
    );
        begin
            if (entry[0]) begin
                ref_odd_hit[ref_row_for_entry(entry)] <= hit;
                ref_odd_way[ref_row_for_entry(entry)] <= way;
            end else begin
                ref_even_hit[ref_row_for_entry(entry)] <= hit;
                ref_even_way[ref_row_for_entry(entry)] <= way;
            end
        end
    endtask

    task automatic check_write_data_matches(
        input logic is_even_bank,
        input logic from_slot1
    );
        logic exp_hit;
        logic exp_way;
        logic [1:0] exp_type;
        logic [31:0] exp_target;
        logic exp_pred_taken;
        logic [31:0] exp_pred_target;
        begin
            exp_hit = from_slot1 ? dut.u_frontend_ftq.f0_abtb_bank1_hit_r
                                 : ref_slot0_src_hit();
            exp_way = from_slot1 ? dut.u_frontend_ftq.f0_abtb_bank1_way_r
                                 : ref_slot0_src_way();
            exp_type = from_slot1 ? dut.u_frontend_ftq.f0_abtb_bank1_cfi_type_r
                                  : ref_slot0_src_type();
            exp_target = from_slot1 ? dut.u_frontend_ftq.f0_abtb_bank1_target_r
                                    : ref_slot0_src_target();
            exp_pred_taken =
                from_slot1 ? dut.u_frontend_ftq.f0_abtb_bank1_pred_taken_r
                           : ref_slot0_src_pred_taken();
            exp_pred_target =
                from_slot1 ? dut.u_frontend_ftq.f0_abtb_bank1_pred_target_r
                           : ref_slot0_src_pred_target();

            if (is_even_bank) begin
                check(dut.u_frontend_ftq.fq_abtb_even_write_data.hit
                      == exp_hit
                      && dut.u_frontend_ftq.fq_abtb_even_write_data.way
                         == exp_way
                      && dut.u_frontend_ftq.fq_abtb_even_write_data.cfi_type
                         == exp_type
                      && dut.u_frontend_ftq.fq_abtb_even_write_data.target
                         == exp_target
                      && dut.u_frontend_ftq.fq_abtb_even_write_data.pred_taken
                         == exp_pred_taken
                      && dut.u_frontend_ftq.fq_abtb_even_write_data.pred_target
                         == exp_pred_target,
                      "even sidecar write data mismatch");
            end else begin
                check(dut.u_frontend_ftq.fq_abtb_odd_write_data.hit
                      == exp_hit
                      && dut.u_frontend_ftq.fq_abtb_odd_write_data.way
                         == exp_way
                      && dut.u_frontend_ftq.fq_abtb_odd_write_data.cfi_type
                         == exp_type
                      && dut.u_frontend_ftq.fq_abtb_odd_write_data.target
                         == exp_target
                      && dut.u_frontend_ftq.fq_abtb_odd_write_data.pred_taken
                         == exp_pred_taken
                      && dut.u_frontend_ftq.fq_abtb_odd_write_data.pred_target
                         == exp_pred_target,
                      "odd sidecar write data mismatch");
            end
        end
    endtask

    task automatic check_sidecar_write_edge;
        logic [FQ_PTR_W-1:0] entry0;
        logic [FQ_PTR_W-1:0] entry1;
        logic exp_even_write;
        logic exp_odd_write;
        logic exp_even_from_slot1;
        logic exp_odd_from_slot1;
        logic [FQ_PTR_W-2:0] exp_even_row;
        logic [FQ_PTR_W-2:0] exp_odd_row;
        begin
            entry0 = dut.u_frontend_ftq.fq_tail;
            entry1 = ref_entry_next(entry0);

            check(dut.u_frontend_ftq.fq_tail_p1 == entry1,
                  "DUT fq_tail_p1 does not equal old tail + 1");

            exp_even_write =
                (dut.u_frontend_ftq.f0_enq0_valid && !entry0[0])
                || (dut.u_frontend_ftq.f0_enq1_valid && !entry1[0]);
            exp_odd_write =
                (dut.u_frontend_ftq.f0_enq0_valid && entry0[0])
                || (dut.u_frontend_ftq.f0_enq1_valid && entry1[0]);
            exp_even_from_slot1 =
                dut.u_frontend_ftq.f0_enq1_valid && !entry1[0];
            exp_odd_from_slot1 =
                dut.u_frontend_ftq.f0_enq1_valid && entry1[0];
            exp_even_row = exp_even_from_slot1 ? ref_row_for_entry(entry1)
                                               : ref_row_for_entry(entry0);
            exp_odd_row = exp_odd_from_slot1 ? ref_row_for_entry(entry1)
                                             : ref_row_for_entry(entry0);

            check(dut.u_frontend_ftq.fq_abtb_even_write == exp_even_write,
                  "even sidecar write enable mismatch");
            check(dut.u_frontend_ftq.fq_abtb_odd_write == exp_odd_write,
                  "odd sidecar write enable mismatch");

            if (exp_even_write) begin
                check(dut.u_frontend_ftq.fq_abtb_even_write_row
                      == exp_even_row,
                      "even sidecar write row mismatch");
                check_write_data_matches(1'b1, exp_even_from_slot1);
            end
            if (exp_odd_write) begin
                check(dut.u_frontend_ftq.fq_abtb_odd_write_row
                      == exp_odd_row,
                      "odd sidecar write row mismatch");
                check_write_data_matches(1'b0, exp_odd_from_slot1);
            end

            if (dut.u_frontend_ftq.f0_enq1_payload
                && !dut.u_frontend_ftq.f0_enq1_valid) begin
                check(!dut.u_frontend_ftq.fq_abtb_even_write_entry1
                      && !dut.u_frontend_ftq.fq_abtb_odd_write_entry1,
                      "killed slot1 drove a sidecar write-entry enable");
            end
        end
    endtask

    task automatic check_sidecar_read_addressing;
        logic [FQ_PTR_W-1:0] entry0;
        logic [FQ_PTR_W-1:0] entry1;
        logic [FQ_PTR_W-2:0] exp_even_row;
        logic [FQ_PTR_W-2:0] exp_odd_row;
        begin
            entry0 = dut.u_frontend_ftq.fq_head;
            entry1 = ref_entry_next(entry0);
            exp_even_row = entry0[0] ? ref_row_for_entry(entry1)
                                     : ref_row_for_entry(entry0);
            exp_odd_row = ref_row_for_entry(entry0);

            check(dut.u_frontend_ftq.fq_head_p1 == entry1,
                  "DUT fq_head_p1 does not equal old head + 1");
            check(dut.u_frontend_ftq.fq_abtb_even_read_row
                  == exp_even_row,
                  "even sidecar read row mismatch");
            check(dut.u_frontend_ftq.fq_abtb_odd_read_row
                  == exp_odd_row,
                  "odd sidecar read row mismatch");
        end
    endtask

    task automatic check_sidecar_entry(
        input logic [FQ_PTR_W-1:0] entry,
        input logic rtl_hit,
        input logic rtl_way,
        input string slot_name
    );
        begin
            check(ref_entry_valid[entry],
                  $sformatf("%s observed an FQ entry without a reference token",
                            slot_name));
            check(rtl_hit == ref_hit_for_entry(entry)
                  && rtl_way == ref_way_for_entry(entry),
                  $sformatf("%s sidecar mismatch at entry=%0d token=%0d",
                            slot_name, entry, ref_entry_token[entry]));
        end
    endtask

    task automatic check_predicted_taken_branch_kill;
        integer before_count;
        integer cycle;
        begin
            before_count = slot1_sidecar_kill_branch_checks;
            clear_program();
            irom[0] = enc_branch(3'b000, 5'd0, 5'd0, 0);
            irom[1] = enc_jal(5'd1, 0);
            reset_cpu();
            begin : wait_predicted_taken_branch_kill_loop
                for (cycle = 0; cycle < 800; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (slot1_sidecar_kill_branch_checks > before_count)
                        disable wait_predicted_taken_branch_kill_loop;
                end
            end
            check(slot1_sidecar_kill_branch_checks > before_count,
                  "trained taken branch did not kill its slot1 sidecar candidate");
        end
    endtask

    task automatic wait_sidecar_kill_counter(
        input integer before_count,
        input integer max_cycles,
        input string message
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_sidecar_kill_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (slot1_sidecar_kill_checks > before_count) begin
                        found = 1'b1;
                        disable wait_sidecar_kill_loop;
                    end
                end
            end
            if (!found)
                fail(message);
        end
    endtask

    task automatic check_slot1_kill_sidecar_stall;
        integer before_kill_count;
        integer before_stall_count;
        integer cycle;
        begin
            before_kill_count = slot1_sidecar_kill_checks;
            before_stall_count = slot1_sidecar_kill_stall_checks;

            clear_program();
            for (cycle = 0; cycle < 10; cycle = cycle + 1)
                irom[cycle] = enc_addi(5'd3, 5'd0, cycle);
            irom[10] = enc_jal(5'd0, 8);
            irom[11] = enc_jal(5'd1, 0);
            irom[12] = enc_jal(5'd0, 0);

            reset_cpu();
            cache_ready = 1'b0;
            wait_sidecar_kill_counter(before_kill_count, 160,
                                      "slot0 kill did not exercise slot1 sidecar under backend stall");
            check(slot1_sidecar_kill_stall_checks > before_stall_count,
                  "slot1 sidecar kill was not observed while backend was stalled");
            cache_ready = 1'b1;
            repeat (8) @(negedge clk);
        end
    endtask

    task automatic check_slot1_kill_sidecar_wrap;
        integer before_wrap_count;
        integer cycle;
        begin
            before_wrap_count = slot1_sidecar_kill_wrap_checks;

            clear_program();
            // Redirect once to BASE+20 so the next fetch starts at slot1 of a
            // 64-bit block. That creates an odd FQ tail without writing any
            // invalid slot1 sidecar, then normal dual enqueues advance tail to
            // 15 before the final slot0 JAL kills its slot1 follower.
            irom[0] = enc_auipc(5'd2, 20'd0);
            irom[1] = enc_addi(5'd2, 5'd2, 20);
            irom[2] = enc_jalr(5'd0, 5'd2, 0);
            for (cycle = 5; cycle < 20; cycle = cycle + 1)
                irom[cycle] = enc_addi(5'd4, 5'd0, cycle);
            irom[20] = enc_jal(5'd0, 8);
            irom[21] = enc_jal(5'd1, 0);
            irom[22] = enc_jal(5'd0, 0);

            reset_cpu();
            begin : wait_wrap_kill_loop
                for (cycle = 0; cycle < 420; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (slot1_sidecar_kill_wrap_checks > before_wrap_count)
                        disable wait_wrap_kill_loop;
                end
            end
            check(slot1_sidecar_kill_wrap_checks > before_wrap_count,
                  "slot1 sidecar kill did not cover FQ tail wrap-around");
        end
    endtask

    task automatic wait_abtb_update(
        input logic [31:0] expected_pc,
        input logic expected_hit,
        input logic [1:0] expected_type,
        input logic expected_from_s1,
        input integer max_cycles,
        output logic observed_way
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            observed_way = 1'b0;
            begin : wait_update_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.abtb_update_valid
                        && dut.abtb_update_pc == expected_pc
                        && dut.abtb_update_hit == expected_hit) begin
                        check(dut.abtb_update_cfi_type == expected_type,
                              "ABTB update CFI type mismatch");
                        check(dut.pred_train_from_s1 == expected_from_s1,
                              $sformatf("ABTB update selected wrong EX slot pc=%08x expected_s1=%0d actual_s1=%0d",
                                        expected_pc, expected_from_s1,
                                        dut.pred_train_from_s1));
                        observed_way = dut.abtb_update_way;
                        found = 1'b1;
                        disable wait_update_loop;
                    end
                end
            end
            if (!found)
                fail($sformatf("timed out waiting for ABTB update pc=%08x hit=%0d",
                               expected_pc, expected_hit));
        end
    endtask

    task automatic wait_not_taken_branch(input logic [31:0] expected_pc);
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_not_taken_loop
                for (cycle = 0; cycle < 200; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.pred_train_valid
                        && dut.pred_train_pc == expected_pc
                        && dut.pred_train_is_branch
                        && !dut.pred_train_actual_taken) begin
                        check(!dut.abtb_update_valid,
                              "not-taken branch attempted an ABTB write");
                        found = 1'b1;
                        disable wait_not_taken_loop;
                    end
                end
            end
            if (!found)
                fail("timed out waiting for confirmed not-taken branch");
        end
    endtask

    task automatic wait_ignored_jalr(input logic [31:0] expected_pc);
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_jalr_loop
                for (cycle = 0; cycle < 240; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.pred_train_valid
                        && dut.pred_train_pc == expected_pc
                        && dut.pred_train_is_jalr) begin
                        check(!dut.abtb_update_valid,
                              "ordinary indirect JALR attempted an ABTB write");
                        found = 1'b1;
                        disable wait_jalr_loop;
                    end
                end
            end
            if (!found)
                fail("timed out waiting for ordinary indirect JALR");
        end
    endtask

    task automatic check_ftq_stall_hold;
        integer cycle;
        logic found;
        logic [31:0] held_pc;
        logic [31:0] held_inst0;
        logic [31:0] held_inst1;
        logic held_s1_valid;
        logic held_hit;
        logic held_way;
        logic [1:0] held_type;
        logic [31:0] held_target;
        logic held_pred_taken;
        logic [31:0] held_pred_target;
        logic held_s1_hit;
        logic held_s1_way;
        logic [1:0] held_s1_type;
        logic [31:0] held_s1_target;
        logic held_s1_pred_taken;
        logic [31:0] held_s1_pred_target;
        logic [31:0] update_count;
        begin
            @(negedge clk);
            cache_ready = 1'b0;
            found = 1'b0;
            begin : wait_stall_loop
                for (cycle = 0; cycle < 60; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.if_valid && !dut.id_allowin) begin
                        held_pc = dut.if_pc_out;
                        held_inst0 = dut.if_inst0_out;
                        held_inst1 = dut.if_inst1_out;
                        held_s1_valid = dut.if_s1_valid;
                        held_hit = dut.if_abtb_hit_out;
                        held_way = dut.if_abtb_way_out;
                        held_type = dut.if_abtb_cfi_type_out;
                        held_target = dut.if_abtb_target_out;
                        held_pred_taken = dut.if_abtb_pred_taken_out;
                        held_pred_target = dut.if_abtb_pred_target_out;
                        held_s1_hit = dut.if_s1_abtb_hit_out;
                        held_s1_way = dut.if_s1_abtb_way_out;
                        held_s1_type = dut.if_s1_abtb_cfi_type_out;
                        held_s1_target = dut.if_s1_abtb_target_out;
                        held_s1_pred_taken = dut.if_s1_abtb_pred_taken_out;
                        held_s1_pred_target = dut.if_s1_abtb_pred_target_out;
                        update_count = dut.abtb_ex_update_count;
                        found = 1'b1;
                        disable wait_stall_loop;
                    end
                end
            end
            if (!found)
                fail("pipeline did not reach an observable FTQ/FQ stall");

            repeat (4) begin
                @(negedge clk);
                check(dut.if_valid && !dut.id_allowin,
                      "frontend queue unexpectedly advanced during backend stall");
                check(dut.if_pc_out == held_pc
                      && dut.if_inst0_out == held_inst0
                      && dut.if_inst1_out == held_inst1
                      && dut.if_s1_valid == held_s1_valid,
                      "instruction payload changed during FTQ/FQ stall");
                check(dut.if_abtb_hit_out == held_hit
                      && dut.if_abtb_way_out == held_way
                      && dut.if_abtb_cfi_type_out == held_type
                      && dut.if_abtb_target_out == held_target
                      && dut.if_abtb_pred_taken_out == held_pred_taken
                      && dut.if_abtb_pred_target_out == held_pred_target,
                      "slot0 ABTB metadata changed during FTQ/FQ stall");
                check(dut.if_s1_abtb_hit_out == held_s1_hit
                      && dut.if_s1_abtb_way_out == held_s1_way
                      && dut.if_s1_abtb_cfi_type_out == held_s1_type
                      && dut.if_s1_abtb_target_out == held_s1_target
                      && dut.if_s1_abtb_pred_taken_out == held_s1_pred_taken
                      && dut.if_s1_abtb_pred_target_out == held_s1_pred_target,
                      "slot1 ABTB metadata changed during FTQ/FQ stall");
                check(!dut.pred_train_valid
                      && !dut.abtb_update_valid
                      && dut.abtb_ex_update_count == update_count,
                      "stalled EX instruction escaped the shared predictor fire qualification");
            end
            cache_ready = 1'b1;
        end
    endtask

    // Physical sidecar and FQ-entry identity reference model. Payload arrays
    // intentionally survive redirect; only entry validity/tokens are cleared.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_next_token <= 32'd1;
            ref_id_valid <= 1'b0;
            ref_id_s1_valid <= 1'b0;
            ref_ex_valid <= 1'b0;
            ref_ex_s1_valid <= 1'b0;
            redirect_clear_observe <= 1'b0;
            for (ref_i = 0; ref_i < FQ_DEPTH; ref_i = ref_i + 1) begin
                ref_entry_valid[ref_i] <= 1'b0;
                ref_entry_token[ref_i] <= 32'd0;
            end
            for (ref_i = 0; ref_i < FQ_ROWS; ref_i = ref_i + 1) begin
                ref_even_hit[ref_i] <= 1'b0;
                ref_even_way[ref_i] <= 1'b0;
                ref_odd_hit[ref_i] <= 1'b0;
                ref_odd_way[ref_i] <= 1'b0;
            end
        end else begin
            redirect_clear_observe <= dut.u_frontend_ftq.ex_redirect_valid;
            check_sidecar_write_edge();

            if (!dut.u_frontend_ftq.ex_redirect_valid) begin
                if (dut.u_frontend_ftq.f0_enq0_valid)
                    ref_write_entry_payload(
                        dut.u_frontend_ftq.fq_tail,
                        ref_slot0_src_hit(),
                        ref_slot0_src_way()
                    );
                if (dut.u_frontend_ftq.f0_enq1_valid)
                    ref_write_entry_payload(
                        ref_entry_next(dut.u_frontend_ftq.fq_tail),
                        dut.u_frontend_ftq.f0_abtb_bank1_hit_r,
                        dut.u_frontend_ftq.f0_abtb_bank1_way_r
                    );
            end

            if (dut.u_frontend_ftq.ex_redirect_valid) begin
                for (ref_i = 0; ref_i < FQ_DEPTH; ref_i = ref_i + 1)
                    ref_entry_valid[ref_i] <= 1'b0;
            end else begin
                if (dut.u_frontend_ftq.if_accept_single)
                    ref_entry_valid[dut.u_frontend_ftq.fq_head] <= 1'b0;
                if (dut.u_frontend_ftq.if_accept_dual) begin
                    ref_entry_valid[dut.u_frontend_ftq.fq_head] <= 1'b0;
                    ref_entry_valid[
                        ref_entry_next(dut.u_frontend_ftq.fq_head)
                    ] <= 1'b0;
                end

                if (dut.u_frontend_ftq.f0_enq0_valid) begin
                    ref_entry_valid[dut.u_frontend_ftq.fq_tail] <= 1'b1;
                    ref_entry_token[dut.u_frontend_ftq.fq_tail]
                        <= ref_next_token;
                end
                if (dut.u_frontend_ftq.f0_enq1_valid) begin
                    ref_entry_valid[
                        ref_entry_next(dut.u_frontend_ftq.fq_tail)
                    ] <= 1'b1;
                    ref_entry_token[
                        ref_entry_next(dut.u_frontend_ftq.fq_tail)
                    ]
                        <= ref_next_token + 32'd1;
                end
                if (dut.u_frontend_ftq.f0_enq0_valid)
                    ref_next_token <= ref_next_token
                                    + (dut.u_frontend_ftq.f0_enq1_valid
                                       ? 32'd2 : 32'd1);
            end

            if (dut.id_flush) begin
                ref_id_valid <= 1'b0;
                ref_id_s1_valid <= 1'b0;
            end else if (dut.id_allowin) begin
                ref_id_valid <= dut.if_valid && dut.if_ready_go_w;
                ref_id_s1_valid <= dut.if_valid && dut.if_ready_go_w
                                 && dut.if_s1_valid;
                if (dut.if_valid && dut.if_ready_go_w) begin
                    ref_id_token
                        <= ref_entry_token[dut.u_frontend_ftq.fq_head];
                    ref_id_hit
                        <= ref_hit_for_entry(dut.u_frontend_ftq.fq_head);
                    ref_id_way
                        <= ref_way_for_entry(dut.u_frontend_ftq.fq_head);
                    ref_id_s1_token
                        <= ref_entry_token[
                            ref_entry_next(dut.u_frontend_ftq.fq_head)
                        ];
                    ref_id_s1_hit
                        <= ref_hit_for_entry(
                            ref_entry_next(dut.u_frontend_ftq.fq_head)
                        );
                    ref_id_s1_way
                        <= ref_way_for_entry(
                            ref_entry_next(dut.u_frontend_ftq.fq_head)
                        );
                end
            end

            if (dut.ex_flush) begin
                ref_ex_valid <= 1'b0;
                ref_ex_s1_valid <= 1'b0;
            end else if (dut.ex_allowin) begin
                ref_ex_valid <= ref_id_valid && dut.id_ready_go;
                ref_ex_s1_valid <= ref_id_s1_valid && dut.id_ready_go;
                ref_ex_token <= ref_id_token;
                ref_ex_hit <= ref_id_hit;
                ref_ex_way <= ref_id_way;
                ref_ex_s1_token <= ref_id_s1_token;
                ref_ex_s1_hit <= ref_id_s1_hit;
                ref_ex_s1_way <= ref_id_s1_way;
            end
        end
    end

    always @(negedge clk) begin
        if (!rst_n) begin
            sidecar_stall_active = 1'b0;
            killed_pc_refetch_pending = 1'b0;
        end else begin
            check_sidecar_read_addressing();

            if (dut.u_frontend_ftq.fq_count != 0) begin
                check_sidecar_entry(dut.u_frontend_ftq.fq_head,
                                    dut.if_abtb_hit_out,
                                    dut.if_abtb_way_out,
                                    "slot0");
                if (dut.u_frontend_ftq.fq_head[0])
                    sidecar_head_odd_checks = sidecar_head_odd_checks + 1;
                else
                    sidecar_head_even_checks = sidecar_head_even_checks + 1;
            end
            if (dut.u_frontend_ftq.fq_count >= 2)
                check_sidecar_entry(
                                    ref_entry_next(dut.u_frontend_ftq.fq_head),
                                    dut.if_s1_abtb_hit_out,
                                    dut.if_s1_abtb_way_out,
                                    "slot1");

            if (dut.u_frontend_ftq.if_accept_single)
                sidecar_single_dequeue_checks =
                    sidecar_single_dequeue_checks + 1;
            if (dut.u_frontend_ftq.if_accept_dual)
                sidecar_dual_dequeue_checks =
                    sidecar_dual_dequeue_checks + 1;

            if (dut.if_valid && !dut.id_allowin) begin
                sidecar_stall_checks = sidecar_stall_checks + 1;
                if (sidecar_stall_active) begin
                    check(dut.u_frontend_ftq.fq_head == sidecar_stall_head
                          && ref_entry_token[dut.u_frontend_ftq.fq_head]
                             == sidecar_stall_token
                          && dut.if_abtb_hit_out == sidecar_stall_hit
                          && dut.if_abtb_way_out == sidecar_stall_way,
                          "stalled FQ head or sidecar metadata changed");
                end else begin
                    sidecar_stall_active = 1'b1;
                    sidecar_stall_head = dut.u_frontend_ftq.fq_head;
                    sidecar_stall_token =
                        ref_entry_token[dut.u_frontend_ftq.fq_head];
                    sidecar_stall_hit = dut.if_abtb_hit_out;
                    sidecar_stall_way = dut.if_abtb_way_out;
                end
            end else begin
                sidecar_stall_active = 1'b0;
            end

            if (redirect_clear_observe) begin
                check(dut.u_frontend_ftq.fq_count == 0 && !dut.if_valid,
                      "redirect exposed stale FQ sidecar payload");
                sidecar_redirect_hidden_checks =
                    sidecar_redirect_hidden_checks + 1;
            end

            if (dut.u_frontend_ftq.f0_enq1_payload
                && !dut.u_frontend_ftq.f0_enq1_valid) begin
                check(dut.u_frontend_ftq.f0_kill_after_slot0,
                      "slot1 enqueue was invalid without a slot0 kill");
                check(dut.u_frontend_ftq.f0_enq1_payload
                      && !dut.u_frontend_ftq.f0_enq1_valid,
                      "slot0 kill did not expose the required slot1 payload/valid split");
                check(!dut.u_frontend_ftq.fq_abtb_even_write_entry1
                      && !dut.u_frontend_ftq.fq_abtb_odd_write_entry1,
                      "invalid slot1 wrote ABTB sidecar metadata");
                slot1_sidecar_kill_checks = slot1_sidecar_kill_checks + 1;
                if (!dut.id_allowin || !dut.mem_allowin || !cache_ready)
                    slot1_sidecar_kill_stall_checks =
                        slot1_sidecar_kill_stall_checks + 1;
                if (dut.u_frontend_ftq.fq_tail_p1 == '0)
                    slot1_sidecar_kill_wrap_checks =
                        slot1_sidecar_kill_wrap_checks + 1;
                if (dut.u_frontend_ftq.f0_slot0_jal
                    || dut.u_frontend_ftq.f0_slot0_jalr
                    || dut.u_frontend_ftq.f0_slot0_system_redirect
                    || dut.u_frontend_ftq.f0_slot0_pred_taken)
                    slot1_sidecar_kill_redirect_checks =
                        slot1_sidecar_kill_redirect_checks + 1;
                if (dut.u_frontend_ftq.f0_slot0_jal)
                    slot1_sidecar_kill_jal_checks =
                        slot1_sidecar_kill_jal_checks + 1;
                if (dut.u_frontend_ftq.f0_slot0_jalr)
                    slot1_sidecar_kill_jalr_checks =
                        slot1_sidecar_kill_jalr_checks + 1;
                if (dut.u_frontend_ftq.f0_slot0_branch
                    && dut.u_frontend_ftq.f0_slot0_pred_taken)
                    slot1_sidecar_kill_branch_checks =
                        slot1_sidecar_kill_branch_checks + 1;
                killed_pc_for_coverage = dut.u_frontend_ftq.f0_slot1_pc;
                killed_pc_refetch_pending = 1'b1;
            end

            if (killed_pc_refetch_pending
                && ((dut.u_frontend_ftq.f0_enq0_valid
                     && dut.u_frontend_ftq.f0_slot0_pc
                        == killed_pc_for_coverage)
                    || (dut.u_frontend_ftq.f0_enq1_valid
                        && dut.u_frontend_ftq.f0_slot1_pc
                           == killed_pc_for_coverage))) begin
                sidecar_refetch_checks = sidecar_refetch_checks + 1;
                killed_pc_refetch_pending = 1'b0;
            end

            if (dut.id_valid) begin
                check(ref_id_valid
                      && dut.id_abtb_hit == ref_id_hit
                      && dut.id_abtb_way == ref_id_way,
                      "slot0 IF/ID token or sidecar metadata mismatch");
            end
            if (dut.id_s1_valid) begin
                check(ref_id_s1_valid
                      && dut.id_s1_abtb_hit == ref_id_s1_hit
                      && dut.id_s1_abtb_way == ref_id_s1_way,
                      "slot1 IF/ID token or sidecar metadata mismatch");
            end
            if (dut.ex_valid) begin
                check(ref_ex_valid
                      && dut.ex_abtb_hit == ref_ex_hit
                      && dut.ex_abtb_way == ref_ex_way,
                      "slot0 ID/EX token or sidecar metadata mismatch");
            end
            if (dut.ex_s1_valid) begin
                check(ref_ex_s1_valid
                      && dut.ex_s1_abtb_hit == ref_ex_s1_hit
                      && dut.ex_s1_abtb_way == ref_ex_s1_way,
                      "slot1 ID/EX token or sidecar metadata mismatch");
            end

            if (wrong_path_watch && dut.abtb_update_valid
                && dut.abtb_update_pc == wrong_path_pc)
                fail("redirected wrong-path instruction trained ABTB");
            if (dut.abtb_update_valid) begin
                check(dut.pred_train_valid
                      && dut.ex_ready_go_w
                      && dut.mem_allowin
                      && !dut.mem_branch_flush,
                      "ABTB update escaped the existing EX fire/flush qualification");
                if (dut.pred_train_from_s1)
                    check(ref_ex_s1_valid && ref_ex_s1_token != 0,
                          "ABTB update came from a slot1 instruction without an FQ token");
                else
                    check(ref_ex_valid && ref_ex_token != 0,
                          "ABTB update came from a slot0 instruction without an FQ token");
                sidecar_update_token_checks =
                    sidecar_update_token_checks + 1;
            end
            if (dut.s0_pred_update_valid_raw)
                check(!dut.pred_train_from_s1,
                      "younger slot1 update overrode an older slot0 CFI");
        end
    end

    initial begin
        logic miss_way;
        logic hit_way;

        clk = 1'b0;
        rst_n = 1'b0;
        cache_rdata = 32'd0;
        cache_ready = 1'b1;
        mmio_rdata = 32'd0;
        timer_irq_pending = 1'b0;
        wrong_path_watch = 1'b0;
        wrong_path_pc = 32'd0;
        slot1_sidecar_kill_checks = 0;
        slot1_sidecar_kill_stall_checks = 0;
        slot1_sidecar_kill_wrap_checks = 0;
        slot1_sidecar_kill_redirect_checks = 0;
        slot1_sidecar_kill_jal_checks = 0;
        slot1_sidecar_kill_jalr_checks = 0;
        slot1_sidecar_kill_branch_checks = 0;
        sidecar_head_even_checks = 0;
        sidecar_head_odd_checks = 0;
        sidecar_single_dequeue_checks = 0;
        sidecar_dual_dequeue_checks = 0;
        sidecar_stall_checks = 0;
        sidecar_redirect_hidden_checks = 0;
        sidecar_refetch_checks = 0;
        sidecar_update_token_checks = 0;
        sidecar_stall_active = 1'b0;
        redirect_clear_observe = 1'b0;
        killed_pc_refetch_pending = 1'b0;
        killed_pc_for_coverage = 32'd0;
        // Each scenario uses a distinct PC because ABTB/PHT state intentionally
        // persists between subtests.
        // Slot0 JAL: cold allocation, redirect+train, hit metadata, and stall.
        clear_program();
        irom[JAL_INDEX] = enc_jal(5'd0, 0);
        reset_cpu();
        wait_abtb_update(BASE + JAL_INDEX * 4, 1'b0,
                         TYPE_JAL, 1'b0, 400, miss_way);
        check(dut.branch_flush,
              "cold slot0 JAL did not redirect in the same cycle as training");
        check(dut.abtb_update_target == BASE + JAL_INDEX * 4,
              "slot0 JAL update target mismatch");
        wait_abtb_update(BASE + JAL_INDEX * 4, 1'b1,
                         TYPE_JAL, 1'b0, 320, hit_way);
        check(hit_way == miss_way,
              "slot0 JAL hit update did not reuse prediction-time way");
        check(dut.ex_abtb_hit
              && dut.ex_abtb_cfi_type == TYPE_JAL
              && dut.ex_abtb_target == BASE + JAL_INDEX * 4
              && dut.ex_abtb_pred_taken
              && dut.ex_abtb_pred_target == BASE + JAL_INDEX * 4,
              "slot0 JAL metadata was not preserved through EX");
        check_ftq_stall_hold();

        // Slot1 direct CALL: physical bank1 metadata and slot1 EX arbitration.
        clear_program();
        irom[CALL_BLOCK_INDEX] = enc_addi(5'd2, 5'd0, 1);
        irom[CALL_BLOCK_INDEX + 1] = enc_jal(5'd1, -4);
        reset_cpu();
        wait_abtb_update(BASE + (CALL_BLOCK_INDEX + 1) * 4, 1'b0,
                         TYPE_CALL, 1'b1, 480, miss_way);
        check(dut.abtb_update_pc[2],
              "slot1 CALL did not select ABTB bank1 from update_pc[2]");
        wait_abtb_update(BASE + (CALL_BLOCK_INDEX + 1) * 4, 1'b1,
                         TYPE_CALL, 1'b1, 360, hit_way);
        check(hit_way == miss_way,
              "slot1 CALL hit update did not reuse prediction-time way");
        check(dut.ex_s1_abtb_hit
              && dut.ex_s1_abtb_cfi_type == TYPE_CALL
              && dut.ex_s1_abtb_target
                 == BASE + CALL_BLOCK_INDEX * 4
              && dut.ex_s1_abtb_pred_taken
              && dut.ex_s1_abtb_pred_target
                 == BASE + CALL_BLOCK_INDEX * 4,
              "slot1 CALL metadata was not preserved through EX");

        // Taken slot0 branch redirects over a younger wrong-path CALL.
        clear_program();
        irom[TAKEN_BRANCH_INDEX] =
            enc_branch(3'b000, 5'd0, 5'd0, 8);
        irom[TAKEN_BRANCH_INDEX + 1] = enc_jal(5'd1, 0);
        irom[TAKEN_BRANCH_INDEX + 2] = enc_jal(5'd0, 0);
        reset_cpu();
        wrong_path_pc = BASE + (TAKEN_BRANCH_INDEX + 1) * 4;
        wrong_path_watch = 1'b1;
        wait_abtb_update(BASE + TAKEN_BRANCH_INDEX * 4, 1'b0,
                         TYPE_BRANCH, 1'b0, 520, miss_way);
        check(dut.branch_flush && dut.pred_train_actual_taken,
              "taken branch did not redirect and train together");
        check(dut.abtb_update_target
              == BASE + (TAKEN_BRANCH_INDEX + 2) * 4,
              "taken branch ABTB target mismatch");
        wait_abtb_update(BASE + (TAKEN_BRANCH_INDEX + 2) * 4, 1'b0,
                         TYPE_JAL, 1'b0, 320, hit_way);
        wrong_path_watch = 1'b0;

        // Not-taken branch trains direction state but must not allocate ABTB.
        clear_program();
        irom[NOT_TAKEN_INDEX] =
            enc_branch(3'b001, 5'd0, 5'd0, 8);
        irom[NOT_TAKEN_INDEX + 1] = NOP;
        irom[NOT_TAKEN_INDEX + 2] = enc_jal(5'd0, 0);
        reset_cpu();
        wrong_path_pc = BASE + NOT_TAKEN_INDEX * 4;
        wrong_path_watch = 1'b1;
        wait_not_taken_branch(BASE + NOT_TAKEN_INDEX * 4);
        wait_abtb_update(BASE + (NOT_TAKEN_INDEX + 2) * 4, 1'b0,
                         TYPE_JAL, 1'b0, 360, miss_way);
        wrong_path_watch = 1'b0;

        // Exact RISC-V return hint: JALR x0, 0(x1).
        clear_program();
        irom[RET_BASE_INDEX] = enc_auipc(5'd1, 20'd0);
        irom[RET_BASE_INDEX + 1] = enc_addi(5'd1, 5'd1, 12);
        irom[RET_BASE_INDEX + 2] = enc_jalr(5'd0, 5'd1, 0);
        irom[RET_BASE_INDEX + 3] = enc_jal(5'd0, 0);
        reset_cpu();
        wait_abtb_update(BASE + (RET_BASE_INDEX + 2) * 4, 1'b0,
                         TYPE_RET, 1'b0, 640, miss_way);
        check(dut.abtb_update_target
              == BASE + (RET_BASE_INDEX + 3) * 4,
              "RET update target mismatch");

        // Ordinary indirect JALR uses neither CALL nor RET hint and is ignored.
        clear_program();
        irom[JALR_BASE_INDEX] = enc_auipc(5'd2, 20'd0);
        irom[JALR_BASE_INDEX + 1] = enc_addi(5'd2, 5'd2, 12);
        irom[JALR_BASE_INDEX + 2] = enc_jalr(5'd0, 5'd2, 0);
        irom[JALR_BASE_INDEX + 3] = enc_jal(5'd0, 0);
        reset_cpu();
        wrong_path_pc = BASE + (JALR_BASE_INDEX + 2) * 4;
        wrong_path_watch = 1'b1;
        wait_ignored_jalr(BASE + (JALR_BASE_INDEX + 2) * 4);
        wait_abtb_update(BASE + (JALR_BASE_INDEX + 3) * 4, 1'b0,
                         TYPE_JAL, 1'b0, 680, miss_way);
        wrong_path_watch = 1'b0;

        // Slot0 control flow kills slot1: sidecar slot1 writes must use the
        // real valid bit, and stale metadata must not leak through stall or
        // pointer wrap-around.
        check_slot1_kill_sidecar_stall();
        check_slot1_kill_sidecar_wrap();
        check_predicted_taken_branch_kill();
        check(slot1_sidecar_kill_redirect_checks != 0,
              "slot1 sidecar kill test did not cover redirect-class slot0 CFI");
        check(slot1_sidecar_kill_jal_checks != 0,
              "slot1 sidecar kill test did not cover slot0 JAL");
        check(slot1_sidecar_kill_jalr_checks != 0,
              "slot1 sidecar kill test did not cover slot0 JALR");
        check(slot1_sidecar_kill_branch_checks != 0,
              "slot1 sidecar kill test did not cover predicted-taken slot0 branch");
        check(sidecar_head_even_checks != 0
              && sidecar_head_odd_checks != 0,
              "sidecar reference model did not cover even and odd FQ heads");
        check(sidecar_single_dequeue_checks != 0
              && sidecar_dual_dequeue_checks != 0,
              "sidecar reference model did not cover single and dual dequeue");
        check(sidecar_stall_checks != 0,
              "sidecar reference model did not cover a held FQ head");
        check(sidecar_redirect_hidden_checks != 0,
              "sidecar reference model did not prove redirect hides stale payload");
        check(sidecar_refetch_checks != 0,
              "sidecar test did not cover legal refetch of a killed slot PC");
        check(sidecar_update_token_checks != 0,
              "ABTB updates were not checked against valid FQ entry tokens");

        check(dut.abtb_lookup_block_count != 32'd0,
              "accepted frontend blocks were not counted");
        check(dut.abtb_ex_update_count
              == dut.abtb_allocation_count + dut.abtb_hit_update_count,
              "ABTB update observation counters are inconsistent");

        $display("[INFO] sidecar coverage kills=%0d jal=%0d jalr=%0d branch=%0d even_head=%0d odd_head=%0d single_deq=%0d dual_deq=%0d stalls=%0d redirects=%0d refetch=%0d update_tokens=%0d",
                 slot1_sidecar_kill_checks,
                 slot1_sidecar_kill_jal_checks,
                 slot1_sidecar_kill_jalr_checks,
                 slot1_sidecar_kill_branch_checks,
                 sidecar_head_even_checks,
                 sidecar_head_odd_checks,
                 sidecar_single_dequeue_checks,
                 sidecar_dual_dequeue_checks,
                 sidecar_stall_checks,
                 sidecar_redirect_hidden_checks,
                 sidecar_refetch_checks,
                 sidecar_update_token_checks);
        $display("[PASS] frontend ABTB shadow integration test");
        $finish;
    end

endmodule
