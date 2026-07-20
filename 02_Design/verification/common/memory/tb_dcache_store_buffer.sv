`timescale 1ns / 1ps

module tb_dcache_store_buffer;
    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic        push;
    logic [31:0] push_addr;
    logic [ 3:0] push_wea;
    logic [31:0] push_data;
    logic        pop;
    wire         any_pending;
    wire         full;
    wire  [31:0] drain_addr;
    wire  [ 3:0] drain_wea;
    wire  [31:0] drain_data;
    logic [15:0] drain_compare_addr;
    wire         drain_addr_match;
    logic [31:0] lookup_addr;
    logic [ 3:0] lookup_mask;
    wire         lookup_covers;
    wire  [31:0] lookup_data;
    logic        refill_capture;
    logic [31:0] refill_line_addr;
    logic [ 1:0] refill_word;
    logic [31:0] refill_base_data;
    wire  [31:0] refill_merged_data;
    wire  [ 1:0] pending_q;
    wire  [ 1:0] recent_valid_q;
    wire         alloc_sel;
    wire         drain_sel;

    logic [ 1:0] model_pending;
    logic [ 1:0] model_recent;
    logic        model_alloc;
    logic [31:0] model_addr [1:0];
    logic [ 3:0] model_wea  [1:0];
    logic [31:0] model_data [1:0];
    logic        model_refill_valid [1:0];
    logic [ 1:0] model_refill_word  [1:0];
    logic [ 3:0] model_refill_wea   [1:0];
    logic [31:0] model_refill_data  [1:0];

    logic [3:0] pending_seen;
    logic       pop_only_seen;
    logic       push_only_seen;
    logic       push_pop_seen;
    logic       full_replace_seen;
    integer     cycles_checked;
    integer     random_seed;
    integer     i;

    logic       random_push;
    logic       random_pop;
    logic       random_sel;
    logic [31:0] random_addr;
    logic [ 3:0] random_wea;
    logic [31:0] random_data;
    logic [15:0] random_compare;
    logic [31:0] random_lookup_addr;
    logic [ 3:0] random_lookup_mask;
    logic        random_capture;
    logic [31:0] random_line_addr;
    logic [ 1:0] random_word;
    logic [31:0] random_base;

    always #5 clk = ~clk;

    dcache_store_buffer dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .push               (push),
        .push_addr          (push_addr),
        .push_wea           (push_wea),
        .push_data          (push_data),
        .pop                (pop),
        .any_pending        (any_pending),
        .full               (full),
        .drain_addr         (drain_addr),
        .drain_wea          (drain_wea),
        .drain_data         (drain_data),
        .drain_compare_addr (drain_compare_addr),
        .drain_addr_match   (drain_addr_match),
        .lookup_addr        (lookup_addr),
        .lookup_mask        (lookup_mask),
        .lookup_covers      (lookup_covers),
        .lookup_data        (lookup_data),
        .refill_capture     (refill_capture),
        .refill_line_addr   (refill_line_addr),
        .refill_word        (refill_word),
        .refill_base_data   (refill_base_data),
        .refill_merged_data (refill_merged_data),
        .pending_q          (pending_q),
        .recent_valid_q     (recent_valid_q),
        .alloc_sel          (alloc_sel),
        .drain_sel          (drain_sel)
    );

    function automatic [31:0] merge_bytes (
        input logic [31:0] base,
        input logic [31:0] overlay,
        input logic [ 3:0] strobe
    );
        begin
            merge_bytes[ 7: 0] = strobe[0] ? overlay[ 7: 0] : base[ 7: 0];
            merge_bytes[15: 8] = strobe[1] ? overlay[15: 8] : base[15: 8];
            merge_bytes[23:16] = strobe[2] ? overlay[23:16] : base[23:16];
            merge_bytes[31:24] = strobe[3] ? overlay[31:24] : base[31:24];
        end
    endfunction

    function automatic logic model_drain_sel;
        begin
            model_drain_sel = (model_pending == 2'b11)
                            ? model_alloc : model_pending[1];
        end
    endfunction

    task automatic fail(input [8*96-1:0] message);
        begin
            $display("[FAIL] dcache_store_buffer cycle=%0d: %0s",
                     cycles_checked, message);
            $fatal(1);
        end
    endtask

    task automatic reset_model;
        begin
            model_pending = 2'b00;
            model_recent = 2'b00;
            model_alloc = 1'b0;
            for (integer e = 0; e < 2; e = e + 1) begin
                model_addr[e] = 32'd0;
                model_wea[e] = 4'd0;
                model_data[e] = 32'd0;
                model_refill_valid[e] = 1'b0;
                model_refill_word[e] = 2'd0;
                model_refill_wea[e] = 4'd0;
                model_refill_data[e] = 32'd0;
            end
        end
    endtask

    task automatic check_outputs;
        logic selected;
        logic match0;
        logic match1;
        logic [3:0] lookup_entry_mask0;
        logic [3:0] lookup_entry_mask1;
        logic [3:0] lookup_covered_mask;
        logic [31:0] lookup_after0;
        logic [31:0] lookup_after1;
        logic [31:0] expected_lookup;
        logic expected_covers;
        logic [3:0] refill_strobe0;
        logic [3:0] refill_strobe1;
        logic [31:0] expected_refill;
        begin
            selected = model_drain_sel();
            match0 = (model_addr[0][17:2] == drain_compare_addr);
            match1 = (model_addr[1][17:2] == drain_compare_addr);

            if (pending_q !== model_pending) fail("pending_q mismatch");
            if (recent_valid_q !== model_recent) fail("recent_valid_q mismatch");
            if (alloc_sel !== model_alloc) fail("alloc_sel mismatch");
            if (any_pending !== (|model_pending)) fail("any_pending mismatch");
            if (full !== (&model_pending)) fail("full mismatch");
            if (drain_sel !== selected) fail("drain_sel mismatch");
            if (drain_addr !== model_addr[selected]) fail("drain_addr mismatch");
            if (drain_wea !== model_wea[selected]) fail("drain_wea mismatch");
            if (drain_data !== model_data[selected]) fail("drain_data mismatch");
            if (drain_addr_match !== (selected ? match1 : match0))
                fail("parallel drain compare mismatch");

            lookup_entry_mask0 = (model_recent[0]
                                  && (model_addr[0][17:2]
                                      == lookup_addr[17:2]))
                               ? model_wea[0] : 4'b0000;
            lookup_entry_mask1 = (model_recent[1]
                                  && (model_addr[1][17:2]
                                      == lookup_addr[17:2]))
                               ? model_wea[1] : 4'b0000;
            lookup_covered_mask = lookup_entry_mask0 | lookup_entry_mask1;
            lookup_after0 = merge_bytes(32'd0, model_data[0],
                                        lookup_entry_mask0);
            lookup_after1 = merge_bytes(32'd0, model_data[1],
                                        lookup_entry_mask1);
            expected_lookup = model_alloc
                            ? merge_bytes(lookup_after1, model_data[0],
                                          lookup_entry_mask0)
                            : merge_bytes(lookup_after0, model_data[1],
                                          lookup_entry_mask1);
            expected_covers = (|lookup_mask)
                            && ((lookup_covered_mask & lookup_mask)
                                == lookup_mask);
            if (lookup_covers !== expected_covers) fail("lookup_covers mismatch");
            if (lookup_data !== expected_lookup) fail("lookup_data mismatch");

            refill_strobe0 = (model_refill_valid[0]
                              && (model_refill_word[0] == refill_word))
                           ? model_refill_wea[0] : 4'b0000;
            refill_strobe1 = (model_refill_valid[1]
                              && (model_refill_word[1] == refill_word))
                           ? model_refill_wea[1] : 4'b0000;
            expected_refill = merge_bytes(
                merge_bytes(refill_base_data, model_refill_data[0],
                            refill_strobe0),
                model_refill_data[1], refill_strobe1);
            if (refill_merged_data !== expected_refill)
                fail("refill_merged_data mismatch");
        end
    endtask

    task automatic capture_refill_model;
        logic old_sel;
        logic new_sel;
        begin
            old_sel = model_alloc ? 1'b1 : 1'b0;
            new_sel = ~old_sel;
            model_refill_valid[0] = model_recent[old_sel]
                                  && (model_addr[old_sel][31:4]
                                      == refill_line_addr[31:4]);
            model_refill_word[0] = model_addr[old_sel][3:2];
            model_refill_wea[0] = model_wea[old_sel];
            model_refill_data[0] = model_data[old_sel];
            model_refill_valid[1] = model_recent[new_sel]
                                  && (model_addr[new_sel][31:4]
                                      == refill_line_addr[31:4]);
            model_refill_word[1] = model_addr[new_sel][3:2];
            model_refill_wea[1] = model_wea[new_sel];
            model_refill_data[1] = model_data[new_sel];
        end
    endtask

    task automatic run_cycle (
        input logic        cycle_push,
        input logic        cycle_pop,
        input logic [31:0] cycle_addr,
        input logic [ 3:0] cycle_wea,
        input logic [31:0] cycle_data,
        input logic [15:0] cycle_compare,
        input logic [31:0] cycle_lookup_addr,
        input logic [ 3:0] cycle_lookup_mask,
        input logic        cycle_capture,
        input logic [31:0] cycle_line_addr,
        input logic [ 1:0] cycle_refill_word,
        input logic [31:0] cycle_refill_base
    );
        logic selected;
        begin
            @(negedge clk);
            push = cycle_push;
            pop = cycle_pop;
            push_addr = cycle_addr;
            push_wea = cycle_wea;
            push_data = cycle_data;
            drain_compare_addr = cycle_compare;
            lookup_addr = cycle_lookup_addr;
            lookup_mask = cycle_lookup_mask;
            refill_capture = cycle_capture;
            refill_line_addr = cycle_line_addr;
            refill_word = cycle_refill_word;
            refill_base_data = cycle_refill_base;
            #1;
            check_outputs();

            selected = model_drain_sel();
            if (cycle_pop && !model_pending[selected])
                fail("test attempted illegal pop");
            if (cycle_push && model_pending[model_alloc]
                           && !(cycle_pop && (selected == model_alloc)))
                fail("test attempted illegal push overwrite");

            if (cycle_push && cycle_pop) begin
                push_pop_seen = 1'b1;
                if ((model_pending == 2'b11) && (selected == model_alloc))
                    full_replace_seen = 1'b1;
            end else if (cycle_push) begin
                push_only_seen = 1'b1;
            end else if (cycle_pop) begin
                pop_only_seen = 1'b1;
            end

            @(posedge clk);
            if (cycle_capture)
                capture_refill_model();
            if (cycle_pop)
                model_pending[selected] = 1'b0;
            if (cycle_push) begin
                model_pending[model_alloc] = 1'b1;
                model_recent[model_alloc] = 1'b1;
                model_addr[model_alloc] = cycle_addr;
                model_wea[model_alloc] = cycle_wea;
                model_data[model_alloc] = cycle_data;
                model_alloc = ~model_alloc;
            end
            cycles_checked = cycles_checked + 1;
            pending_seen[model_pending] = 1'b1;
            #1;
            check_outputs();
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            push = 1'b0;
            pop = 1'b0;
            refill_capture = 1'b0;
            repeat (2) @(posedge clk);
            reset_model();
            @(negedge clk);
            rst_n = 1'b1;
            #1;
            check_outputs();
            pending_seen[0] = 1'b1;
        end
    endtask

    initial begin
        push = 1'b0;
        pop = 1'b0;
        push_addr = 32'd0;
        push_wea = 4'd0;
        push_data = 32'd0;
        drain_compare_addr = 16'd0;
        lookup_addr = 32'd0;
        lookup_mask = 4'd0;
        refill_capture = 1'b0;
        refill_line_addr = 32'd0;
        refill_word = 2'd0;
        refill_base_data = 32'd0;
        pending_seen = 4'b0000;
        pop_only_seen = 1'b0;
        push_only_seen = 1'b0;
        push_pop_seen = 1'b0;
        full_replace_seen = 1'b0;
        cycles_checked = 0;
        random_seed = 32'h51b0_2026;

        // Exact queue transitions: 00->01->11->10->01->11, followed by a
        // full pop/push replacement of the oldest physical slot.
        apply_reset();
        run_cycle(1, 0, 32'h8010_0040, 4'hf, 32'h1111_2222,
                  16'h0010, 32'h8010_0040, 4'hf, 0, 0, 0, 0);
        run_cycle(1, 0, 32'h8010_0084, 4'h3, 32'h3333_4444,
                  16'h0010, 32'h8010_0084, 4'h3, 0, 0, 0, 0);
        run_cycle(0, 1, 0, 0, 0, 16'h0021, 0, 0, 0, 0, 0, 0);
        run_cycle(1, 1, 32'h8010_00c8, 4'hc, 32'h5555_6666,
                  16'h0021, 32'h8010_00c8, 4'hc, 0, 0, 0, 0);
        run_cycle(1, 0, 32'h8010_010c, 4'h5, 32'h7777_8888,
                  16'h0032, 32'h8010_010c, 4'h5, 0, 0, 0, 0);
        run_cycle(1, 1, 32'h8010_0150, 4'ha, 32'h9999_aaaa,
                  16'h0043, 32'h8010_0150, 4'ha, 0, 0, 0, 0);

        // Same-word partial stores: younger bytes win even after both pending
        // bits drain, and recent data disappears only after both slots reuse.
        apply_reset();
        run_cycle(1, 0, 32'h8010_0200, 4'hf, 32'ha1b2_c3d4,
                  16'h0080, 32'h8010_0200, 4'hf, 0, 0, 0, 0);
        run_cycle(1, 0, 32'h8010_0200, 4'h2, 32'h0000_6600,
                  16'h0080, 32'h8010_0200, 4'hf, 0, 0, 0, 0);
        if (!lookup_covers || (lookup_data !== 32'ha1b2_66d4))
            fail("younger partial-store lookup priority mismatch");
        run_cycle(0, 1, 0, 0, 0, 16'h0080,
                  32'h8010_0200, 4'hf, 0, 0, 0, 0);
        run_cycle(0, 1, 0, 0, 0, 16'h0080,
                  32'h8010_0200, 4'hf, 0, 0, 0, 0);
        if (!lookup_covers || (lookup_data !== 32'ha1b2_66d4))
            fail("drained recent-store lookup was lost");
        run_cycle(1, 0, 32'h8010_0300, 4'hf, 32'h1234_5678,
                  0, 32'h8010_0200, 4'hf, 0, 0, 0, 0);
        run_cycle(1, 0, 32'h8010_0400, 4'hf, 32'h8765_4321,
                  0, 32'h8010_0200, 4'hf, 0, 0, 0, 0);
        if (lookup_covers) fail("overwritten recent store remained visible");

        // Refill snapshots must preserve age and byte masks even when both
        // live entries are replaced after capture.
        apply_reset();
        run_cycle(1, 0, 32'h8010_0504, 4'h2, 32'h0000_ab00,
                  0, 0, 0, 0, 0, 0, 0);
        run_cycle(1, 0, 32'h8010_0508, 4'hc, 32'hcdef_0000,
                  0, 0, 0, 0, 0, 0, 0);
        run_cycle(0, 0, 0, 0, 0, 0, 0, 0,
                  1, 32'h8010_0500, 1, 32'h1122_3344);
        run_cycle(1, 1, 32'h8010_0600, 4'hf, 32'hdead_beef,
                  0, 0, 0, 0, 0, 1, 32'h1122_3344);
        if (refill_merged_data !== 32'h1122_ab44)
            fail("captured refill word1 merge mismatch");
        run_cycle(1, 1, 32'h8010_0700, 4'hf, 32'hfeed_face,
                  0, 0, 0, 0, 0, 2, 32'h5566_7788);
        if (refill_merged_data !== 32'hcdef_7788)
            fail("captured refill word2 merge mismatch");

        // Constrained-random reference-model check. Legal push/pop choices
        // cover all queue occupancies while lookup, compare and refill inputs
        // change independently on every cycle.
        apply_reset();
        for (i = 0; i < 400; i = i + 1) begin
            random_sel = model_drain_sel();
            random_pop = (|model_pending) && ($urandom(random_seed) & 1);
            random_push = (($urandom(random_seed) >> 1) & 1);
            if (random_push && model_pending[model_alloc]
                            && !(random_pop && (random_sel == model_alloc)))
                random_push = 1'b0;
            random_addr = 32'h8010_0000
                        | (($urandom(random_seed) & 16'hffff) << 2);
            random_wea = $urandom_range(15, 1);
            random_data = $urandom(random_seed);
            random_compare = $urandom(random_seed);
            case ($urandom_range(2, 0))
                0: random_lookup_addr = model_addr[0];
                1: random_lookup_addr = model_addr[1];
                default: random_lookup_addr = 32'h8010_0000
                                            | (($urandom(random_seed)
                                                & 16'hffff) << 2);
            endcase
            random_lookup_mask = $urandom_range(15, 0);
            random_capture = (($urandom(random_seed) & 7) == 0);
            random_line_addr = random_lookup_addr;
            random_word = $urandom_range(3, 0);
            random_base = $urandom(random_seed);
            run_cycle(random_push, random_pop, random_addr, random_wea,
                      random_data, random_compare, random_lookup_addr,
                      random_lookup_mask, random_capture, random_line_addr,
                      random_word, random_base);
        end

        if (pending_seen != 4'b1111) fail("not all pending states were covered");
        if (!push_only_seen) fail("push-only transition not covered");
        if (!pop_only_seen) fail("pop-only transition not covered");
        if (!push_pop_seen) fail("simultaneous push/pop not covered");
        if (!full_replace_seen) fail("full same-slot replacement not covered");

        $display("[PASS] dcache_store_buffer directed/random test cycles=%0d pending_seen=%04b",
                 cycles_checked, pending_seen);
        $finish;
    end
endmodule
