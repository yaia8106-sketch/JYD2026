`timescale 1ns/1ps

module tb_icache_metadata;
    import cpu_defs::*;

    logic clk;
    logic rst_n;

    logic        irom_req_valid;
    logic        irom_req_ready;
    logic [31:0] irom_req_addr;
    logic        irom_req_kill;
    logic        irom_resp_valid;
    logic [63:0] irom_resp_data;
    logic [13:0] irom_resp_predecode;
    logic [ 1:0] irom_resp_resp;

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic [31:0] mem_req_addr;
    logic [ 7:0] mem_req_len;
    logic [ 1:0] mem_req_burst;
    logic        mem_rd_valid;
    logic        mem_rd_ready;
    logic [31:0] mem_rd_data;
    logic        mem_rd_last;
    logic [ 1:0] mem_rd_resp;

    logic [13:0] decoded_response_predecode;
    frontend_icache_predecode_t response_low_cached;
    frontend_icache_predecode_t response_high_cached;
    frontend_predecode_t response_low_expanded;
    frontend_predecode_t response_high_expanded;
    frontend_pair_meta_t response_low_pair_direct;
    frontend_pair_meta_t response_high_pair_direct;
    logic [31:0] class_word [0:7];
    logic [31:0] kind_word [0:19];
    icache_inst_kind_t kind_expected [0:19];
    logic [18:0] kind_roundtrip_seen;

    // Short aliases keep the refill-order scenarios readable; each name now
    // denotes the exact kind of its representative instruction.
    localparam icache_inst_kind_t ICACHE_CLASS_ALU_RR =
        ICACHE_KIND_ALU_RR;
    localparam icache_inst_kind_t ICACHE_CLASS_ALU_IMM =
        ICACHE_KIND_ALU_IMM;
    localparam icache_inst_kind_t ICACHE_CLASS_UPPER_IMM =
        ICACHE_KIND_UPPER_IMM;
    localparam icache_inst_kind_t ICACHE_CLASS_LOAD = ICACHE_KIND_LOAD;
    localparam icache_inst_kind_t ICACHE_CLASS_STORE = ICACHE_KIND_STORE;
    localparam icache_inst_kind_t ICACHE_CLASS_MULDIV = ICACHE_KIND_MUL;
    localparam icache_inst_kind_t ICACHE_CLASS_CFI =
        ICACHE_KIND_CONDITIONAL;
    localparam icache_inst_kind_t ICACHE_CLASS_OTHER =
        ICACHE_KIND_PRIV_FLOW;

    integer errors;
    integer response_count;

    // This test intentionally preserves the 8 KiB organization because its
    // white-box tag/index checks exercise the ninth index bit and 7-bit tag.
    // The configuration-matrix test separately covers the 16 KiB default.
    icache #(
        .CACHE_BYTES(8192),
        .WAYS       (1)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .irom_req_valid     (irom_req_valid),
        .irom_req_ready     (irom_req_ready),
        .irom_req_addr      (irom_req_addr),
        .irom_req_kill      (irom_req_kill),
        .irom_resp_valid    (irom_resp_valid),
        .irom_resp_data     (irom_resp_data),
        .irom_resp_predecode(irom_resp_predecode),
        .irom_resp_resp     (irom_resp_resp),
        .mem_req_valid      (mem_req_valid),
        .mem_req_ready      (mem_req_ready),
        .mem_req_addr       (mem_req_addr),
        .mem_req_len        (mem_req_len),
        .mem_req_burst      (mem_req_burst),
        .mem_rd_valid       (mem_rd_valid),
        .mem_rd_ready       (mem_rd_ready),
        .mem_rd_data        (mem_rd_data),
        .mem_rd_last        (mem_rd_last),
        .mem_rd_resp        (mem_rd_resp)
    );

    loongarch_icache_block_predecode u_response_reference (
        .block_data     (irom_resp_data),
        .block_metadata (decoded_response_predecode)
    );

    assign response_low_cached = irom_resp_predecode[6:0];
    assign response_high_cached = irom_resp_predecode[13:7];

    isa_cached_predecode_expand u_response_low_expand (
        .inst          (irom_resp_data[31:0]),
        .cached        (response_low_cached),
        .pred_taken    (1'b1),
        .expanded      (response_low_expanded),
        .pair_metadata (response_low_pair_direct)
    );

    isa_cached_predecode_expand u_response_high_expand (
        .inst          (irom_resp_data[63:32]),
        .cached        (response_high_cached),
        .pred_taken    (1'b0),
        .expanded      (response_high_expanded),
        .pair_metadata (response_high_pair_direct)
    );

    always #5 clk = ~clk;

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
        input logic [5:0]  op_31_26,
        input logic [3:0]  op_25_22,
        input logic [11:0] immediate,
        input logic [4:0]  rj,
        input logic [4:0]  rd
    );
        enc_i12 = {op_31_26, op_25_22, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] enc_upper(
        input logic [5:0]  op_31_26,
        input logic [19:0] immediate,
        input logic [4:0]  rd
    );
        enc_upper = {op_31_26, 1'b0, immediate, rd};
    endfunction

    function automatic logic [31:0] enc_i16(
        input logic [5:0]  op_31_26,
        input logic [15:0] immediate,
        input logic [4:0]  rj,
        input logic [4:0]  rd
    );
        enc_i16 = {op_31_26, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] enc_i26(
        input logic [5:0]  op_31_26,
        input logic [25:0] immediate
    );
        enc_i26 = {op_31_26, immediate[15:0], immediate[25:16]};
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("[FAIL] %s at %0t", message, $time);
            end
        end
    endtask

    function automatic frontend_pair_meta_t pair_meta_reference(
        input frontend_predecode_t decoded,
        input logic                pred_taken,
        input logic                writes_dst,
        input logic                force_single
    );
        begin
            pair_meta_reference = '0;
            pair_meta_reference.pred_taken = pred_taken;
            pair_meta_reference.force_single = force_single;
            pair_meta_reference.is_muldiv = decoded.is_muldiv;
            pair_meta_reference.is_alu_type = decoded.is_alu_type;
            pair_meta_reference.is_lsu = decoded.is_lsu;
            pair_meta_reference.is_cfi = decoded.is_cfi;
            pair_meta_reference.writes_dst = writes_dst;
            pair_meta_reference.uses_src0 = decoded.uses_src0;
            pair_meta_reference.uses_src1 = decoded.uses_src1;
            pair_meta_reference.dst_addr = decoded.dst_addr;
            pair_meta_reference.src0_addr = decoded.src0_addr;
            pair_meta_reference.src1_addr = decoded.src1_addr;
        end
    endfunction

    // Every response, including critical-first and refill-buffer responses,
    // must carry exactly the metadata that direct decoding of its data gives.
    always @(negedge clk) begin
        if (rst_n && irom_resp_valid) begin
            response_count = response_count + 1;
            check(irom_resp_predecode === decoded_response_predecode,
                  "ICache response metadata/data mismatch");
            check(response_low_pair_direct === pair_meta_reference(
                      response_low_expanded,
                      1'b1,
                      response_low_cached.writes_dst,
                      response_low_cached.block_younger),
                  "low direct pair metadata disagrees with full expansion");
            check(response_high_pair_direct === pair_meta_reference(
                      response_high_expanded,
                      1'b0,
                      response_high_cached.writes_dst,
                      response_high_cached.block_younger),
                  "high direct pair metadata disagrees with full expansion");
        end
    end

    task automatic issue_irom(input logic [31:0] addr);
        integer guard;
        begin
            @(negedge clk);
            irom_req_addr = addr;
            irom_req_valid = 1'b1;
            guard = 0;
            do begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 40)
                    $fatal(1, "[FAIL] ICache request timeout addr=%08x", addr);
            end while (!irom_req_ready);
            @(negedge clk);
            irom_req_valid = 1'b0;
        end
    endtask

    task automatic accept_refill_request(input logic [31:0] expected_addr);
        integer guard;
        begin
            guard = 0;
            while (!mem_req_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 40)
                    $fatal(1,
                           "[FAIL] expected refill request timeout addr=%08x",
                           expected_addr);
            end
            #1;
            check(mem_req_addr == expected_addr, "refill address mismatch");
            check(mem_req_len == 8'd3, "refill length was not four beats");
            check(mem_req_burst == 2'b10, "refill was not a WRAP burst");
            mem_req_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mem_req_ready = 1'b0;
        end
    endtask

    task automatic start_refill(input logic [31:0] addr);
        begin
            fork
                issue_irom(addr);
                accept_refill_request(addr);
            join
        end
    endtask

    task automatic send_refill_beat(
        input logic [31:0] data,
        input logic [ 1:0] resp,
        input logic        last
    );
        integer guard;
        begin
            @(negedge clk);
            mem_rd_data = data;
            mem_rd_resp = resp;
            mem_rd_last = last;
            mem_rd_valid = 1'b1;
            guard = 0;
            do begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 40)
                    $fatal(1, "[FAIL] refill data handshake timeout");
            end while (!mem_rd_ready);
            @(negedge clk);
            mem_rd_valid = 1'b0;
            mem_rd_resp = 2'b00;
            mem_rd_last = 1'b0;
        end
    endtask

    task automatic expect_response(
        input logic [63:0]         expected_data,
        input icache_inst_kind_t   expected_low_kind,
        input icache_inst_kind_t   expected_high_kind,
        input logic [1:0]          expected_resp,
        input string               name
    );
        integer guard;
        frontend_icache_predecode_t low_metadata;
        frontend_icache_predecode_t high_metadata;
        begin
            guard = 0;
            while (!irom_resp_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "[FAIL] response timeout: %s", name);
            end
            #1;
            check(irom_resp_data === expected_data,
                  $sformatf("%s data", name));
            low_metadata = irom_resp_predecode[6:0];
            high_metadata = irom_resp_predecode[13:7];
            check(low_metadata.inst_kind === expected_low_kind,
                  $sformatf("%s low instruction kind", name));
            check(high_metadata.inst_kind === expected_high_kind,
                  $sformatf("%s high instruction kind", name));
            check(irom_resp_resp === expected_resp,
                  $sformatf("%s response code", name));
        end
    endtask

    task automatic expect_local_hit(
        input logic [31:0]         addr,
        input logic [63:0]         expected_data,
        input icache_inst_kind_t   expected_low_kind,
        input icache_inst_kind_t   expected_high_kind,
        input string               name
    );
        integer guard;
        begin
            @(negedge clk);
            irom_req_addr = addr;
            irom_req_valid = 1'b1;
            guard = 0;
            do begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "[FAIL] local-hit request timeout: %s", name);
            end while (!irom_req_ready);
            @(negedge clk);
            irom_req_valid = 1'b0;
            #1;
            check(irom_resp_valid,
                  $sformatf("%s did not return in one lookup cycle", name));
            check(!mem_req_valid,
                  $sformatf("%s unexpectedly started a refill", name));
            if (irom_resp_valid)
                expect_response(expected_data, expected_low_kind,
                                expected_high_kind, 2'b00, name);
        end
    endtask

    // The timing-oriented implementation publishes tag/valid one edge after
    // the final refill beat.  A request arriving in that single-cycle window
    // must be satisfied by the completed refill buffer; otherwise it would
    // observe the intentionally stale valid bit and launch a duplicate miss.
    task automatic expect_commit_window_hit(
        input logic [31:0]         addr,
        input logic [63:0]         expected_data,
        input icache_inst_kind_t   expected_low_kind,
        input icache_inst_kind_t   expected_high_kind,
        input string               name
    );
        integer guard;
        begin
            // The caller has just returned from the final refill-beat task at
            // a falling edge, so inspect and drive this window without first
            // waiting for another edge.
            #1;
            check(dut.tag_commit_pending_q,
                  $sformatf("%s did not expose delayed commit window", name));
            check(!dut.line_valid_q[addr[12:4]],
                  $sformatf("%s published valid before commit edge", name));

            irom_req_addr = addr;
            irom_req_valid = 1'b1;
            guard = 0;
            do begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1,
                           "[FAIL] commit-window request timeout: %s",
                           name);
            end while (!irom_req_ready);

            @(negedge clk);
            irom_req_valid = 1'b0;
            #1;
            check(irom_resp_valid,
                  $sformatf("%s was not served by refill buffer", name));
            check(!mem_req_valid,
                  $sformatf("%s launched a duplicate refill", name));
            if (irom_resp_valid)
                expect_response(expected_data, expected_low_kind,
                                expected_high_kind, 2'b00, name);
        end
    endtask

    task automatic expect_tag_entry(
        input logic [8:0]          index,
        input logic [6:0]          tag,
        input icache_inst_kind_t   kind0,
        input icache_inst_kind_t   kind1,
        input icache_inst_kind_t   kind2,
        input icache_inst_kind_t   kind3,
        input string               name
    );
        logic [18:0] expected_payload;
        begin
            expected_payload = {
                kind3[2:0], kind2[2:0], kind1[2:0], kind0[2:0], tag
            };
            check(dut.line_valid_q[index],
                  $sformatf("%s valid bit", name));
            check(dut.tag_mem[index] === expected_payload,
                  $sformatf("%s {kind-low,tag} LUTRAM payload", name));
        end
    endtask

    // The five kind bits are physically split: kind[2:0] shares the shortened
    // tag LUTRAM while kind[4:3] occupies data-BRAM parity. Exercise every
    // defined kind through refill, atomic publication, and both local-hit
    // blocks so a packing/order error on either side cannot hide behind the
    // combinational predecode equivalence test.
    task automatic exercise_exact_kind_line(
        input integer      base_kind,
        input logic [31:0] line_addr
    );
        begin
            start_refill(line_addr);
            send_refill_beat(kind_word[base_kind], 2'b00, 1'b0);
            send_refill_beat(kind_word[base_kind + 1], 2'b00, 1'b0);
            expect_response(
                {kind_word[base_kind + 1], kind_word[base_kind]},
                kind_expected[base_kind], kind_expected[base_kind + 1],
                2'b00, $sformatf("kind line %0d critical response",
                                  base_kind / 4)
            );
            send_refill_beat(kind_word[base_kind + 2], 2'b00, 1'b0);
            send_refill_beat(kind_word[base_kind + 3], 2'b00, 1'b1);
            expect_commit_window_hit(
                line_addr,
                {kind_word[base_kind + 1], kind_word[base_kind]},
                kind_expected[base_kind], kind_expected[base_kind + 1],
                $sformatf("kind line %0d delayed-commit hit", base_kind / 4)
            );
            repeat (1) @(posedge clk);

            expect_tag_entry(
                line_addr[12:4], line_addr[19:13],
                kind_expected[base_kind],
                kind_expected[base_kind + 1],
                kind_expected[base_kind + 2],
                kind_expected[base_kind + 3],
                $sformatf("kind line %0d physical payload", base_kind / 4)
            );
            expect_local_hit(
                line_addr,
                {kind_word[base_kind + 1], kind_word[base_kind]},
                kind_expected[base_kind], kind_expected[base_kind + 1],
                $sformatf("kind line %0d lower local hit", base_kind / 4)
            );
            expect_local_hit(
                line_addr + 32'd8,
                {kind_word[base_kind + 3], kind_word[base_kind + 2]},
                kind_expected[base_kind + 2],
                kind_expected[base_kind + 3],
                $sformatf("kind line %0d upper local hit", base_kind / 4)
            );

            for (int offset = 0; offset < 4; offset++) begin
                if ((base_kind + offset) < 19)
                    kind_roundtrip_seen[base_kind + offset] = 1'b1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        irom_req_valid = 1'b0;
        irom_req_addr = 32'd0;
        irom_req_kill = 1'b0;
        mem_req_ready = 1'b0;
        mem_rd_valid = 1'b0;
        mem_rd_data = 32'd0;
        mem_rd_last = 1'b0;
        mem_rd_resp = 2'b00;
        errors = 0;
        response_count = 0;
        kind_roundtrip_seen = '0;

        // Representative exact kinds with nontrivial register
        // fields so reconstructed source/destination metadata is exercised.
        class_word[0] = enc_rr(2'h1, 5'h00, 5'd18, 5'd17, 5'd15);
        class_word[1] = enc_i12(6'h00, 4'ha, 12'h7f1, 5'd9, 5'd8);
        class_word[2] = enc_upper(6'h05, 20'habcde, 5'd7);
        class_word[3] = enc_i12(6'h0a, 4'h2, 12'h024, 5'd6, 5'd5);
        class_word[4] = enc_i12(6'h0a, 4'h6, 12'hff8, 5'd4, 5'd3);
        class_word[5] = enc_rr(2'h1, 5'h18, 5'd20, 5'd2, 5'd1);
        class_word[6] = enc_i16(6'h16, 16'h0012, 5'd13, 5'd12);
        class_word[7] = 32'h0648_3800;

        // One representative of every exact kind. Entry 19 pads the fifth
        // four-word line with a normal ALU-immediate instruction.
        kind_word[0]  = 32'hffff_ffff;
        kind_word[1]  = enc_rr(2'h1, 5'h00, 5'd18, 5'd17, 5'd15);
        kind_word[2]  = enc_i12(6'h00, 4'ha, 12'h7f1, 5'd9, 5'd8);
        kind_word[3]  = enc_upper(6'h05, 20'habcde, 5'd7);
        kind_word[4]  = enc_i12(6'h0a, 4'h2, 12'h024, 5'd6, 5'd5);
        kind_word[5]  = enc_i12(6'h0a, 4'h6, 12'hff8, 5'd4, 5'd3);
        kind_word[6]  = enc_rr(2'h1, 5'h18, 5'd20, 5'd2, 5'd1);
        kind_word[7]  = enc_rr(2'h2, 5'h00, 5'd5, 5'd4, 5'd3);
        kind_word[8]  = enc_i16(6'h16, 16'h0012, 5'd13, 5'd12);
        kind_word[9]  = enc_i26(6'h14, 26'h000_0002);
        kind_word[10] = enc_i26(6'h15, 26'h000_0002);
        kind_word[11] = enc_i16(6'h13, 16'h0002, 5'd6, 5'd1);
        kind_word[12] = {8'h04, 14'h006, 5'd0, 5'd7};
        kind_word[13] = {8'h04, 14'h006, 5'd1, 5'd7};
        kind_word[14] = {8'h04, 14'h005, 5'd9, 5'd7};
        kind_word[15] = 32'h0000_600d;
        kind_word[16] = 32'h0000_6180;
        kind_word[17] = 32'h0000_6d91;
        kind_word[18] = 32'h0648_3800;
        kind_word[19] = 32'h0340_0000;

        kind_expected[0]  = ICACHE_KIND_ILLEGAL;
        kind_expected[1]  = ICACHE_KIND_ALU_RR;
        kind_expected[2]  = ICACHE_KIND_ALU_IMM;
        kind_expected[3]  = ICACHE_KIND_UPPER_IMM;
        kind_expected[4]  = ICACHE_KIND_LOAD;
        kind_expected[5]  = ICACHE_KIND_STORE;
        kind_expected[6]  = ICACHE_KIND_MUL;
        kind_expected[7]  = ICACHE_KIND_DIVMOD;
        kind_expected[8]  = ICACHE_KIND_CONDITIONAL;
        kind_expected[9]  = ICACHE_KIND_BRANCH;
        kind_expected[10] = ICACHE_KIND_BRANCH_LINK;
        kind_expected[11] = ICACHE_KIND_JIRL;
        kind_expected[12] = ICACHE_KIND_CSR_READ;
        kind_expected[13] = ICACHE_KIND_CSR_WRITE;
        kind_expected[14] = ICACHE_KIND_CSR_EXCHANGE;
        kind_expected[15] = ICACHE_KIND_COUNTER;
        kind_expected[16] = ICACHE_KIND_COUNTER_ID;
        kind_expected[17] = ICACHE_KIND_CPUCFG;
        kind_expected[18] = ICACHE_KIND_PRIV_FLOW;
        kind_expected[19] = ICACHE_KIND_ALU_IMM;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Lower critical block: verify early response, refill-buffer reuse,
        // pending request for the not-yet-arrived block, and atomic tag/class
        // publication only after the fourth beat.
        $display("[INFO] all classes, lower critical block, and atomic commit");
        start_refill(32'h1c00_0000);
        send_refill_beat(class_word[0], 2'b00, 1'b0);
        send_refill_beat(class_word[1], 2'b00, 1'b0);
        expect_response({class_word[1], class_word[0]},
                        ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                        2'b00, "lower critical-first response");
        check(!dut.line_valid_q[9'h000],
              "line became valid before the complete refill");

        expect_local_hit(32'h1c00_0000,
                         {class_word[1], class_word[0]},
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         "in-flight refill-buffer hit");

        issue_irom(32'h1c00_0008);
        send_refill_beat(class_word[2], 2'b00, 1'b0);
        send_refill_beat(class_word[3], 2'b00, 1'b1);
        expect_response({class_word[3], class_word[2]},
                        ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                        2'b00, "pending second-block response");
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h000, 7'h00,
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "lower-first line");
        expect_local_hit(32'h1c00_0008,
                         {class_word[3], class_word[2]},
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "lower-first completed upper block");

        // Upper critical block reverses refill order.  The final LUTRAM entry
        // must still be in architectural instruction order.
        $display("[INFO] upper critical WRAP class ordering");
        start_refill(32'h1c00_0018);
        send_refill_beat(class_word[6], 2'b00, 1'b0);
        send_refill_beat(class_word[7], 2'b00, 1'b0);
        expect_response({class_word[7], class_word[6]},
                        ICACHE_CLASS_CFI, ICACHE_CLASS_OTHER,
                        2'b00, "upper critical-first response");
        check(!dut.line_valid_q[9'h001],
              "reverse-refill line became valid after two beats");
        expect_local_hit(32'h1c00_0018,
                         {class_word[7], class_word[6]},
                         ICACHE_CLASS_CFI, ICACHE_CLASS_OTHER,
                         "upper in-flight refill-buffer hit");
        send_refill_beat(class_word[4], 2'b00, 1'b0);
        send_refill_beat(class_word[5], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h001, 7'h00,
                         ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                         ICACHE_CLASS_CFI, ICACHE_CLASS_OTHER,
                         "upper-first line");
        expect_local_hit(32'h1c00_0010,
                         {class_word[5], class_word[4]},
                         ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                         "upper-first completed lower block");
        expect_local_hit(32'h1c00_0018,
                         {class_word[7], class_word[6]},
                         ICACHE_CLASS_CFI, ICACHE_CLASS_OTHER,
                         "upper-first completed upper block");

        $display("[INFO] all nineteen exact kinds survive physical metadata split");
        for (int kind_line = 0; kind_line < 5; kind_line++) begin
            exercise_exact_kind_line(
                kind_line * 4,
                32'h1c00_4000 + (kind_line * 16)
            );
        end
        check(&kind_roundtrip_seen,
              "not every exact ICache kind completed a physical round trip");

        // Address bit 12 is the new ninth index bit. The lower and upper 4 KiB
        // halves must coexist instead of aliasing as they did in the 4 KiB
        // organization.
        $display("[INFO] 8 KiB ninth set-index bit");
        start_refill(32'h1c00_0000);
        send_refill_beat(class_word[0], 2'b00, 1'b0);
        send_refill_beat(class_word[1], 2'b00, 1'b0);
        expect_response({class_word[1], class_word[0]},
                        ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                        2'b00, "lower 4 KiB half response");
        send_refill_beat(class_word[2], 2'b00, 1'b0);
        send_refill_beat(class_word[3], 2'b00, 1'b1);
        repeat (2) @(posedge clk);

        start_refill(32'h1c00_1000);
        send_refill_beat(class_word[4], 2'b00, 1'b0);
        send_refill_beat(class_word[5], 2'b00, 1'b0);
        expect_response({class_word[5], class_word[4]},
                        ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                        2'b00, "upper 4 KiB half response");
        send_refill_beat(class_word[6], 2'b00, 1'b0);
        send_refill_beat(class_word[7], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h000, 7'h00,
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "lower 4 KiB half resident line");
        expect_tag_entry(9'h100, 7'h00,
                         ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                         ICACHE_CLASS_CFI, ICACHE_CLASS_OTHER,
                         "upper 4 KiB half resident line");
        expect_local_hit(32'h1c00_0000,
                         {class_word[1], class_word[0]},
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         "lower 4 KiB half preserved");
        expect_local_hit(32'h1c00_1000,
                         {class_word[5], class_word[4]},
                         ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                         "upper 4 KiB half preserved");

        // Same index but a different retained [19:13] tag must replace the
        // line.  Re-requesting the original address must therefore refill.
        $display("[INFO] in-window compressed-tag conflict");
        start_refill(32'h1c00_2000);
        send_refill_beat(class_word[4], 2'b00, 1'b0);
        send_refill_beat(class_word[5], 2'b00, 1'b0);
        expect_response({class_word[5], class_word[4]},
                        ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                        2'b00, "conflicting-tag critical response");
        send_refill_beat(class_word[6], 2'b00, 1'b0);
        send_refill_beat(class_word[7], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h000, 7'h01,
                         ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                         ICACHE_CLASS_CFI, ICACHE_CLASS_OTHER,
                         "conflicting-tag replacement");

        start_refill(32'h1c00_0000);
        send_refill_beat(class_word[0], 2'b00, 1'b0);
        send_refill_beat(class_word[1], 2'b00, 1'b0);
        expect_response({class_word[1], class_word[0]},
                        ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                        2'b00, "evicted-tag re-request");
        send_refill_beat(class_word[2], 2'b00, 1'b0);
        send_refill_beat(class_word[3], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h000, 7'h00,
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "restored base line");

        // Both exact boundaries of 0x1c0xxxxx are checked.  Outside-window
        // responses are forwarded but must neither allocate nor disturb the
        // resident line with the same shortened tag/index.
        $display("[INFO] one-megabyte cache window boundaries");
        start_refill(32'h1c0f_fff0);
        send_refill_beat(class_word[0], 2'b00, 1'b0);
        send_refill_beat(class_word[1], 2'b00, 1'b0);
        expect_response({class_word[1], class_word[0]},
                        ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                        2'b00, "last in-window line response");
        send_refill_beat(class_word[2], 2'b00, 1'b0);
        send_refill_beat(class_word[3], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h1ff, 7'h7f,
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "last in-window line");

        start_refill(32'h1bff_fff8);
        send_refill_beat(class_word[6], 2'b00, 1'b0);
        send_refill_beat(class_word[7], 2'b00, 1'b0);
        expect_response({class_word[7], class_word[6]},
                        ICACHE_CLASS_CFI, ICACHE_CLASS_OTHER,
                        2'b00, "below-window response");
        send_refill_beat(class_word[4], 2'b00, 1'b0);
        send_refill_beat(class_word[5], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h1ff, 7'h7f,
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "below-window preservation");
        expect_local_hit(32'h1c0f_fff8,
                         {class_word[3], class_word[2]},
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "last in-window line after lower alias");

        start_refill(32'h1c10_0000);
        send_refill_beat(class_word[4], 2'b00, 1'b0);
        send_refill_beat(class_word[5], 2'b00, 1'b0);
        expect_response({class_word[5], class_word[4]},
                        ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                        2'b00, "above-window response");
        send_refill_beat(class_word[6], 2'b00, 1'b0);
        send_refill_beat(class_word[7], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        // A second request proves that the completed refill buffer is not an
        // accidental one-line cache for excluded addresses.
        start_refill(32'h1c10_0000);
        send_refill_beat(class_word[0], 2'b00, 1'b0);
        send_refill_beat(class_word[1], 2'b00, 1'b0);
        expect_response({class_word[1], class_word[0]},
                        ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                        2'b00, "repeated above-window response");
        send_refill_beat(class_word[2], 2'b00, 1'b0);
        send_refill_beat(class_word[3], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h000, 7'h00,
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "above-window preservation");
        expect_local_hit(32'h1c00_0000,
                         {class_word[1], class_word[0]},
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         "base line after upper alias");

        // An error arriving only in the noncritical half must prevent the tag
        // and all 12 class bits from becoming valid.  The critical response
        // was already returned successfully, so only a repeated bus request
        // can prove that no complete line was committed.
        $display("[INFO] late refill error suppresses tag/class commit");
        start_refill(32'h1c00_2020);
        send_refill_beat(class_word[0], 2'b00, 1'b0);
        send_refill_beat(class_word[1], 2'b00, 1'b0);
        expect_response({class_word[1], class_word[0]},
                        ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                        2'b00, "pre-error critical response");
        send_refill_beat(class_word[2], 2'b00, 1'b0);
        send_refill_beat(class_word[3], 2'b10, 1'b1);
        repeat (2) @(posedge clk);
        check(!dut.line_valid_q[9'h002],
              "late refill error incorrectly validated the line");

        start_refill(32'h1c00_2020);
        send_refill_beat(class_word[4], 2'b00, 1'b0);
        send_refill_beat(class_word[5], 2'b00, 1'b0);
        expect_response({class_word[5], class_word[4]},
                        ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                        2'b00, "post-error retry response");
        send_refill_beat(class_word[6], 2'b00, 1'b0);
        send_refill_beat(class_word[7], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h002, 7'h01,
                         ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                         ICACHE_CLASS_CFI, ICACHE_CLASS_OTHER,
                         "post-error successful retry");
        expect_local_hit(32'h1c00_2020,
                         {class_word[5], class_word[4]},
                         ICACHE_CLASS_STORE, ICACHE_CLASS_MULDIV,
                         "post-error retry local hit");

        // Data, tag and class payload registers intentionally have no reset
        // mux.  Only validity state is reset, so prove that stale payload bits
        // cannot create a hit after reset deassertion.
        $display("[INFO] valid-only reset contains stale tag/class payload");
        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        check(dut.line_valid_q == '0,
              "reset did not clear all ICache line-valid bits");
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        start_refill(32'h1c00_2020);
        send_refill_beat(class_word[0], 2'b00, 1'b0);
        send_refill_beat(class_word[1], 2'b00, 1'b0);
        expect_response({class_word[1], class_word[0]},
                        ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                        2'b00, "post-reset stale-payload containment");
        send_refill_beat(class_word[2], 2'b00, 1'b0);
        send_refill_beat(class_word[3], 2'b00, 1'b1);
        repeat (2) @(posedge clk);
        expect_tag_entry(9'h002, 7'h01,
                         ICACHE_CLASS_ALU_RR, ICACHE_CLASS_ALU_IMM,
                         ICACHE_CLASS_UPPER_IMM, ICACHE_CLASS_LOAD,
                         "post-reset refill");

        repeat (3) @(posedge clk);
        check(response_count >= 35,
              "too few ICache metadata response paths were exercised");
        if (errors == 0)
            $display("[PASS] NSCSCC ICache shortened-tag/class metadata test responses=%0d",
                     response_count);
        else
            $fatal(1, "[FAIL] NSCSCC ICache metadata test errors=%0d",
                   errors);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "[FAIL] NSCSCC ICache metadata test timeout");
    end

endmodule
