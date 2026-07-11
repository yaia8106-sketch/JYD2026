// ============================================================
// Module: dcache_store_buffer
// Description: Two-entry write-through store buffer and recent-store lookup.
//
// Responsibilities:
//   - retain pending stores until the memory backend acknowledges them
//   - retain the two most recent stores for fully-covered load-miss bypass
//   - snapshot same-line recent stores when a cache-line refill starts
//   - merge those snapshots into each accepted refill word
// ============================================================

module dcache_store_buffer (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        push,
    input  logic [31:0] push_addr,
    input  logic [ 3:0] push_wea,
    input  logic [31:0] push_data,
    input  logic        pop,

    output logic        any_pending,
    output logic        full,
    output logic [31:0] drain_addr,
    output logic [ 3:0] drain_wea,
    output logic [31:0] drain_data,

    input  logic [31:0] lookup_addr,
    input  logic [ 3:0] lookup_mask,
    output logic        lookup_covers,
    output logic [31:0] lookup_data,

    input  logic        refill_capture,
    input  logic [31:0] refill_line_addr,
    input  logic [ 1:0] refill_word,
    input  logic [31:0] refill_base_data,
    output logic [31:0] refill_merged_data,

    // Compatibility/observation outputs retained at the DCache boundary.
    output logic [ 1:0] pending_q,
    output logic [ 1:0] recent_valid_q,
    output logic        alloc_sel,
    output logic        drain_sel
);

    logic [31:0] addr_q [1:0];
    logic [ 3:0] wea_q  [1:0];
    logic [31:0] data_q [1:0];

    logic        refill_merge_valid [1:0];
    logic [ 1:0] refill_merge_word  [1:0];
    logic [ 3:0] refill_merge_wea   [1:0];
    logic [31:0] refill_merge_data  [1:0];

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

    // ================================================================
    //  Drain selection
    // ================================================================
    assign any_pending = |pending_q;
    assign full        = &pending_q;

    // With both entries pending, alloc_sel identifies the older entry because
    // allocation alternates. With one entry pending, select that physical slot.
    assign drain_sel  = (pending_q == 2'b11) ? alloc_sel : pending_q[1];
    assign drain_addr = drain_sel ? addr_q[1] : addr_q[0];
    assign drain_wea  = drain_sel ? wea_q[1]  : wea_q[0];
    assign drain_data = drain_sel ? data_q[1] : data_q[0];

    // ================================================================
    //  Recent-store load-miss lookup
    // ================================================================
    // The instantiated DRAM is 256 KiB at 0x8010_0000..0x8013_FFFF, so bits
    // [31:18] are constant for every address that can reach this DCache.  Use
    // the same word key as the cache instead of a redundant 30-bit equality.
    wire lookup_match0 = recent_valid_q[0]
                       & (addr_q[0][17:2] == lookup_addr[17:2]);
    wire lookup_match1 = recent_valid_q[1]
                       & (addr_q[1][17:2] == lookup_addr[17:2]);
    wire [3:0] lookup_entry_mask0 = lookup_match0 ? wea_q[0] : 4'b0000;
    wire [3:0] lookup_entry_mask1 = lookup_match1 ? wea_q[1] : 4'b0000;
    wire [3:0] lookup_covered_mask = lookup_entry_mask0 | lookup_entry_mask1;

    // alloc=0: entry0 is older, entry1 is newer.
    // alloc=1: entry1 is older, entry0 is newer.
    wire [31:0] lookup_after_0 = merge_bytes(32'd0, data_q[0], lookup_entry_mask0);
    wire [31:0] lookup_after_1 = merge_bytes(32'd0, data_q[1], lookup_entry_mask1);
    wire [31:0] lookup_0_then_1 =
        merge_bytes(lookup_after_0, data_q[1], lookup_entry_mask1);
    wire [31:0] lookup_1_then_0 =
        merge_bytes(lookup_after_1, data_q[0], lookup_entry_mask0);

    assign lookup_data = alloc_sel ? lookup_1_then_0 : lookup_0_then_1;
    assign lookup_covers = |lookup_mask
                         & ((lookup_covered_mask & lookup_mask) == lookup_mask);

    // ================================================================
    //  Refill overlay
    // ================================================================
    wire recent_old_valid = alloc_sel ? recent_valid_q[1] : recent_valid_q[0];
    wire [31:0] recent_old_addr = alloc_sel ? addr_q[1] : addr_q[0];
    wire [ 3:0] recent_old_wea  = alloc_sel ? wea_q[1]  : wea_q[0];
    wire [31:0] recent_old_data = alloc_sel ? data_q[1] : data_q[0];
    wire recent_new_valid = alloc_sel ? recent_valid_q[0] : recent_valid_q[1];
    wire [31:0] recent_new_addr = alloc_sel ? addr_q[0] : addr_q[1];
    wire [ 3:0] recent_new_wea  = alloc_sel ? wea_q[0]  : wea_q[1];
    wire [31:0] recent_new_data = alloc_sel ? data_q[0] : data_q[1];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int e = 0; e < 2; e++) begin
                refill_merge_valid[e] <= 1'b0;
                refill_merge_word[e]  <= 2'd0;
                refill_merge_wea[e]   <= 4'd0;
                refill_merge_data[e]  <= 32'd0;
            end
        end else if (refill_capture) begin
            // Preserve age order so entry 1 wins overlapping bytes.
            refill_merge_valid[0] <= recent_old_valid
                                   & (recent_old_addr[31:4] == refill_line_addr[31:4]);
            refill_merge_word[0]  <= recent_old_addr[3:2];
            refill_merge_wea[0]   <= recent_old_wea;
            refill_merge_data[0]  <= recent_old_data;
            refill_merge_valid[1] <= recent_new_valid
                                   & (recent_new_addr[31:4] == refill_line_addr[31:4]);
            refill_merge_word[1]  <= recent_new_addr[3:2];
            refill_merge_wea[1]   <= recent_new_wea;
            refill_merge_data[1]  <= recent_new_data;
        end
    end

    wire refill_match0 = refill_merge_valid[0]
                       & (refill_merge_word[0] == refill_word);
    wire refill_match1 = refill_merge_valid[1]
                       & (refill_merge_word[1] == refill_word);
    wire [3:0] refill_strobe0 = refill_match0 ? refill_merge_wea[0] : 4'b0000;
    wire [3:0] refill_strobe1 = refill_match1 ? refill_merge_wea[1] : 4'b0000;
    wire [31:0] refill_after_0 =
        merge_bytes(refill_base_data, refill_merge_data[0], refill_strobe0);

    assign refill_merged_data =
        merge_bytes(refill_after_0, refill_merge_data[1], refill_strobe1);

    // ================================================================
    //  Queue state
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pending_q      <= 2'b00;
            recent_valid_q <= 2'b00;
            alloc_sel      <= 1'b0;
            for (int e = 0; e < 2; e++) begin
                addr_q[e] <= 32'd0;
                wea_q[e]  <= 4'd0;
                data_q[e] <= 32'd0;
            end
        end else begin
            if (pop)
                pending_q[drain_sel] <= 1'b0;

            if (push) begin
                pending_q[alloc_sel]      <= 1'b1;
                recent_valid_q[alloc_sel] <= 1'b1;
                addr_q[alloc_sel]         <= push_addr;
                wea_q[alloc_sel]          <= push_wea;
                data_q[alloc_sel]         <= push_data;
                alloc_sel                 <= ~alloc_sel;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (push && pending_q[alloc_sel])
                $error("DCache store buffer overwrote a pending entry");
            if (pop && !pending_q[drain_sel])
                $error("DCache store buffer popped a non-pending entry");
            if (|(pending_q & ~recent_valid_q))
                $error("DCache pending entry lost recent-store validity");
            if (push && pop)
                $error("DCache store buffer push/pop must be mutually exclusive");
        end
    end
`endif

endmodule
