`timescale 1ns/1ps

module tb_frontend_abtb_steering;

    localparam logic [31:0] BASE        = 32'h8000_0000;
    localparam logic [31:0] NOP         = 32'h0000_0013;
    localparam logic [1:0]  TYPE_JAL    = 2'b00;
    localparam logic [1:0]  TYPE_CALL   = 2'b01;
    localparam logic [1:0]  TYPE_BRANCH = 2'b10;
    localparam logic [1:0]  TYPE_RET    = 2'b11;
    localparam integer BANK0_INDEX       = 32;
    localparam integer BANK1_INDEX       = 64;
    localparam integer PC2_INDEX         = 97;
    localparam integer JAL_CALL_INDEX    = 128;
    localparam integer JALR_CALL_INDEX   = 160;
    localparam integer INDIRECT_INDEX    = 192;
    localparam integer BRANCH_INDEX      = 224;
    localparam integer RET_INDEX         = 256;
    localparam integer ORDER_INDEX       = 288;
    localparam integer WRONG_INDEX       = 320;
    localparam integer OVERRIDE_INDEX    = 352;
    localparam integer WRAP_START_INDEX  = 400;
    localparam integer FINAL_INDEX       = 448;
    localparam integer PHT_SLOT1_INDEX   = 512;
    localparam integer PHT_OLDER_INDEX   = 560;
    localparam integer PHT_STALL_INDEX   = 608;

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
    integer case_count;

    cpu_top dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .irom_addr            (irom_addr),
        .irom_req_valid       (),
        .irom_req_addr        (),
        .irom_req_ready       (1'b0),
        .irom_resp_valid      (1'b0),
        .irom_data            (irom_data),
        .cache_req            (cache_req),
        .cache_wr             (cache_wr),
        .cache_addr           (cache_addr),
        .cache_wea            (cache_wea),
        .cache_wdata          (cache_wdata),
        .cache_load_mask      (),
        .cache_uncached       (),
        .cache_rdata          (cache_rdata),
        .cache_ready          (cache_ready),
        .cache_flush          (cache_flush),
        .cache_pipeline_stall (cache_pipeline_stall),
        .mmio_addr            (mmio_addr),
        .mmio_wr_addr         (mmio_wr_addr),
        .mmio_wea             (mmio_wea),
        .mmio_wdata           (mmio_wdata),
        .mmio_rdata           (mmio_rdata),
        .timer_irq_pending    (timer_irq_pending),
        .debug0_wb_valid      (),
        .debug0_wb_pc         (),
        .debug0_wb_rf_wen     (),
        .debug0_wb_rf_wnum    (),
        .debug0_wb_rf_wdata   (),
        .debug1_wb_valid      (),
        .debug1_wb_pc         (),
        .debug1_wb_rf_wen     (),
        .debug1_wb_rf_wnum    (),
        .debug1_wb_rf_wdata   (),
        .debug0_wb_inst          (),
        .debug0_wb_exception     (),
        .debug0_wb_mem_read      (),
        .debug0_wb_mem_write     (),
        .debug0_wb_mem_size      (),
        .debug0_wb_mem_unsigned  (),
        .debug0_wb_mem_addr      (),
        .debug0_wb_store_data    (),
        .debug0_wb_csr_rstat     (),
        .debug0_wb_csr_data      (),
        .debug1_wb_inst          (),
        .debug1_wb_mem_read      (),
        .debug1_wb_mem_write     (),
        .debug1_wb_mem_size      (),
        .debug1_wb_mem_unsigned  (),
        .debug1_wb_mem_addr      (),
        .debug1_wb_store_data    (),
        .debug_gpr_state         (),
        .debug_priv_state        (),
        .debug_excp_valid        (),
        .debug_ertn              (),
        .debug_intr_no           (),
        .debug_cause             (),
        .debug_exception_pc      (),
        .debug_exception_inst    ()
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

    function automatic logic [31:0] enc_lw(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_lw = {imm[11:0], rs1, 3'b010, rd, 7'b0000011};
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

    task automatic pass_case(input string message);
        begin
            case_count = case_count + 1;
            $display("[INFO] case %0d: %s", case_count, message);
        end
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
            rst_n = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task automatic wait_update(
        input logic [31:0] expected_pc,
        input logic expected_hit,
        input logic [1:0] expected_type,
        input integer max_cycles
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_update_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.abtb_update_valid
                        && dut.abtb_update_pc == expected_pc
                        && dut.abtb_update_hit == expected_hit) begin
                        check(dut.abtb_update_cfi_type == expected_type,
                              "ABTB update type mismatch");
                        found = 1'b1;
                        disable wait_update_loop;
                    end
                end
            end
            if (!found)
                fail($sformatf("timed out waiting for update pc=%08x hit=%0d",
                               expected_pc, expected_hit));
        end
    endtask

    task automatic wait_direct(
        input logic [31:0] expected_lookup_pc,
        input logic expected_bank,
        input logic [1:0] expected_type,
        input logic [31:0] expected_target,
        input integer max_cycles
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_direct_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.stage1_steer_valid
                        && dut.stage1_steer_source_abtb
                        && dut.pc == expected_lookup_pc) begin
                        if (dut.stage1_steer_taken
                            && dut.stage1_steer_bank == expected_bank
                            && dut.stage1_steer_cfi_type == expected_type
                            && dut.stage1_steer_target == expected_target
                            && dut.stage1_steer_next_pc == expected_target) begin
                            found = 1'b1;
                            disable wait_direct_loop;
                        end
                    end
                end
            end
            if (!found)
                fail($sformatf("timed out waiting for ABTB steer pc=%08x",
                               expected_lookup_pc));
        end
    endtask

    task automatic wait_sequential(
        input logic [31:0] expected_lookup_pc,
        input integer max_cycles
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_sequential_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.stage1_steer_valid
                        && !dut.stage1_steer_source_abtb
                        && dut.pc == expected_lookup_pc
                        && !dut.stage1_steer_taken) begin
                        found = 1'b1;
                        disable wait_sequential_loop;
                    end
                end
            end
            if (!found)
                fail($sformatf("timed out waiting for sequential steer pc=%08x",
                               expected_lookup_pc));
        end
    endtask

    task automatic wait_sequential_source(
        input logic [31:0] expected_lookup_pc,
        input integer max_cycles
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_sequential_source_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.stage1_steer_valid
                        && !dut.stage1_steer_source_abtb
                        && dut.pc == expected_lookup_pc) begin
                        found = 1'b1;
                        disable wait_sequential_source_loop;
                    end
                end
            end
            if (!found)
                fail($sformatf("timed out waiting for sequential source pc=%08x",
                               expected_lookup_pc));
        end
    endtask

    task automatic wait_f0_sequential_accept(
        input logic [31:0] expected_pc,
        input integer max_cycles
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_f0_sequential_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.u_frontend_ftq.f0_valid_r
                        && dut.u_frontend_ftq.f0_start_pc_r == expected_pc
                        && !dut.u_frontend_ftq.f0_steer_taken_r
                        && !dut.u_frontend_ftq.f0_steer_source_abtb_r) begin
                        found = 1'b1;
                        disable wait_f0_sequential_loop;
                    end
                end
            end
            if (!found)
                fail($sformatf("timed out waiting for F0 sequential accept pc=%08x",
                               expected_pc));
        end
    endtask

    task automatic wait_direct_resolve(
        input logic [31:0] expected_pc,
        input logic expected_slot1,
        input logic expected_redirect,
        input integer max_cycles
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_resolve_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (!expected_slot1
                        && dut.ex_valid
                        && dut.ex_pred_source_abtb
                        && dut.ex_pc == expected_pc
                        && dut.ex_ready_go_w && dut.mem_allowin) begin
                        check(dut.branch_flush == expected_redirect,
                              "slot0 ABTB prediction redirect mismatch");
                        found = 1'b1;
                        disable wait_resolve_loop;
                    end
                    if (expected_slot1
                        && dut.ex_s1_valid
                        && dut.ex_s1_pred_source_abtb
                        && dut.ex_s1_pc == expected_pc
                        && dut.ex_ready_go_w && dut.mem_allowin) begin
                        check(dut.ex_s1_branch_redirect == expected_redirect,
                              "slot1 ABTB prediction redirect mismatch");
                        found = 1'b1;
                        disable wait_resolve_loop;
                    end
                end
            end
            if (!found)
                fail($sformatf("timed out waiting for ABTB resolve pc=%08x",
                               expected_pc));
        end
    endtask

    task automatic wait_slot_binding(
        input logic [31:0] expected_pc,
        input logic expected_slot1,
        input integer max_cycles
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            begin : wait_binding_loop
                for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (!expected_slot1 && dut.if_valid
                        && dut.if_pc_out == expected_pc
                        && dut.if_pred_source_abtb_out) begin
                        check(dut.if_pred_taken_out,
                              "slot0 ABTB source was not canonical taken");
                        found = 1'b1;
                        disable wait_binding_loop;
                    end
                    if (expected_slot1 && dut.if_valid && dut.if_s1_valid
                        && dut.if_pc_out + 32'd4 == expected_pc
                        && dut.if_s1_pred_source_abtb_out) begin
                        check(!dut.if_pred_source_abtb_out
                              && !dut.if_pred_taken_out
                              && dut.if_s1_pred_taken_out,
                              "bank1 ABTB prediction was bound to the wrong slot");
                        found = 1'b1;
                        disable wait_binding_loop;
                    end
                end
            end
            if (!found)
                fail("timed out waiting for canonical slot binding");
        end
    endtask

    task automatic scenario_bank0_jal;
        logic [31:0] redirects_before;
        logic [31:0] test_pc;
        integer cycle;
        logic saw_slot1_kill;
        begin
            test_pc = BASE + BANK0_INDEX * 4;
            clear_program();
            irom[BANK0_INDEX] = enc_jal(5'd0, 0);
            irom[BANK0_INDEX + 1] = enc_addi(5'd7, 5'd7, 1);
            reset_cpu();

            wait_f0_sequential_accept(test_pc, 160);
            pass_case("cold miss uses sequential fallback");
            wait_update(test_pc, 1'b0, TYPE_JAL, 220);
            pass_case("EX training allocates the cold ABTB CFI");

            wait_direct(test_pc, 1'b0, TYPE_JAL, test_pc, 220);
            pass_case("bank0 JAL hit drives canonical steering");
            wait_slot_binding(test_pc, 1'b0, 220);
            saw_slot1_kill = 1'b0;
            begin : slot1_kill_loop
                for (cycle = 0; cycle < 160; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.u_frontend_ftq.f0_enq1_payload
                        && dut.u_frontend_ftq.f0_slot0_pred_source_abtb) begin
                        check(!dut.u_frontend_ftq.f0_enq1_valid,
                              "slot0 ABTB JAL did not kill slot1");
                        saw_slot1_kill = 1'b1;
                        disable slot1_kill_loop;
                    end
                end
            end
            check(saw_slot1_kill,
                  "did not observe slot0 ABTB kill at F0");
            pass_case("slot0 ABTB taken kills slot1");

            redirects_before = dut.abtb_direct_redirect_count;
            wait_direct_resolve(test_pc, 1'b0, 1'b0, 220);
            check(dut.abtb_direct_redirect_count == redirects_before,
                  "correct bank0 ABTB target produced an extra redirect");
            pass_case("correct bank0 target reaches EX without redirect");
        end
    endtask

    task automatic scenario_bank1_jal;
        logic [31:0] block_pc;
        logic [31:0] jal_pc;
        begin
            block_pc = BASE + BANK1_INDEX * 4;
            jal_pc = block_pc + 32'd4;
            clear_program();
            irom[BANK1_INDEX] = enc_addi(5'd2, 5'd0, 1);
            irom[BANK1_INDEX + 1] = enc_jal(5'd0, -4);
            reset_cpu();

            wait_update(jal_pc, 1'b0, TYPE_JAL, 320);
            wait_direct(block_pc, 1'b1, TYPE_JAL, block_pc, 260);
            pass_case("bank1 JAL steers when the first instruction is not taken");
            wait_slot_binding(jal_pc, 1'b1, 260);
            pass_case("bank1 prediction metadata is bound to slot1");
            wait_direct_resolve(jal_pc, 1'b1, 1'b0, 260);
            pass_case("correct slot1 direct target avoids redundant EX redirect");
        end
    endtask

    task automatic scenario_pc2_bank1_first;
        logic [31:0] test_pc;
        begin
            test_pc = BASE + PC2_INDEX * 4;
            clear_program();
            irom[PC2_INDEX] = enc_jal(5'd0, 0);
            reset_cpu();

            wait_update(test_pc, 1'b0, TYPE_JAL, 360);
            wait_direct(test_pc, 1'b1, TYPE_JAL, test_pc, 280);
            check(dut.pc[2],
                  "bank1 first-instruction case did not use a PC+4 fetch start");
            pass_case("current_pc[2]==1 uses bank1 as the first instruction");
        end
    endtask

    task automatic scenario_calls;
        logic [31:0] jal_pc;
        logic [31:0] jalr_pc;
        begin
            jal_pc = BASE + JAL_CALL_INDEX * 4;
            clear_program();
            irom[JAL_CALL_INDEX] = enc_jal(5'd1, 0);
            reset_cpu();
            wait_update(jal_pc, 1'b0, TYPE_CALL, 420);
            wait_direct(jal_pc, 1'b0, TYPE_CALL, jal_pc, 260);
            pass_case("JAL link-register hint steers as TYPE_CALL");

            jalr_pc = BASE + JALR_CALL_INDEX * 4;
            clear_program();
            irom[JALR_CALL_INDEX - 2] = enc_auipc(5'd2, 20'd0);
            irom[JALR_CALL_INDEX - 1] = enc_addi(5'd2, 5'd2, 8);
            irom[JALR_CALL_INDEX] = enc_jalr(5'd1, 5'd2, 0);
            reset_cpu();
            wait_update(jalr_pc, 1'b0, TYPE_CALL, 520);
            wait_direct(jalr_pc, 1'b0, TYPE_CALL, jalr_pc, 300);
            pass_case("JALR x1/x5 link-register hint steers as TYPE_CALL");
        end
    endtask

    task automatic scenario_unsupported_types;
        integer cycle;
        logic saw_ordinary_jalr;
        logic [31:0] indirect_pc;
        logic [31:0] branch_pc;
        logic [31:0] ret_pc;
        begin
            indirect_pc = BASE + INDIRECT_INDEX * 4;
            clear_program();
            irom[INDIRECT_INDEX - 2] = enc_auipc(5'd2, 20'd0);
            irom[INDIRECT_INDEX - 1] = enc_addi(5'd2, 5'd2, 8);
            irom[INDIRECT_INDEX] = enc_jalr(5'd0, 5'd2, 0);
            reset_cpu();
            saw_ordinary_jalr = 1'b0;
            for (cycle = 0; cycle < 620; cycle = cycle + 1) begin
                @(negedge clk);
                if (dut.pred_train_valid && dut.pred_train_pc == indirect_pc) begin
                    check(!dut.abtb_update_valid,
                          "ordinary indirect JALR wrote ABTB");
                    saw_ordinary_jalr = 1'b1;
                end
                if (dut.pc == indirect_pc && dut.stage1_steer_valid)
                    check(!dut.stage1_steer_source_abtb,
                          "ordinary indirect JALR used ABTB steering");
            end
            check(saw_ordinary_jalr,
                  "ordinary indirect JALR did not reach confirmed training");
            pass_case("ordinary indirect JALR neither allocates nor steers");

            branch_pc = BASE + BRANCH_INDEX * 4;
            clear_program();
            irom[BRANCH_INDEX] = NOP;
            irom[BRANCH_INDEX + 1] = enc_jal(5'd0, -4);
            reset_cpu();
            wait_update(branch_pc + 32'd4, 1'b0, TYPE_JAL, 680);
            wait_direct(branch_pc, 1'b1, TYPE_JAL, branch_pc, 680);

            // Keep the trained bank1 JAL, then train slot0 as an older branch
            // without resetting predictor state. A taken slot0 branch kills
            // slot1, so training bank1 first is required for this scenario.
            irom[BRANCH_INDEX] = enc_branch(3'b000, 5'd0, 5'd0, 0);
            wait_update(branch_pc, 1'b0, TYPE_BRANCH, 680);
            wait_direct(branch_pc, 1'b0, TYPE_BRANCH, branch_pc, 1200);
            begin : branch_owned_taken_loop
                logic saw_owned_taken;
                saw_owned_taken = 1'b0;
                for (cycle = 0; cycle < 480; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.if_valid && dut.if_pc_out == branch_pc
                        && dut.if_pred_taken_out) begin
                        check(dut.if_pred_source_abtb_out
                              && dut.if_stage1_branch_owned_out,
                              "taken branch did not carry independent ownership");
                        saw_owned_taken = 1'b1;
                        disable branch_owned_taken_loop;
                    end
                end
                check(saw_owned_taken,
                      "did not observe taken branch ownership at FQ output");
            end
            pass_case("PHT taken branch hit owns Stage-1 steering");

            // Keep the ABTB entry but change the architectural branch to NT.
            // The younger bank1 JAL remains eligible and loops back.
            irom[BRANCH_INDEX] = enc_branch(3'b001, 5'd0, 5'd0, 0);
            begin : branch_owned_nt_loop
                logic saw_owned_nt;
                saw_owned_nt = 1'b0;
                for (cycle = 0; cycle < 1600; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.u_frontend_ftq.f0_valid_r
                        && dut.u_frontend_ftq.f0_start_pc_r == branch_pc
                        && dut.u_frontend_ftq.f0_slot0_stage1_branch_owned
                        && !dut.u_frontend_ftq.f0_slot0_pred_taken) begin
                        check(dut.u_frontend_ftq.f0_final_taken
                              && dut.u_frontend_ftq.f0_final_source_abtb
                              && dut.u_frontend_ftq.f0_final_bank
                              && dut.u_frontend_ftq.f0_slot1_pred_source_abtb,
                              "owned branch NT did not select younger bank1 JAL");
                        saw_owned_nt = 1'b1;
                        disable branch_owned_nt_loop;
                    end
                end
                check(saw_owned_nt,
                      "did not observe branch-owned not-taken metadata");
            end
            pass_case("PHT not-taken branch retains ownership and selects bank1");

            ret_pc = BASE + RET_INDEX * 4;
            clear_program();
            irom[RET_INDEX - 2] = enc_auipc(5'd1, 20'd0);
            irom[RET_INDEX - 1] = enc_addi(5'd1, 5'd1, 8);
            irom[RET_INDEX] = enc_jalr(5'd0, 5'd1, 0);
            reset_cpu();
            wait_update(ret_pc, 1'b0, TYPE_RET, 760);
            wait_sequential_source(ret_pc, 360);
            check(!dut.stage1_steer_source_abtb,
                  "TYPE_RET entry used ABTB/PHT branch steering");
            pass_case("TYPE_RET falls through under default branch steering");
        end
    endtask

    task automatic scenario_program_order;
        logic [31:0] block_pc;
        begin
            block_pc = BASE + ORDER_INDEX * 4;
            // Train bank1 first, then turn slot0 into a JAL without resetting the
            // predictor. Both physical banks then hold ABTB entries.
            clear_program();
            irom[ORDER_INDEX] = NOP;
            irom[ORDER_INDEX + 1] = enc_jal(5'd0, -4);
            reset_cpu();
            wait_direct(block_pc, 1'b1, TYPE_JAL, block_pc, 880);
            irom[ORDER_INDEX] = enc_jal(5'd0, 0);
            wait_update(block_pc, 1'b0, TYPE_JAL, 320);
            wait_direct(block_pc, 1'b0, TYPE_JAL, block_pc, 320);
            check(dut.abtb_bank1_pred_taken,
                  "bank1 ABTB candidate was absent in dual-CFI arbitration");
            pass_case("bank0 wins when both ABTB banks contain taken CFI");

            // A trained taken branch is older than the still-present bank1 JAL.
            irom[ORDER_INDEX] = enc_branch(3'b000, 5'd0, 5'd0, 0);
            wait_update(block_pc, 1'b1, TYPE_BRANCH, 360);
            wait_direct(block_pc, 1'b0, TYPE_BRANCH, block_pc, 1200);
            check(dut.abtb_bank1_pred_taken
                  && dut.stage1_steer_source_abtb
                  && dut.stage1_steer_bank == 1'b0,
                  "owned bank0 branch did not beat younger bank1 ABTB");
            pass_case("owned bank0 branch wins over bank1 ABTB");
        end
    endtask

    task automatic scenario_wrong_target;
        logic [31:0] redirects_before;
        logic [31:0] misses_before;
        logic [31:0] test_pc;
        begin
            test_pc = BASE + WRONG_INDEX * 4;
            clear_program();
            irom[WRONG_INDEX] = enc_jal(5'd0, 8);
            irom[WRONG_INDEX + 2] = enc_jal(5'd0, -8);
            reset_cpu();
            wait_direct(test_pc, 1'b0, TYPE_JAL, test_pc + 32'd8, 980);

            // Change only architectural code. The next lookup uses the stale
            // trained target, then EX redirects and updates the carried way.
            irom[WRONG_INDEX] = enc_jal(5'd0, 12);
            irom[WRONG_INDEX + 3] = enc_jal(5'd0, -12);
            redirects_before = dut.abtb_direct_redirect_count;
            misses_before = dut.abtb_direct_target_miss_count;
            wait_direct_resolve(test_pc, 1'b0, 1'b1, 360);
            check(dut.branch_target == test_pc + 32'd12
                  && dut.abtb_update_valid
                  && dut.abtb_update_pc == test_pc
                  && dut.abtb_update_hit,
                  "stale target did not redirect and hit-update together");
            repeat (2) @(negedge clk);
            check(dut.abtb_direct_redirect_count > redirects_before
                  && dut.abtb_direct_target_miss_count > misses_before,
                  "stale-target counters did not record the correction");
            pass_case("stale ABTB target redirects and retrains at EX");

            wait_direct(test_pc, 1'b0, TYPE_JAL, test_pc + 32'd12, 360);
            wait_direct_resolve(test_pc, 1'b0, 1'b0, 360);
            pass_case("retrained target becomes a correct ABTB prediction");
        end
    endtask

    task automatic scenario_same_instruction_override;
        integer cycle;
        logic saw_divergence;
        logic saw_branch_train;
        logic [31:0] test_pc;
        begin
            test_pc = BASE + OVERRIDE_INDEX * 4;
            // Establish a JAL ABTB entry for BASE+8.
            clear_program();
            irom[OVERRIDE_INDEX] = enc_jal(5'd0, 8);
            irom[OVERRIDE_INDEX + 2] = enc_jal(5'd0, -8);
            reset_cpu();
            wait_direct(test_pc, 1'b0, TYPE_JAL, test_pc + 32'd8, 1080);

            // A same-PC not-taken branch must not allocate/update ABTB, so the
            // old direct ABTB entry can remain until replaced by a qualified
            // taken CFI update. EX redirect corrects this stale predictor state.
            irom[OVERRIDE_INDEX] =
                enc_branch(3'b001, 5'd0, 5'd0, 12);
            irom[OVERRIDE_INDEX + 1] = enc_jal(5'd0, -4);
            saw_branch_train = 1'b0;
            begin : branch_train_loop
                for (cycle = 0; cycle < 320; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.pred_train_valid && dut.pred_train_pc == test_pc
                        && dut.pred_train_is_conditional_control
                        && !dut.pred_train_actual_taken) begin
                        check(!dut.abtb_update_valid,
                              "not-taken branch overwrote the stale ABTB entry");
                        saw_branch_train = 1'b1;
                        disable branch_train_loop;
                    end
                end
            end
            check(saw_branch_train,
                  "same-PC not-taken branch did not reach confirmed training");

            saw_divergence = 1'b0;
            begin : divergence_loop
                for (cycle = 0; cycle < 480; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.pc == test_pc
                        && dut.stage1_steer_valid
                        && dut.stage1_steer_source_abtb
                        && dut.stage1_steer_target == test_pc + 32'd8) begin
                        saw_divergence = 1'b1;
                        disable divergence_loop;
                    end
                end
            end
            check(saw_divergence,
                  "did not observe stale direct ABTB target after NT branch");
            pass_case("same-instruction NT branch does not overwrite direct ABTB target");
        end
    endtask

    task automatic scenario_stall_wrap_redirect;
        integer cycle;
        logic [31:0] held_pc;
        logic held_source;
        logic saw_stall;
        logic saw_wrap;
        logic saw_redirect_update;
        logic saw_younger_update;
        logic [31:0] final_pc;
        begin
            clear_program();
            for (cycle = WRAP_START_INDEX;
                 cycle < WRAP_START_INDEX + 24;
                 cycle = cycle + 1)
                irom[cycle] = enc_addi(5'd3, 5'd3, 1);
            irom[WRAP_START_INDEX + 24] = enc_jal(5'd0, -96);
            reset_cpu();
            saw_wrap = 1'b0;
            for (cycle = 0; cycle < 1400; cycle = cycle + 1) begin
                @(negedge clk);
                if (dut.u_frontend_ftq.fq_tail < 4'd2
                    && dut.u_frontend_ftq.fq_count != 0
                    && cycle > 40)
                    saw_wrap = 1'b1;
                if (saw_wrap)
                    cycle = 1400;
            end
            check(saw_wrap, "FQ pointer did not wrap under default branch steering");
            pass_case("FQ wrap-around preserves steering operation");

            cache_ready = 1'b0;
            saw_stall = 1'b0;
            begin : stall_loop
                for (cycle = 0; cycle < 120; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.if_valid && !dut.id_allowin
                        && !dut.u_frontend_ftq.bp0_fire) begin
                        held_pc = dut.pc;
                        held_source = dut.stage1_steer_source_abtb;
                        repeat (4) begin
                            @(negedge clk);
                            check(dut.pc == held_pc
                                  && dut.stage1_steer_source_abtb
                                     == held_source,
                                  "stall consumed steering or advanced current_pc");
                        end
                        saw_stall = 1'b1;
                        disable stall_loop;
                    end
                end
            end
            cache_ready = 1'b1;
            check(saw_stall, "backend stall did not hold frontend state");
            pass_case("stall holds current PC and accepted steering metadata");

            final_pc = BASE + FINAL_INDEX * 4;
            clear_program();
            irom[FINAL_INDEX] = enc_jal(5'd0, 0);
            irom[FINAL_INDEX + 1] = enc_jal(5'd1, 0);
            reset_cpu();
            saw_redirect_update = 1'b0;
            saw_younger_update = 1'b0;
            begin : redirect_update_loop
                for (cycle = 0; cycle < 1500; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.branch_flush && dut.abtb_update_valid
                        && dut.abtb_update_pc == final_pc)
                        saw_redirect_update = 1'b1;
                    if (dut.abtb_update_valid
                        && dut.abtb_update_pc == final_pc + 32'd4)
                        saw_younger_update = 1'b1;
                    if (saw_redirect_update && dut.stage1_steer_source_abtb
                        && dut.pc == final_pc)
                        disable redirect_update_loop;
                end
            end
            check(saw_redirect_update,
                  "redirecting CFI did not train in the redirect cycle");
            check(!saw_younger_update,
                  "older slot0 redirect failed to suppress younger slot1 update");
            pass_case("redirect and confirmed ABTB update occur together");
            pass_case("older slot0 redirect suppresses younger slot1");
            pass_case("redirect to the same PC is a legal refetch and lookup");
        end
    endtask

    task automatic scenario_stage1_direction_pipeline;
        integer cycle;
        logic found;
        logic [7:0] ghr_before;
        logic [7:0] ghr_after;
        logic [7:0] expected_pht_index;
        logic [1:0] expected_pht_counter;
        logic [31:0] slot0_pc;
        logic [31:0] slot1_pc;
        logic [31:0] older_pc;
        logic [31:0] younger_pc;
        begin
            slot0_pc = BASE + PHT_SLOT1_INDEX * 4;
            slot1_pc = slot0_pc + 32'd4;
            clear_program();
            irom[PHT_SLOT1_INDEX] = enc_addi(5'd6, 5'd0, 1);
            irom[PHT_SLOT1_INDEX + 1] =
                enc_branch(3'b000, 5'd0, 5'd0, 12);
            reset_cpu();

            found = 1'b0;
            begin : slot1_update_loop
                for (cycle = 0; cycle < 900; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.stage1_direction_update_valid
                        && dut.pred_train_pc == slot1_pc) begin
                        check(dut.pred_train_from_s1,
                              "slot1 branch used slot0 update metadata");
                        check(dut.stage1_direction_update_index
                              == dut.ex_s1_stage1_pht_index
                              && dut.stage1_direction_update_counter
                                 == dut.ex_s1_stage1_pht_counter,
                              "slot1 PHT prediction-time metadata mismatch");
                        check(dut.pred_train_actual_taken
                              && dut.ex_s1_branch_redirect,
                              "slot1 taken branch did not redirect and train");
                        ghr_before =
                            dut.u_frontend_stage1_direction.committed_ghr;
                        expected_pht_index =
                            dut.stage1_direction_update_index;
                        expected_pht_counter =
                            dut.stage1_direction_update_counter;
                        found = 1'b1;
                        disable slot1_update_loop;
                    end
                end
            end
            check(found, "slot1 conditional branch did not update PHT/GHR");
            // The EX-aligned event remains visible through the legacy
            // observation probes.  Predictor state is intentionally written
            // from the registered event in the following cycle.
            @(negedge clk);
            check(dut.stage1_direction_write_valid,
                  "slot1 PHT event did not cross the registered write boundary");
            check(dut.stage1_direction_write_index
                  == expected_pht_index
                  && dut.stage1_direction_write_counter
                     == expected_pht_counter
                  && dut.stage1_direction_write_actual_taken,
                  "registered slot1 PHT write payload changed");
            @(posedge clk);
            #1;
            ghr_after = {ghr_before[6:0], 1'b1};
            check(dut.u_frontend_stage1_direction.committed_ghr == ghr_after,
                  "slot1 taken branch did not shift committed GHR");
            repeat (8) begin
                @(negedge clk);
                check(!dut.stage1_direction_update_valid,
                      "unexpected branch update after slot1 redirect");
                check(dut.u_frontend_stage1_direction.committed_ghr
                      == ghr_after,
                      "redirect restored or changed committed GHR");
            end
            pass_case("slot1 branch carries prediction-time PHT metadata to EX");
            pass_case("redirect updates but does not restore committed GHR");

            older_pc = BASE + PHT_OLDER_INDEX * 4;
            younger_pc = older_pc + 32'd4;
            clear_program();
            irom[PHT_OLDER_INDEX] =
                enc_branch(3'b000, 5'd0, 5'd0, 12);
            irom[PHT_OLDER_INDEX + 1] =
                enc_branch(3'b000, 5'd0, 5'd0, 0);
            reset_cpu();

            found = 1'b0;
            begin : older_update_loop
                for (cycle = 0; cycle < 1000; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.stage1_direction_update_valid
                        && dut.pred_train_pc == younger_pc)
                        fail("wrong-path younger slot1 branch updated PHT/GHR");
                    if (dut.stage1_direction_update_valid
                        && dut.pred_train_pc == older_pc) begin
                        check(!dut.pred_train_from_s1
                              && dut.pred_train_actual_taken
                              && dut.branch_flush,
                              "older slot0 branch update qualification mismatch");
                        found = 1'b1;
                        disable older_update_loop;
                    end
                end
            end
            check(found, "older slot0 branch did not reach confirmed update");
            repeat (40) begin
                @(negedge clk);
                check(!(dut.stage1_direction_update_valid
                        && dut.pred_train_pc == younger_pc),
                      "redirected younger branch trained after flush");
            end
            pass_case("older slot0 redirect suppresses wrong-path slot1 PHT update");
        end
    endtask

    task automatic scenario_stage1_direction_stall;
        integer cycle;
        logic found_lead;
        logic found_held_branch;
        logic found_update;
        logic [7:0] held_ghr;
        logic [31:0] updates_before;
        logic [31:0] lead_pc;
        logic [31:0] branch_pc;
        begin
            lead_pc = BASE + PHT_STALL_INDEX * 4;
            branch_pc = lead_pc + 32'd4;
            clear_program();
            // A same-pair LOAD-use remains unsupported, so this RAW dependency
            // prevents dual issue. Pulling cache_ready low after the LOAD
            // leaves EX2 lets the following branch enter EX2
            // on that edge and then remain there until the shared completion
            // condition is released.
            irom[PHT_STALL_INDEX] = enc_lw(5'd7, 5'd0, 0);
            irom[PHT_STALL_INDEX + 1] =
                enc_branch(3'b000, 5'd7, 5'd0, 12);
            reset_cpu();

            found_lead = 1'b0;
            begin : lead_loop
                for (cycle = 0; cycle < 1100; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.ex_valid && dut.ex_pc == lead_pc
                        && dut.mem_allowin) begin
                        @(posedge clk);
                        #1;
                        cache_ready = 1'b0;
                        found_lead = 1'b1;
                        disable lead_loop;
                    end
                end
            end
            check(found_lead, "did not intercept lead ALU before MEM");

            found_held_branch = 1'b0;
            begin : held_branch_loop
                for (cycle = 0; cycle < 80; cycle = cycle + 1) begin
                    @(negedge clk);
                    if (dut.ex_valid && dut.ex_pc == branch_pc
                        && dut.ex_is_conditional_control
                        && !dut.ex_ready_go_w) begin
                        held_ghr =
                            dut.u_frontend_stage1_direction.committed_ghr;
                        updates_before = dut.stage1_confirmed_branch_count;
                        repeat (4) begin
                            @(negedge clk);
                            check(dut.ex_valid && dut.ex_pc == branch_pc
                                  && !dut.ex_ready_go_w,
                                  "completion stall did not hold branch in EX2");
                            check(!dut.stage1_direction_update_valid,
                                  "stalled branch repeated PHT/GHR update");
                            check(dut.stage1_confirmed_branch_count
                                  == updates_before
                                  && dut.u_frontend_stage1_direction.committed_ghr
                                     == held_ghr,
                                  "stalled branch changed predictor state");
                        end
                        found_held_branch = 1'b1;
                        disable held_branch_loop;
                    end
                end
            end
            check(found_held_branch,
                  "branch did not remain in EX2 while completion was stalled");

            cache_ready = 1'b1;
            #1;
            found_update = dut.stage1_direction_update_valid
                         && dut.pred_train_pc == branch_pc;
            check(found_update, "released branch did not update PHT/GHR");
            check(dut.stage1_confirmed_branch_count == updates_before,
                  "branch counter advanced before confirmed edge");
            @(posedge clk);
            #1;
            check(dut.stage1_confirmed_branch_count == updates_before + 32'd1,
                  "released branch did not update exactly once");
            repeat (12) begin
                @(negedge clk);
                check(!(dut.stage1_direction_update_valid
                        && dut.pred_train_pc == branch_pc),
                      "released branch produced duplicate predictor update");
            end
            pass_case("backend stall holds branch metadata and updates once on fire");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cache_rdata = 32'd0;
        cache_ready = 1'b1;
        mmio_rdata = 32'd0;
        timer_irq_pending = 1'b0;
        case_count = 0;

        scenario_bank0_jal();
        scenario_bank1_jal();
        scenario_pc2_bank1_first();
        scenario_calls();
        scenario_unsupported_types();
        scenario_program_order();
        scenario_wrong_target();
        scenario_same_instruction_override();
        scenario_stall_wrap_redirect();
        scenario_stage1_direction_pipeline();
        scenario_stage1_direction_stall();

        check(case_count >= 28, "steering TB did not cover all required cases");
        repeat (2) @(negedge clk);
        check(dut.stage1_confirmed_branch_count != 0,
              "Stage-1 direction confirmed-branch counter remained empty");
        $display("[PASS] frontend ABTB/PHT branch steering integration test (%0d cases)",
                 case_count);
        $finish;
    end

endmodule
