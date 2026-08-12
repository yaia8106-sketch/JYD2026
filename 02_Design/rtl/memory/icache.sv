// ============================================================
// Module: icache
// Description:
//   NSCSCC instruction cache between the variable-latency frontend port and
//   the shared 32-bit memory backend.
//
// Organization:
//   - parameterized 8/16/32 KiB, 1/2-way, 16-byte lines
//   - one capacity-sized 72-bit simple-dual-port memory; the selected way is
//     part of its row address, so 2-way operation does not duplicate data BRAM
//   - 8 KiB uses 1024 x 72 (two RAMB36s), while 16/32 KiB use
//     2048/4096 x 72 respectively for instruction data plus refill-time
//     predecode metadata
//   - distributed per-way shortened-tag/class storage with one valid bit per
//     line and one replacement bit per set when WAYS=2
//   - one four-beat WRAP refill starting at the critical 64-bit block
//
// A request is accepted when irom_req_valid and irom_req_ready are both high.
// A local hit is returned from the synchronous data RAM in the following
// cycle. The frontend has no response backpressure and consumes each valid
// response immediately.
//
// A frontend kill discards lookup/miss ownership at the clock edge. An AXI
// read already accepted by the backend is drained without writing later
// response beats into the cache. Independent cache hits may continue while
// that stale read is draining.
// ============================================================

module icache #(
    // NSCSCC programs execute from a one-megabyte physical-PC window.  Only
    // requests in this prefix may allocate or hit in the shortened-tag array;
    // every request still keeps its complete 32-bit address on the AXI side.
    parameter logic [11:0] ICACHE_ADDR_PREFIX = 12'h1c0,
    parameter integer CACHE_BYTES =
`ifdef NSCSCC_ICACHE_BYTES
        `NSCSCC_ICACHE_BYTES,
`else
        16384,
`endif
    parameter integer WAYS =
`ifdef NSCSCC_ICACHE_WAYS
        `NSCSCC_ICACHE_WAYS
