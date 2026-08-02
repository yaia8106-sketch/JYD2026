// ============================================================
// Module: icache
// Description:
//   NSCSCC instruction cache between the variable-latency frontend port and
//   the shared 32-bit memory backend.
//
// Organization:
//   - 4 KiB, direct-mapped, 16-byte lines
//   - one 512 x 72 simple-dual-port block RAM for instruction data plus
//     refill-time predecode metadata
//   - distributed shortened-tag/class storage with one valid bit per line
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
    parameter logic [11:0] ICACHE_ADDR_PREFIX = 12'h1c0
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

    localparam integer SETS = 256;
    localparam integer INDEX_WIDTH = 8;
    localparam integer TAG_WIDTH = 8;
    localparam integer BLOCK_CLASS_WIDTH = 6;
    localparam integer LINE_CLASS_WIDTH = 12;
    localparam integer TAG_RAM_WIDTH = TAG_WIDTH + LINE_CLASS_WIDTH;
    localparam integer DATA_ROWS = 512;

    typedef enum logic [1:0] {
        REFILL_IDLE,
        REFILL_REQ,
        REFILL_DATA
    } refill_state_t;

    refill_state_t refill_state_q;

    // ----------------------------------------------------------------
    // Cache arrays
    // ----------------------------------------------------------------

    // 512 x 72 maps directly to one RAMB36 in simple-dual-port mode. The
    // upper eight bits occupy the primitive parity storage and hold four
    // predecode bits for each of the two 32-bit instructions.
    (* ram_style = "block" *)
    logic [71:0] data_mem [0:DATA_ROWS-1];
    (* ram_style = "distributed" *)
    logic [TAG_RAM_WIDTH-1:0] tag_mem [0:SETS-1];
    logic [SETS-1:0] line_valid_q;

    logic [71:0] lookup_payload_q;
    logic [BLOCK_CLASS_WIDTH-1:0] lookup_class_q;

    // ----------------------------------------------------------------
    // One-cycle lookup pipeline
    // ----------------------------------------------------------------

    logic        lookup_valid_q;
    logic        lookup_hit_q;
    logic        lookup_refill_hit_q;
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

    wire irom_req_fire = irom_req_valid & irom_req_ready;
    wire [INDEX_WIDTH-1:0] irom_req_index = irom_req_addr[11:4];
    wire [TAG_WIDTH-1:0] irom_req_tag = irom_req_addr[19:12];
    wire irom_req_in_window =
        irom_req_addr[31:20] == ICACHE_ADDR_PREFIX;
    wire irom_req_block = irom_req_addr[3];
    wire [INDEX_WIDTH:0] irom_req_data_row = {
        irom_req_index,
        irom_req_block
    };

    // A registered local hit is consumed by the frontend in this cycle, so
    // its lookup slot may be replaced by the next BP request at the same edge.
    // A miss retains ownership until it has been copied to pending_miss.
    assign irom_req_ready =
        (~lookup_valid_q | lookup_hit_q)
        & ~pending_miss_valid_q
        & ~miss_resp_valid_q;

    // BP-stage hit computation. The address is applied to tag LUTRAM and data
    // BRAM together; only the already-decided hit/refill source bits cross the
    // BP->F0 edge. Split wide equalities so Vivado can evaluate their groups
    // in parallel rather than building serial carry chains.
    wire [TAG_RAM_WIDTH-1:0] irom_req_tag_payload =
        tag_mem[irom_req_index];
    wire [TAG_WIDTH-1:0] irom_req_cached_tag =
        irom_req_tag_payload[TAG_WIDTH-1:0];
    wire [LINE_CLASS_WIDTH-1:0] irom_req_line_class =
        irom_req_tag_payload[TAG_RAM_WIDTH-1:TAG_WIDTH];
    wire [TAG_WIDTH-1:0] irom_req_tag_diff =
        irom_req_cached_tag ^ irom_req_tag;
    wire irom_req_tag_eq0 = ~|irom_req_tag_diff[3:0];
    wire irom_req_tag_eq1 = ~|irom_req_tag_diff[7:4];
    wire irom_req_array_hit =
        irom_req_in_window
        & line_valid_q[irom_req_index]
        & irom_req_tag_eq0 & irom_req_tag_eq1;

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
    wire irom_req_refill_hit =
        (refill_state_q == REFILL_DATA)
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

    logic [27:0] refill_line_addr_q;
    logic        refill_block_q;
    logic        refill_second_block_q;
    logic        refill_response_needed_q;
    logic        refill_drop_q;
    logic        refill_beat_q;
    logic [31:0] refill_word0_q;
    logic [ 1:0] refill_block_resp_q;

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
    wire refill_block_commit =
        refill_block_complete
        & ~refill_drop_q
        & ~irom_req_kill;

    wire [INDEX_WIDTH-1:0] refill_index = refill_line_addr_q[7:0];
    wire [TAG_WIDTH-1:0] refill_tag = refill_line_addr_q[15:8];
    wire refill_in_window =
        refill_line_addr_q[27:16] == ICACHE_ADDR_PREFIX;
    wire [INDEX_WIDTH:0] refill_data_row = {
        refill_index,
        refill_block_q
    };
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
    wire [LINE_CLASS_WIDTH-1:0] refill_line_class =
        refill_block_q
            ? {refill_block_class, refill_buffer_block0_class_q}
            : {refill_buffer_block1_class_q, refill_block_class};

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
                line_valid_q[refill_index] <= 1'b0;
            if (refill_line_complete_ok) begin
                tag_mem[refill_index] <= {refill_line_class, refill_tag};
                line_valid_q[refill_index] <= 1'b1;
            end
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
    wire lookup_hit = lookup_valid_q & lookup_hit_q;
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
        lookup_refill_hit_q
            ? lookup_refill_payload
            : lookup_payload_q;
    wire [BLOCK_CLASS_WIDTH-1:0] lookup_hit_class =
        lookup_refill_hit_q
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
    end
`endif

endmodule