`else
        1
`endif
) (
    // Clock and reset
    input  logic        clk,
    input  logic        rst_n,

    // Frontend 64-bit instruction-block channel
    input  logic        irom_req_valid,
    output logic        irom_req_ready,
    input  logic [31:0] irom_req_addr,
    input  logic        irom_req_kill,
    output logic        irom_resp_valid,
    output logic [63:0] irom_resp_data,
    output logic [13:0] irom_resp_predecode,
    output logic [ 1:0] irom_resp_resp,

    // Shared 32-bit memory-backend read channel
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic [ 7:0] mem_req_len,
    output logic [ 1:0] mem_req_burst,
    input  logic        mem_rd_valid,
    output logic        mem_rd_ready,
    input  logic [31:0] mem_rd_data,
    input  logic        mem_rd_last,
    input  logic [ 1:0] mem_rd_resp
);

    localparam integer LINE_BYTES = 16;
    localparam integer LINE_OFFSET_WIDTH = 4;
    localparam integer LINES = CACHE_BYTES / LINE_BYTES;
    localparam integer SETS = LINES / WAYS;
    localparam integer INDEX_WIDTH = $clog2(SETS);
    localparam integer WAY_WIDTH = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam integer TAG_WIDTH = 20 - LINE_OFFSET_WIDTH - INDEX_WIDTH;
    localparam integer BLOCK_CLASS_WIDTH = 6;
    localparam integer LINE_CLASS_WIDTH = 12;
    localparam integer TAG_RAM_WIDTH = TAG_WIDTH + LINE_CLASS_WIDTH;
    localparam integer DATA_ROWS_PER_WAY = SETS * 2;
    localparam integer DATA_ROWS = LINES * 2;
    localparam integer LINE_SLOT_WIDTH = $clog2(LINES);
    localparam integer DATA_ROW_WIDTH = $clog2(DATA_ROWS);

    typedef enum logic [1:0] {
        REFILL_IDLE,
        REFILL_REQ,
        REFILL_DATA
    } refill_state_t;

    refill_state_t refill_state_q;

    // ----------------------------------------------------------------
    // Cache arrays
    // ----------------------------------------------------------------

    // The selected way is folded into the synchronous BRAM row address after
    // the distributed-tag lookup. Therefore 8 KiB remains one 1024 x 72 data
    // memory for both 1-way and 2-way configurations. The upper eight bits
    // occupy the primitive parity storage and hold four predecode bits for
    // each of the two 32-bit instructions.
    (* ram_style = "block" *)
    logic [71:0] data_mem [0:DATA_ROWS-1];
    (* ram_style = "distributed" *)
    logic [TAG_RAM_WIDTH-1:0] tag_mem [0:LINES-1];
    logic [LINES-1:0] line_valid_q;
    logic [SETS-1:0] replacement_way_q;

    logic [71:0] lookup_payload_q;
    logic [BLOCK_CLASS_WIDTH-1:0] lookup_class_q;

    // ----------------------------------------------------------------
    // One-cycle lookup pipeline
    // ----------------------------------------------------------------

    logic        lookup_valid_q;
    logic        lookup_hit_q;
    logic        lookup_refill_hit_q;
    logic        lookup_commit_hit;
    logic [28:0] lookup_block_addr_q;

    logic        pending_miss_valid_q;
    logic [28:0] pending_miss_block_addr_q;

    logic        miss_resp_valid_q;
    logic [71:0] miss_resp_payload_q;
    logic [BLOCK_CLASS_WIDTH-1:0] miss_resp_class_q;
    logic [ 1:0] miss_resp_resp_q;

    logic [27:0] refill_buffer_line_addr_q;
    logic [ 1:0] refill_buffer_filled_q;
    logic [71:0] refill_buffer_block0_q;
    logic [71:0] refill_buffer_block1_q;
    logic [BLOCK_CLASS_WIDTH-1:0] refill_buffer_block0_class_q;
    logic [BLOCK_CLASS_WIDTH-1:0] refill_buffer_block1_class_q;
    logic [ 1:0] refill_line_resp_q;

    logic [27:0] refill_line_addr_q;
    logic        refill_block_q;
    logic [WAY_WIDTH-1:0] refill_way_q;
    logic        refill_second_block_q;
    logic        refill_response_needed_q;
    logic        refill_drop_q;
    logic        refill_beat_q;
    logic [31:0] refill_word0_q;
    logic [ 1:0] refill_block_resp_q;
    wire         refill_block_commit;

    // The last refill beat first completes the registered block-class
    // records. Tag/valid publication then uses those registers on the next
    // edge, keeping the refill decoder out of the LUTRAM write-data path.
    logic                   tag_commit_pending_q;
    logic [INDEX_WIDTH-1:0] tag_commit_index_q;
    logic [TAG_WIDTH-1:0]   tag_commit_tag_q;
    logic [WAY_WIDTH-1:0]   tag_commit_way_q;

    wire irom_req_fire = irom_req_valid & irom_req_ready;
    wire [INDEX_WIDTH-1:0] irom_req_index =
        irom_req_addr[LINE_OFFSET_WIDTH +: INDEX_WIDTH];
    wire [TAG_WIDTH-1:0] irom_req_tag =
        irom_req_addr[LINE_OFFSET_WIDTH + INDEX_WIDTH +: TAG_WIDTH];
    wire irom_req_in_window =
        irom_req_addr[31:20] == ICACHE_ADDR_PREFIX;
    wire irom_req_block = irom_req_addr[3];
    wire [WAY_WIDTH-1:0] irom_req_array_way;
    wire [DATA_ROW_WIDTH-1:0] irom_req_data_row;
    generate
        if (WAYS == 1) begin : g_request_row_one_way
            assign irom_req_data_row = {irom_req_index, irom_req_block};
        end else begin : g_request_row_two_ways
            assign irom_req_data_row = {
                irom_req_array_way[0], irom_req_index, irom_req_block
            };
        end
    endgenerate

    // A registered local hit is consumed by the frontend in this cycle, so
    // its lookup slot may be replaced by the next BP request at the same edge.
    // A miss retains ownership until it has been copied to pending_miss.
    assign irom_req_ready =
        (~lookup_valid_q | lookup_hit_q | lookup_commit_hit)
        & ~pending_miss_valid_q
        & ~miss_resp_valid_q;

    // BP-stage hit computation. All way tags are read in parallel from
    // distributed memory. The matching way is then included in the single
    // synchronous data-memory row address, avoiding a duplicated BRAM read.
    // Split each shortened-tag equality into low/high groups so Vivado can
    // evaluate them in parallel rather than building a serial comparator.
    wire [WAYS-1:0] irom_req_way_hit;
    wire [TAG_RAM_WIDTH-1:0] irom_req_way_tag_payload [0:WAYS-1];
    genvar lookup_way;
    generate
        for (lookup_way = 0; lookup_way < WAYS;
             lookup_way = lookup_way + 1) begin : g_lookup_way
            localparam logic [LINE_SLOT_WIDTH-1:0] WAY_LINE_BASE =
                LINE_SLOT_WIDTH'(lookup_way * SETS);
            wire [LINE_SLOT_WIDTH-1:0] line_slot =
                WAY_LINE_BASE | LINE_SLOT_WIDTH'(irom_req_index);
            wire [TAG_WIDTH-1:0] cached_tag =
                irom_req_way_tag_payload[lookup_way][TAG_WIDTH-1:0];
            wire [TAG_WIDTH-1:0] tag_diff = cached_tag ^ irom_req_tag;
            wire tag_eq_low = ~|tag_diff[3:0];
            wire tag_eq_high = ~|tag_diff[TAG_WIDTH-1:4];

            assign irom_req_way_tag_payload[lookup_way] =
                tag_mem[line_slot];
            assign irom_req_way_hit[lookup_way] =
                irom_req_in_window
                & line_valid_q[line_slot]
                & tag_eq_low & tag_eq_high;
        end
    endgenerate

    generate
        if (WAYS == 1) begin : g_select_one_way
            assign irom_req_array_way = '0;
        end else begin : g_select_two_ways
            // At most one way can hold a given shortened tag in a set.
            assign irom_req_array_way =
                irom_req_way_hit[0] ? 0 : 1;
        end
    endgenerate

    wire [TAG_RAM_WIDTH-1:0] irom_req_tag_payload =
        irom_req_way_tag_payload[irom_req_array_way];
    wire [LINE_CLASS_WIDTH-1:0] irom_req_line_class =
        irom_req_tag_payload[TAG_RAM_WIDTH-1:TAG_WIDTH];
    wire irom_req_array_hit = |irom_req_way_hit;

    wire [27:0] irom_req_refill_diff =
        irom_req_addr[31:4] ^ refill_buffer_line_addr_q;
    wire irom_req_refill_eq0 = ~|irom_req_refill_diff[5:0];
    wire irom_req_refill_eq1 = ~|irom_req_refill_diff[11:6];
    wire irom_req_refill_eq2 = ~|irom_req_refill_diff[17:12];
    wire irom_req_refill_eq3 = ~|irom_req_refill_diff[23:18];
    wire irom_req_refill_eq4 = ~|irom_req_refill_diff[27:24];
    wire irom_req_refill_block_valid =
        irom_req_block ? refill_buffer_filled_q[1]
                       : refill_buffer_filled_q[0];
    // Keep a completed line visible through its one-cycle atomic tag commit.
    // Requests in that window use the refill buffer instead of starting a
    // duplicate miss against the not-yet-published tag.
    wire refill_buffer_lookup_active =
        (refill_state_q == REFILL_DATA) | tag_commit_pending_q;
    wire irom_req_refill_hit =
        refill_buffer_lookup_active
        & irom_req_refill_block_valid
        & irom_req_refill_eq0 & irom_req_refill_eq1
        & irom_req_refill_eq2 & irom_req_refill_eq3
        & irom_req_refill_eq4;
    wire irom_req_hit = irom_req_array_hit | irom_req_refill_hit;

    always_ff @(posedge clk) begin
        if (!rst_n || irom_req_kill)
            lookup_valid_q <= 1'b0;
        else if (irom_req_fire)
            lookup_valid_q <= 1'b1;
        else if (lookup_valid_q)
            lookup_valid_q <= 1'b0;
    end

    // Hit/source/address metadata is owned solely by lookup_valid_q.  A kill
    // clears that one owner bit; stale payload cannot produce a response.
    always_ff @(posedge clk) begin
        if (irom_req_fire) begin
            lookup_hit_q <= irom_req_hit;
            lookup_refill_hit_q <= irom_req_refill_hit;
            lookup_block_addr_q <= irom_req_addr[31:3];
            lookup_class_q <= irom_req_block
                            ? irom_req_line_class[11:6]
                            : irom_req_line_class[5:0];
        end
    end

    // ----------------------------------------------------------------
    // Refill transaction and partial-line buffer
    // ----------------------------------------------------------------

    wire mem_req_fire = mem_req_valid & mem_req_ready;
    wire mem_rd_fire = mem_rd_valid & mem_rd_ready;
    wire refill_block_complete =
        (refill_state_q == REFILL_DATA)
        & mem_rd_fire
        & refill_beat_q;
    wire [63:0] refill_block_data =
        refill_beat_q
            ? {mem_rd_data, refill_word0_q}
            : {32'd0, mem_rd_data};
    wire [13:0] refill_block_predecode;
    // The RAMB36 parity bits retain the original four controls per
    // instruction.  The new three-bit classes are accumulated separately and
    // committed atomically with the shortened line tag.
    wire [7:0] refill_block_control = {
        refill_block_predecode[13:10],
        refill_block_predecode[6:3]
    };
    wire [BLOCK_CLASS_WIDTH-1:0] refill_block_class = {
        refill_block_predecode[9:7],
        refill_block_predecode[2:0]
    };
    wire [71:0] refill_block_payload = {
        refill_block_control,
        refill_block_data
    };
    wire [1:0] refill_block_resp =
        refill_block_resp_q | mem_rd_resp;
    assign refill_block_commit =
        refill_block_complete
        & ~refill_drop_q
        & ~irom_req_kill;

    wire [INDEX_WIDTH-1:0] pending_miss_index =
        pending_miss_block_addr_q[1 +: INDEX_WIDTH];
    wire [WAY_WIDTH-1:0] miss_replacement_way;
    generate
        if (WAYS == 1) begin : g_replace_one_way
            assign miss_replacement_way = '0;
        end else begin : g_replace_two_ways
            wire [LINE_SLOT_WIDTH-1:0] way0_slot =
                {1'b0, pending_miss_index};
            wire [LINE_SLOT_WIDTH-1:0] way1_slot =
                {1'b1, pending_miss_index};
            wire way0_valid = line_valid_q[way0_slot];
            wire way1_valid = line_valid_q[way1_slot];
            assign miss_replacement_way =
                !way0_valid ? 0
                : !way1_valid ? 1
                : replacement_way_q[pending_miss_index];
        end
    endgenerate

    wire [INDEX_WIDTH-1:0] refill_index =
        refill_line_addr_q[0 +: INDEX_WIDTH];
    wire [TAG_WIDTH-1:0] refill_tag =
        refill_line_addr_q[INDEX_WIDTH +: TAG_WIDTH];
    wire refill_in_window =
        refill_line_addr_q[27:16] == ICACHE_ADDR_PREFIX;
    wire [DATA_ROW_WIDTH-1:0] refill_data_row;
    wire [LINE_SLOT_WIDTH-1:0] refill_line_slot;
    wire [LINE_SLOT_WIDTH-1:0] tag_commit_line_slot;
    generate
        if (WAYS == 1) begin : g_refill_row_one_way
            assign refill_data_row = {refill_index, refill_block_q};
            assign refill_line_slot = refill_index;
            assign tag_commit_line_slot = tag_commit_index_q;
        end else begin : g_refill_row_two_ways
            assign refill_data_row = {
                refill_way_q[0], refill_index, refill_block_q
            };
            assign refill_line_slot = {refill_way_q[0], refill_index};
            assign tag_commit_line_slot = {
                tag_commit_way_q[0], tag_commit_index_q
            };
        end
    endgenerate
    wire refill_line_start = mem_req_fire;
    wire refill_cache_block_commit =
        refill_block_commit & refill_in_window;
    wire [1:0] refill_complete_resp =
        refill_line_resp_q | refill_block_resp;
    wire refill_line_complete =
        refill_block_commit
        & refill_second_block_q;
    wire refill_line_complete_ok =
        refill_line_complete
        & (refill_complete_resp == 2'b00)
        & refill_in_window;
    wire [LINE_CLASS_WIDTH-1:0] tag_commit_line_class = {
        refill_buffer_block1_class_q,
        refill_buffer_block0_class_q
    };

    // This decoder is outside the hit path: it runs only on the completed
    // 64-bit refill block before that block is committed to the RAMB36.
    loongarch_icache_block_predecode u_refill_predecode (
        .block_data     (refill_block_data),
        .block_metadata (refill_block_predecode)
    );

    // Keep the data read and refill write as two independent BRAM ports.
    // A same-row collision is harmless: that row has no valid line yet, and
    // the partial-line buffer supplies matching refill data instead.
    always_ff @(posedge clk) begin
        if (irom_req_fire)
            lookup_payload_q <= data_mem[irom_req_data_row];
        if (refill_cache_block_commit)
            data_mem[refill_data_row] <= refill_block_payload;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            line_valid_q <= '0;
        end else begin
            if (refill_line_start && refill_in_window)
                line_valid_q[refill_line_slot] <= 1'b0;
            if (tag_commit_pending_q) begin
                tag_mem[tag_commit_line_slot] <= {
                    tag_commit_line_class,
                    tag_commit_tag_q
                };
                line_valid_q[tag_commit_line_slot] <= 1'b1;
            end
        end
    end

    // For two ways this bit names the next victim after both ways are valid.
    // Invalid ways always win allocation, so the payload itself needs no
    // reset. Array hits and successful fills make the opposite way oldest.
    generate
        if (WAYS == 2) begin : g_replacement_state
            always_ff @(posedge clk) begin
                if (irom_req_fire && irom_req_array_hit)
                    replacement_way_q[irom_req_index]
                        <= ~irom_req_array_way[0];
                if (tag_commit_pending_q)
                    replacement_way_q[tag_commit_index_q]
                        <= ~tag_commit_way_q[0];
            end
        end
    endgenerate

    // Only the pending bit needs reset. Index/tag payloads are overwritten by
    // the event that makes them observable. A redirect after the final beat
    // does not cancel this delayed publication, matching the former design in
    // which the line had already become valid on that final-beat edge.
    always_ff @(posedge clk) begin
        if (!rst_n)
            tag_commit_pending_q <= 1'b0;
        else
            tag_commit_pending_q <= refill_line_complete_ok;

        if (refill_line_complete_ok) begin
            tag_commit_index_q <= refill_index;
            tag_commit_tag_q <= refill_tag;
            tag_commit_way_q <= refill_way_q;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || irom_req_kill)
            refill_buffer_filled_q <= 2'b00;
        else begin
            if (refill_line_start)
                refill_buffer_filled_q <= 2'b00;
            if (refill_block_commit)
                refill_buffer_filled_q[refill_block_q] <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (refill_line_start) begin
            refill_buffer_line_addr_q <= refill_line_addr_q;
            refill_line_resp_q <= 2'b00;
        end else if (refill_block_commit) begin
            refill_line_resp_q <= refill_line_resp_q | refill_block_resp;
        end

        if (refill_block_commit) begin
            if (refill_block_q) begin
                refill_buffer_block1_q <= refill_block_payload;
                refill_buffer_block1_class_q <= refill_block_class;
            end else begin
                refill_buffer_block0_q <= refill_block_payload;
                refill_buffer_block0_class_q <= refill_block_class;
            end
        end
    end

    // ----------------------------------------------------------------
    // Lookup result and frontend response
    // ----------------------------------------------------------------

    wire lookup_block = lookup_block_addr_q[0];
    // A request accepted on the final refill beat sampled the old buffer-valid
    // bits. Rescue it one cycle later from registered refill state instead of
    // feeding AXI RVALID/RRESP combinationally into the BP-stage hit path.
    // This keeps the original one-cycle hit response and back-to-back request
    // behavior without creating a memory-bus-to-frontend timing path.
    always_comb begin
        lookup_commit_hit =
            lookup_valid_q
            & tag_commit_pending_q
            & (lookup_block_addr_q[28:1] == refill_buffer_line_addr_q)
            & (lookup_block
                   ? refill_buffer_filled_q[1]
                   : refill_buffer_filled_q[0]);
    end
    wire lookup_hit = lookup_valid_q & (lookup_hit_q | lookup_commit_hit);
    wire lookup_miss = lookup_valid_q & ~lookup_hit;
    wire [71:0] lookup_refill_payload =
        lookup_block
            ? refill_buffer_block1_q
            : refill_buffer_block0_q;
    wire [BLOCK_CLASS_WIDTH-1:0] lookup_refill_class =
        lookup_block
            ? refill_buffer_block1_class_q
            : refill_buffer_block0_class_q;
    wire [71:0] lookup_hit_payload =
        (lookup_refill_hit_q | lookup_commit_hit)
            ? lookup_refill_payload
            : lookup_payload_q;
    wire [BLOCK_CLASS_WIDTH-1:0] lookup_hit_class =
        (lookup_refill_hit_q | lookup_commit_hit)
            ? lookup_refill_class
            : lookup_class_q;

    wire refill_matches_lookup =
        refill_block_commit
        & lookup_miss
        & (lookup_block_addr_q[28:1] == refill_line_addr_q)
        & (lookup_block_addr_q[0] == refill_block_q);
    wire refill_matches_pending =
        refill_block_commit
        & pending_miss_valid_q
        & (pending_miss_block_addr_q[28:1] == refill_line_addr_q)
        & (pending_miss_block_addr_q[0] == refill_block_q);
    wire refill_owner_response =
        refill_block_commit
        & refill_response_needed_q;
    wire refill_frontend_response =
        refill_owner_response
        | refill_matches_lookup
        | refill_matches_pending;

    always_ff @(posedge clk) begin
        if (!rst_n || irom_req_kill) begin
            pending_miss_valid_q <= 1'b0;
        end else begin
            if ((refill_state_q == REFILL_IDLE) && pending_miss_valid_q)
                pending_miss_valid_q <= 1'b0;
            if (refill_matches_pending)
                pending_miss_valid_q <= 1'b0;
            if (lookup_miss & ~refill_matches_lookup) begin
                pending_miss_valid_q <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (lookup_miss & ~refill_matches_lookup)
            pending_miss_block_addr_q <= lookup_block_addr_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || irom_req_kill)
            miss_resp_valid_q <= 1'b0;
        else
            miss_resp_valid_q <= refill_frontend_response;
    end

    always_ff @(posedge clk) begin
        if (refill_frontend_response) begin
            miss_resp_payload_q <= refill_block_payload;
            miss_resp_class_q <= refill_block_class;
            miss_resp_resp_q <= refill_block_resp;
        end
    end

    assign irom_resp_valid = lookup_hit | miss_resp_valid_q;
    assign irom_resp_data =
        lookup_hit
            ? lookup_hit_payload[63:0]
            : miss_resp_payload_q[63:0];
    wire [7:0] response_control =
        lookup_hit
            ? lookup_hit_payload[71:64]
            : miss_resp_payload_q[71:64];
    wire [BLOCK_CLASS_WIDTH-1:0] response_class =
        lookup_hit ? lookup_hit_class : miss_resp_class_q;
    assign irom_resp_predecode = {
        response_control[7:4], response_class[5:3],
        response_control[3:0], response_class[2:0]
    };
    assign irom_resp_resp =
        lookup_hit
            ? 2'b00
            : miss_resp_resp_q;

    // ----------------------------------------------------------------
    // Refill state machine
    // ----------------------------------------------------------------

    // Reset owns only the FSM state. All transaction fields are initialized by
    // the event that makes their state observable.
    always_ff @(posedge clk) begin
        if (!rst_n)
            refill_state_q <= REFILL_IDLE;
        else if (irom_req_kill) begin
            if (refill_state_q == REFILL_REQ)
                refill_state_q <= mem_req_fire ? REFILL_DATA : REFILL_IDLE;
            else if ((refill_state_q == REFILL_DATA)
                     && mem_rd_fire && mem_rd_last)
                refill_state_q <= REFILL_IDLE;
        end else begin
            case (refill_state_q)
                REFILL_IDLE:
                    if (pending_miss_valid_q)
                        refill_state_q <= REFILL_REQ;
                REFILL_REQ:
                    if (mem_req_fire)
                        refill_state_q <= REFILL_DATA;
                REFILL_DATA:
                    if (mem_rd_fire) begin
                        if (refill_drop_q && mem_rd_last)
                            refill_state_q <= REFILL_IDLE;
                        else if (!refill_drop_q && refill_beat_q
                                 && refill_second_block_q && mem_rd_last)
                            refill_state_q <= REFILL_IDLE;
                    end
                default:
                    refill_state_q <= REFILL_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (irom_req_kill) begin
            refill_response_needed_q <= 1'b0;
            if (refill_state_q == REFILL_REQ) begin
                if (mem_req_fire) begin
                    refill_beat_q <= 1'b0;
                    refill_block_resp_q <= 2'b00;
                    refill_drop_q <= 1'b1;
                end else begin
                    refill_drop_q <= 1'b0;
                end
            end else if (refill_state_q == REFILL_DATA) begin
                if (mem_rd_fire && mem_rd_last) begin
                    refill_drop_q <= 1'b0;
                    refill_beat_q <= 1'b0;
                    refill_second_block_q <= 1'b0;
                    refill_block_resp_q <= 2'b00;
                end else begin
                    refill_drop_q <= 1'b1;
                end
            end
        end else begin
            case (refill_state_q)
                REFILL_IDLE: begin
                    refill_drop_q <= 1'b0;
                    if (pending_miss_valid_q) begin
                        refill_line_addr_q <=
                            pending_miss_block_addr_q[28:1];
                        refill_block_q <= pending_miss_block_addr_q[0];
                        refill_way_q <= miss_replacement_way;
                        refill_second_block_q <= 1'b0;
                        refill_response_needed_q <= 1'b1;
                    end
                end

                REFILL_REQ: begin
                    if (mem_req_fire) begin
                        refill_beat_q <= 1'b0;
                        refill_block_resp_q <= 2'b00;
                    end
                end

                REFILL_DATA: begin
                    if (mem_rd_fire) begin
                        // Once a redirect kills this refill, AXI RLAST is the
                        // only trustworthy completion marker. A kill may
                        // coincide with an accepted middle beat, so the local
                        // beat/block counters no longer describe the remaining
                        // bus transaction and must not drive normal sequencing.
                        if (refill_drop_q) begin
                            if (mem_rd_last) begin
                                refill_drop_q <= 1'b0;
                                refill_beat_q <= 1'b0;
                                refill_second_block_q <= 1'b0;
                                refill_response_needed_q <= 1'b0;
                                refill_block_resp_q <= 2'b00;
                            end
                        end else if (!refill_beat_q) begin
                            refill_word0_q <= mem_rd_data;
                            refill_beat_q <= 1'b1;
                            refill_block_resp_q <= refill_block_resp;
                        end else begin
                            refill_beat_q <= 1'b0;
                            refill_block_resp_q <= 2'b00;
                            if (!refill_second_block_q) begin
                                refill_block_q <= ~refill_block_q;
                                refill_second_block_q <= 1'b1;
                                refill_response_needed_q <= 1'b0;
                            end else if (mem_rd_last) begin
                                refill_second_block_q <= 1'b0;
                                refill_response_needed_q <= 1'b0;
                                refill_drop_q <= 1'b0;
                            end
                        end
                    end
                end

                default: begin
                    refill_drop_q <= 1'b0;
                    refill_response_needed_q <= 1'b0;
                end
            endcase
        end
    end

    assign mem_req_valid = refill_state_q == REFILL_REQ;
    assign mem_req_addr = {
        refill_line_addr_q,
        refill_block_q,
        3'b000
    };
    assign mem_req_len = 8'd3;
    assign mem_req_burst = 2'b10;
    assign mem_rd_ready = refill_state_q == REFILL_DATA;

`ifndef SYNTHESIS
    initial begin
        if ((CACHE_BYTES != 8192) && (CACHE_BYTES != 16384)
            && (CACHE_BYTES != 32768))
            $fatal(1, "ICache CACHE_BYTES must be 8192, 16384 or 32768");
        if ((WAYS != 1) && (WAYS != 2))
            $fatal(1, "ICache WAYS must be 1 or 2");
        if ((LINES % WAYS) != 0)
            $fatal(1, "ICache line count must divide evenly across ways");
    end

    always_ff @(posedge clk) begin
        if (rst_n && irom_req_fire && (irom_req_addr[2:0] != 3'b000))
            $error("ICache request address is not 64-bit aligned");
        if (rst_n
            && mem_rd_fire
            && !refill_drop_q
            && !irom_req_kill
            && (mem_rd_last !=
                (refill_second_block_q & refill_beat_q)))
            $error("ICache four-beat WRAP refill RLAST mismatch");
        if (rst_n && lookup_hit && miss_resp_valid_q)
            $error("ICache produced two frontend responses in one cycle");
        if (rst_n && refill_matches_lookup && refill_matches_pending)
            $error("ICache matched both lookup and pending miss owners");
        if (rst_n && irom_req_valid && (WAYS == 2)
            && (&irom_req_way_hit))
            $error("ICache duplicate tag addr=%08x set=%0d",
                   irom_req_addr, irom_req_index);
    end
`endif

endmodule
