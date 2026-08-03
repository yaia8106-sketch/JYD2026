// ============================================================
// Module: dcache
// Description: NSCSCC-only 4KB, 2-way set-associative data cache.
//
// Architecture:
//   - Internal EX->MEM pipeline register (synced with cpu_top's ex_mem_reg)
//   - Tag: LUTRAM async read and EX-stage compare, hit result latched EX->MEM
//   - Data: BRAM sync read (addr in EX, data in MEM)
//   - 16-byte line, four-beat critical-word-first AXI WRAP refill
//   - Load miss: optionally write back a dirty victim, then refill the line
//   - WB store hit: update the cache and set one dirty bit
//   - WB store miss: save the store, refill, merge its byte lanes, mark dirty
//   - A one-cycle BRAM RAW-collision bypass handles an immediately following
//     same-word load without a store queue or a load stall
//   - Way/refill/uncached load data is formatted in parallel before late select
// ============================================================

module dcache (
    input  logic        clk,
    input  logic        rst_n,

    // --- EX stage inputs ---
    input  logic        cpu_req,
    input  logic        cpu_wr,
    input  logic [31:0] cpu_addr,
    input  logic [ 8:0] cpu_lookup_addr, // addr[10:2] from the short LSU adder
    input  logic [ 3:0] cpu_wea,
    input  logic [31:0] cpu_wdata,       // raw, aligned after the EX->MEM register
    input  logic [ 1:0] cpu_load_size,
    input  logic        cpu_load_unsigned,
    input  logic        cpu_uncached,

    // --- MEM stage outputs ---
    output logic [31:0] cpu_rdata,
    output logic        cpu_ready,

    // Pipeline synchronization
    input  logic        pipeline_stall,  // from cpu_top: ~mem_allowin (keep EX->MEM reg in sync)

    // Pipeline flush
    input  logic        flush,

    // External memory backend interface. Commands and write data use separate
    // ready/valid channels so writeback lines remain a 32-bit beat stream.
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic        mem_req_write,
    output logic [31:0] mem_req_addr,
    output logic [ 7:0] mem_req_len,
    output logic [ 1:0] mem_req_burst,

    output logic        mem_w_valid,
    input  logic        mem_w_ready,
    output logic [31:0] mem_w_data,
    output logic [ 3:0] mem_w_strb,
    output logic        mem_w_last,

    input  logic        mem_rd_valid,
    output logic        mem_rd_ready,
    input  logic [31:0] mem_rd_data,
    input  logic        mem_rd_last,
    input  logic [ 1:0] mem_rd_resp,
    output logic        mem_rd_cancel,

    input  logic        mem_wr_valid,
    output logic        mem_wr_ready,
    input  logic [ 1:0] mem_wr_resp
);

    // ================================================================
    //  Parameters
    // ================================================================
    localparam WAYS       = 2;
    localparam SETS       = 128;
    localparam LINE_WORDS = 4;
    localparam TAG_W      = 21;
    localparam INDEX_W    = 7;    // addr[10:4]
    localparam WORD_W     = 2;    // addr[3:2]

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

    function automatic [31:0] format_load_data (
        input logic [31:0] raw_data,
        input logic [ 1:0] addr_low,
        input logic [ 1:0] load_size,
        input logic        load_unsigned
    );
        logic [31:0] shifted;
        begin
            // Preserve the shared load formatter's literal logical-shift
            // behavior even though LA32R traps misaligned half/word accesses.
            case (addr_low)
                2'd0: shifted = raw_data;
                2'd1: shifted = { 8'd0, raw_data[31:8]};
                2'd2: shifted = {16'd0, raw_data[31:16]};
                default: shifted = {24'd0, raw_data[31:24]};
            endcase

            case (load_size)
                2'b00: format_load_data = {
                    {24{shifted[7] & ~load_unsigned}}, shifted[7:0]
                };
                2'b01: format_load_data = {
                    {16{shifted[15] & ~load_unsigned}}, shifted[15:0]
                };
                2'b10: format_load_data = shifted;
                default: format_load_data = 32'd0;
            endcase
        end
    endfunction

    // ================================================================
    //  EX-stage address decomposition
    // ================================================================
    wire [TAG_W-1:0]   ex_tag   = cpu_addr[31:11];
    wire [INDEX_W-1:0] ex_index = cpu_lookup_addr[8:2];
    wire [WORD_W-1:0]  ex_word  = cpu_lookup_addr[1:0];

    // ================================================================
    //  Internal EX->MEM register (synced with cpu_top's ex_mem_reg)
    // ================================================================
    logic [TAG_W-1:0]   mem_tag;
    logic [INDEX_W-1:0] mem_index;
    logic [WORD_W-1:0]  mem_word;
    logic [31:0]        mem_addr;
    logic               mem_req;
    logic               mem_wr;
    logic [ 3:0]        mem_wea;
    logic [31:0]        mem_wdata;
    logic [ 1:0]        mem_load_size;
    logic               mem_load_unsigned;
    logic               mem_uncached;

    // pipeline_advance must match cpu_top's mem_allowin to keep DCache's
    // internal EX->MEM register synchronized with cpu_top's ex_mem_reg.
    // NOTE: Do NOT add "| flush" - flush no longer force-kills the current
    // MEM instruction in ex_mem_reg (see fix: gate ~mem_branch_flush inside
    // mem_allowin path). Both must stall/advance together.
    wire pipeline_advance = ~pipeline_stall;

    always_ff @(posedge clk) begin
        if (!rst_n)
            mem_req <= 1'b0;
        else if (pipeline_advance)
            mem_req <= cpu_req & ~flush;
    end

    // mem_req is the sole owner of the EX/MEM request payload.  Flush/reset
    // therefore touch only that valid bit; a normal advance is the payload CE.
    always_ff @(posedge clk) begin
        if (pipeline_advance) begin
            mem_tag   <= ex_tag;
            mem_index <= ex_index;
            mem_word  <= ex_word;
            mem_addr  <= cpu_addr;
            mem_wr    <= cpu_wr;
            mem_wea   <= cpu_wea;
            mem_wdata <= cpu_wdata;
            mem_load_size <= cpu_load_size;
            mem_load_unsigned <= cpu_load_unsigned;
            mem_uncached <= cpu_uncached;
        end
    end

    // ================================================================
    //  FSM types & signals (declared early for simulator compatibility)
    // ================================================================
    typedef enum logic [3:0] {
        S_IDLE,
        S_REFILL_REQ,     // issue line-read request to backend
        S_REFILL_DATA,    // receive line data beats from backend
        S_REFILL_DROP,    // drain an aborted refill after pipeline flush
        S_DONE,
        S_REPLAY,         // re-read a request held while WB miss work used Port B
        S_WB_CAPTURE,     // read four victim words into the local line buffer
        S_WB_REQ,         // issue one four-beat writeback command
        S_WB_DATA,        // stream four writeback words
        S_WB_RESP,        // wait for the write response
        S_UC_REQ,         // issue one uncached read/write command
        S_UC_READ,        // wait for the uncached read beat
        S_UC_WRITE_DATA,  // send the single uncached write beat
        S_UC_WRITE_RESP   // wait for the uncached write response
    } state_t;

    (* fsm_encoding = "one_hot" *) state_t state;
    state_t state_next;
    wire state_idle          = (state == S_IDLE);
    wire state_refill_req    = (state == S_REFILL_REQ);
    wire state_refill_data   = (state == S_REFILL_DATA);
    wire state_refill_drop   = (state == S_REFILL_DROP);
    wire state_done          = (state == S_DONE);
    wire state_replay        = (state == S_REPLAY);
    wire state_wb_capture    = (state == S_WB_CAPTURE);
    wire state_wb_req        = (state == S_WB_REQ);
    wire state_wb_data       = (state == S_WB_DATA);
    wire state_wb_resp       = (state == S_WB_RESP);
    wire state_uc_req        = (state == S_UC_REQ);
    wire state_uc_read       = (state == S_UC_READ);
    wire state_uc_write_data = (state == S_UC_WRITE_DATA);
    wire state_uc_write_resp = (state == S_UC_WRITE_RESP);
    wire refill_start;
    logic [WORD_W-1:0]  refill_beat;  // counts data beats received (0..LINE_WORDS-1)
    wire                refill_data_fire; // current cycle has accepted backend data
    logic               refill_way;
    logic [TAG_W-1:0]   refill_tag;
    logic [INDEX_W-1:0] refill_index;
    logic [31:0]        refill_fetch_addr;
    logic [WORD_W-1:0]  refill_target_word;
    logic               refill_is_store;
    logic [31:0]        refill_store_data;
    logic [ 3:0]        refill_store_wea;
    logic [31:0]        victim_line_addr;
    wire  [WORD_W-1:0]  refill_word;
    wire [INDEX_W+WORD_W-1:0] refill_write_addr;
    wire                refill_cache_write;
    logic               refill_cpu_pending;
    wire                refill_target_fire;

    // ================================================================
    //  Tag RAM (LUTRAM, async read)
    // ================================================================
    // Keep each way in a distinct array.  A dynamic first dimension makes
    // Vivado scalarize every tag bit; explicit way arrays infer compact
    // single-write/asynchronous-read distributed RAMs for the full AXI tag.
    (* ram_style = "distributed" *)
    logic [TAG_W-1:0] tag_mem_way0 [0:SETS-1];
    (* ram_style = "distributed" *)
    logic [TAG_W-1:0] tag_mem_way1 [0:SETS-1];
    logic             tag_vld [WAYS-1:0][SETS-1:0];
    logic [SETS-1:0]   dirty_way0;
    logic [SETS-1:0]   dirty_way1;

    // The normal lookup uses the EX address. S_REPLAY is the one exception:
    // writeback capture temporarily owns data RAM Port B, so the held MEM
    // request is looked up again before returning to S_IDLE.
    wire [TAG_W-1:0] tag_rd_data [WAYS-1:0];
    wire             tag_rd_vld  [WAYS-1:0];
    // Each packed 128-entry distributed Tag RAM expands into many RAM64
    // primitives.  A single selected index used to drive both ways, giving
    // every low address bit roughly 150 physical loads.  Keep independent
    // selected-index cones per way and let synthesis replicate each cone at a
    // small, explicit fanout boundary.  Both expressions are identical, so
    // lookup/replay behavior and latency remain unchanged.
    (* keep = "true", max_fanout = 24 *)
    wire [INDEX_W-1:0] tag_read_index_w0 = state_replay
                                         ? mem_index : ex_index;
    (* keep = "true", max_fanout = 24 *)
    wire [INDEX_W-1:0] tag_read_index_w1 = state_replay
                                         ? mem_index : ex_index;
    wire [TAG_W-1:0] tag_lookup_tag = state_replay ? mem_tag : ex_tag;
    assign tag_rd_data[0] = tag_mem_way0[tag_read_index_w0];
    assign tag_rd_data[1] = tag_mem_way1[tag_read_index_w1];
    assign tag_rd_vld[0]  = tag_vld[0][tag_read_index_w0];
    assign tag_rd_vld[1]  = tag_vld[1][tag_read_index_w1];

    // Keep the raw tag for miss-victim metadata.  Capture valid and the four
    // tag-compare groups independently across EX->MEM; the final five-input
    // hit reduction is deliberately moved behind that edge.
    logic [TAG_W-1:0] mem_tag_rd [WAYS-1:0];
    logic             mem_tag_vld [WAYS-1:0];

    // Compare in parallel before the EX->MEM edge. A monolithic 21-bit
    // equality can become a serial carry chain on 7-series devices; four
    // independent groups plus one late five-input AND keep the logic shallow.
    wire [TAG_W-1:0] tag_diff_w0 = tag_rd_data[0] ^ tag_lookup_tag;
    wire [TAG_W-1:0] tag_diff_w1 = tag_rd_data[1] ^ tag_lookup_tag;
    wire tag_eq_w0_0 = ~|tag_diff_w0[5:0];
    wire tag_eq_w0_1 = ~|tag_diff_w0[11:6];
    wire tag_eq_w0_2 = ~|tag_diff_w0[17:12];
    wire tag_eq_w0_3 = ~|tag_diff_w0[20:18];
    wire tag_eq_w1_0 = ~|tag_diff_w1[5:0];
    wire tag_eq_w1_1 = ~|tag_diff_w1[11:6];
    wire tag_eq_w1_2 = ~|tag_diff_w1[17:12];
    wire tag_eq_w1_3 = ~|tag_diff_w1[20:18];
    wire [3:0] tag_eq_group_w0 = {
        tag_eq_w0_3, tag_eq_w0_2, tag_eq_w0_1, tag_eq_w0_0
    };
    wire [3:0] tag_eq_group_w1 = {
        tag_eq_w1_3, tag_eq_w1_2, tag_eq_w1_1, tag_eq_w1_0
    };

    logic [3:0] mem_tag_eq_w0;
    logic [3:0] mem_tag_eq_w1;

`ifndef SYNTHESIS
    // Executable reference for the pre-refactor behavior: combine valid and
    // all four compare groups before the EX->MEM edge.
    wire lookup_hit_reference_w0 = tag_rd_vld[0]
                                 & (&tag_eq_group_w0);
    wire lookup_hit_reference_w1 = tag_rd_vld[1]
                                 & (&tag_eq_group_w1);
    logic mem_hit_reference_w0;
    logic mem_hit_reference_w1;
`endif

    always_ff @(posedge clk) begin
        if (pipeline_advance | state_replay) begin
            mem_tag_rd[0]  <= tag_rd_data[0];
            mem_tag_vld[0] <= tag_rd_vld[0];
            mem_tag_rd[1]  <= tag_rd_data[1];
            mem_tag_vld[1] <= tag_rd_vld[1];
            mem_tag_eq_w0   <= tag_eq_group_w0;
            mem_tag_eq_w1   <= tag_eq_group_w1;
`ifndef SYNTHESIS
            mem_hit_reference_w0 <= lookup_hit_reference_w0;
            mem_hit_reference_w1 <= lookup_hit_reference_w1;
`endif
        end
    end

    // ================================================================
    //  Hit result (MEM stage)
    //
    //  The async valid-array selection and the tag comparison now terminate
    //  at separate registers.  This small reduction consumes the downstream
    //  MEM-stage margin instead of extending the EX lookup path.
    // ================================================================
    wire hit_w0 = mem_tag_vld[0] & (&mem_tag_eq_w0);
    wire hit_w1 = mem_tag_vld[1] & (&mem_tag_eq_w1);
    wire cache_hit = hit_w0 | hit_w1;
    wire hit_way = hit_w1;

    // ================================================================
    //  Data RAM - BRAM IP instances (one per way)
    // ================================================================
    logic [31:0] data_rd [WAYS-1:0];
    logic [31:0] line_buffer [0:LINE_WORDS-1];
    logic [WORD_W:0] wb_read_issue_count;
    logic [WORD_W-1:0] wb_read_capture_count;
    logic               wb_read_valid_q;
    logic [WORD_W-1:0]  wb_send_beat;

    wire wb_read_issue = state_wb_capture
                       & (wb_read_issue_count
                          < (WORD_W + 1)'(LINE_WORDS));
    wire wb_capture_fire = state_wb_capture & wb_read_valid_q;
    wire wb_capture_last = wb_capture_fire
                         & (wb_read_capture_count
                            == WORD_W'(LINE_WORDS - 1));
    wire [INDEX_W+WORD_W-1:0] wb_read_addr = {
        refill_index, wb_read_issue_count[WORD_W-1:0]
    };
    wire [31:0] wb_selected_data = refill_way ? data_rd[1] : data_rd[0];

    wire [INDEX_W+WORD_W-1:0] data_rd_addr = {ex_index, ex_word};
    wire [INDEX_W+WORD_W-1:0] replay_read_addr = {mem_index, mem_word};
    wire [INDEX_W+WORD_W-1:0] data_bram_rd_addr =
        wb_read_issue ? wb_read_addr
      : state_replay  ? replay_read_addr
                      : data_rd_addr;

    // BRAM write port signals (unified MUX, defined later)
    wire  [ 3:0] data_bram_wea  [WAYS-1:0];
    wire  [INDEX_W+WORD_W-1:0] data_bram_waddr [WAYS-1:0];
    wire  [31:0] data_bram_wdata [WAYS-1:0];

    // Victim capture and replay are registered miss-only address candidates.
    // Normal load-hit timing still sees only the original pipeline address.
    wire data_bram_rd_en = pipeline_advance | wb_read_issue | state_replay;

    // Gate BRAM read address: hold previous address during stalls
    // This prevents BRAM from outputting wrong data during pipeline stalls
    logic [INDEX_W+WORD_W-1:0] bram_rd_addr_r;
    always_ff @(posedge clk) begin
        if (data_bram_rd_en)
            bram_rd_addr_r <= data_bram_rd_addr;
    end
    wire [INDEX_W+WORD_W-1:0] bram_rd_addr_gated = data_bram_rd_en ? data_bram_rd_addr : bram_rd_addr_r;

    // Raw BRAM output - directly used as data_rd
    // BRAM has inherent 1-cycle read latency, matching original FF behavior

    dcache_data_ram u_data_way0 (
        .clka  (clk),
        .wea   (data_bram_wea[0]),
        .addra (data_bram_waddr[0]),
        .dina  (data_bram_wdata[0]),
        .clkb  (clk),
        .addrb (bram_rd_addr_gated),
        .doutb (data_rd[0])
    );

    dcache_data_ram u_data_way1 (
        .clka  (clk),
        .wea   (data_bram_wea[1]),
        .addra (data_bram_waddr[1]),
        .dina  (data_bram_wdata[1]),
        .clkb  (clk),
        .addrb (bram_rd_addr_gated),
        .doutb (data_rd[1])
    );

    wire  [31:0] refill_write_data;
    logic        refill_target_valid;
    logic [31:0] refill_target_data;
    logic        raw_bypass_valid;
    logic [31:0] raw_bypass_data;
    logic [ 3:0] raw_bypass_wea;

    // ================================================================
    //  LRU (1-bit per set)
    // ================================================================
    logic [SETS-1:0] lru;
    wire lru_victim = lru[mem_index];

    // Invalid ways are always cheaper victims than a valid LRU way. Prepare
    // both candidates in parallel and register the final selection at miss
    // acceptance; dirty metadata is deliberately absent from the hit path.
    wire victim_way_candidate = ~mem_tag_vld[0] ? 1'b0
                              : ~mem_tag_vld[1] ? 1'b1
                              : lru_victim;
    wire victim_valid_candidate = victim_way_candidate
                                ? mem_tag_vld[1] : mem_tag_vld[0];
    wire victim_dirty_candidate = victim_way_candidate
                                ? dirty_way1[mem_index]
                                : dirty_way0[mem_index];
    wire [TAG_W-1:0] victim_tag_candidate = victim_way_candidate
                                          ? mem_tag_rd[1]
                                          : mem_tag_rd[0];
    wire victim_needs_writeback = victim_valid_candidate
                                & victim_dirty_candidate;

    // The NSCSCC build always uses the generic streaming AXI backend.
    wire        backend_req_ready = mem_req_ready;
    wire        backend_rd_valid  = mem_rd_valid;
    wire [31:0] backend_rd_data   = mem_rd_data;
    wire        backend_rd_last   = mem_rd_last;
    wire        backend_rd_ready  = state_refill_data | state_refill_drop
                                  | state_uc_read;
    wire        backend_wr_valid  = mem_wr_valid;
    wire        backend_wr_ready  = state_wb_resp | state_uc_write_resp;

    // Delay byte-lane alignment until after the internal EX->MEM register.
    // This keeps the variable shift off the CPU ALU address path.
    wire [31:0] mem_wdata_aligned = mem_wdata << {mem_addr[1:0], 3'b0};
    wire [3:0] refill_store_merge_wea =
        (refill_is_store & (refill_word == refill_target_word))
        ? refill_store_wea : 4'b0000;
    assign refill_write_data = merge_bytes(
        backend_rd_data, refill_store_data, refill_store_merge_wea
    );

    // ================================================================
    //  FSM - variable-latency refill/store backend
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= state_next;
    end

    // A store miss is captured as the sole active miss and may retire
    // immediately; later memory operations remain backpressured until its
    // write-allocate refill completes.
    wire idle_mem_req = state_idle & mem_req;
    wire idle_uncached = idle_mem_req & mem_uncached;
    wire idle_load    = idle_mem_req & ~mem_uncached & ~mem_wr;
    wire idle_store   = idle_mem_req & ~mem_uncached &  mem_wr;
    wire idle_store_accept = idle_store;

    wire idle_load_hit   = idle_load &  cache_hit;
    wire idle_load_miss  = idle_load & ~cache_hit;
    wire idle_store_hit  = idle_store &  cache_hit;
    wire idle_store_miss = idle_store & ~cache_hit;
    wire store_hit_accept = idle_store_hit;
    wire idle_refill_start = idle_load_miss | idle_store_miss;
    wire idle_uncached_start = idle_uncached;
    assign refill_start = idle_refill_start;

    wire refill_req_fire = state_refill_req & backend_req_ready;
    // An accepted AXI read cannot be cancelled. A killed load drains the
    // remainder without installing it; a store allocation must always finish.
    wire refill_abort = flush & ~refill_is_store;
    wire refill_data_last = refill_data_fire & (refill_beat == WORD_W'(LINE_WORDS - 1));
    wire refill_complete = refill_data_last & ~refill_abort;
    assign refill_word = refill_target_word + refill_beat;
    assign refill_target_fire = refill_data_fire
                              & refill_cpu_pending
                              & (refill_word == refill_target_word)
                              & ~refill_abort;
    wire refill_drop_done = state_refill_drop & backend_rd_valid & backend_rd_ready & backend_rd_last;
    wire wb_req_fire = state_wb_req & backend_req_ready;
    wire wb_data_fire = state_wb_data & mem_w_ready;
    wire wb_data_last_fire = wb_data_fire
                           & (wb_send_beat == WORD_W'(LINE_WORDS - 1));
    wire wb_resp_fire = state_wb_resp & backend_wr_valid
                      & backend_wr_ready;
    wire wb_resp_ok = wb_resp_fire & (mem_wr_resp == 2'b00);
    wire uc_req_fire = state_uc_req & backend_req_ready;
    wire uc_read_fire = state_uc_read & backend_rd_valid
                     & backend_rd_ready & backend_rd_last;
    wire uc_write_data_fire = state_uc_write_data & mem_w_ready;
    wire uc_write_fire = state_uc_write_resp & backend_wr_valid
                      & backend_wr_ready;

    always_comb begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (idle_uncached_start)
                    state_next = S_UC_REQ;
                else if (idle_refill_start) begin
                    if (victim_needs_writeback)
                        state_next = S_WB_CAPTURE;
                    else
                        state_next = S_REFILL_REQ;
                end
            end

            S_REFILL_REQ: begin
                if (refill_req_fire) begin
                    if (refill_abort)
                        state_next = S_REFILL_DROP;
                    else
                        state_next = S_REFILL_DATA;
                end
                else if (refill_abort)
                    state_next = S_IDLE;
            end

            S_REFILL_DATA: begin
                if (refill_abort)
                    // A non-cancellable backend has nothing left to drop when
                    // flush coincides with the accepted final beat.
                    if (refill_data_last)
                        state_next = S_IDLE;
                    else
                        state_next = S_REFILL_DROP;
                else if (refill_data_last)
                    state_next = S_DONE;
            end

            S_REFILL_DROP: begin
                if (refill_drop_done)
                    state_next = S_IDLE;
            end

            S_DONE: begin
                if (mem_req)
                    state_next = S_REPLAY;
                else
                    state_next = S_IDLE;
            end
            S_REPLAY:
                state_next = S_IDLE;
            S_WB_CAPTURE: begin
                if (refill_abort)
                    // No external write command exists yet, so a killed load
                    // can retain the original dirty cache line.
                    state_next = S_IDLE;
                else if (wb_capture_last)
                    state_next = S_WB_REQ;
            end
            S_WB_REQ: begin
                if (wb_req_fire)
                    // Once accepted, the write transaction is never cancelled.
                    state_next = S_WB_DATA;
                else if (refill_abort)
                    state_next = S_IDLE;
            end
            S_WB_DATA: begin
                if (wb_data_last_fire)
                    state_next = S_WB_RESP;
            end
            S_WB_RESP: begin
                if (wb_resp_fire) begin
                    if (mem_wr_resp != 2'b00) begin
                        if (refill_abort)
                            state_next = S_IDLE;
                        else
                            state_next = S_WB_REQ;
                    end
                    else if (refill_is_store)
                        state_next = S_REFILL_REQ;
                    else if (refill_abort | ~refill_cpu_pending)
                        state_next = S_IDLE;
                    else
                        state_next = S_REFILL_REQ;
                end
            end
            S_UC_REQ: begin
                if (uc_req_fire) begin
                    if (mem_wr)
                        state_next = S_UC_WRITE_DATA;
                    else
                        state_next = S_UC_READ;
                end
            end
            S_UC_READ: begin
                if (uc_read_fire)
                    state_next = S_IDLE;
            end
            S_UC_WRITE_DATA: begin
                if (uc_write_data_fire)
                    state_next = S_UC_WRITE_RESP;
            end
            S_UC_WRITE_RESP: begin
                if (uc_write_fire)
                    state_next = S_IDLE;
            end
            default:
                state_next = S_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (refill_start) begin
            refill_beat         <= '0;
            refill_way          <= victim_way_candidate;
            refill_tag          <= mem_tag;
            refill_index        <= mem_index;
            refill_fetch_addr   <= {mem_addr[31:4], mem_word, 2'b00};
            refill_target_word  <= mem_word;
            refill_is_store     <= mem_wr;
            refill_store_data   <= mem_wdata_aligned;
            refill_store_wea    <= mem_wea;
            victim_line_addr    <= {
                victim_tag_candidate, mem_index, 4'b0000
            };
            refill_cpu_pending  <= ~mem_wr;
            refill_target_valid <= 1'b0;
            refill_target_data  <= 32'd0;
        end else if (refill_data_fire) begin
            refill_beat <= refill_beat + 1'b1;
            if (refill_word == refill_target_word) begin
                refill_target_valid <= 1'b1;
                refill_target_data  <= refill_write_data;
            end
            if (refill_target_fire)
                refill_cpu_pending <= 1'b0;
        end else if (refill_abort | refill_drop_done)
            refill_cpu_pending <= 1'b0;
        else if (state_done)
            refill_cpu_pending <= 1'b0;
    end

    assign refill_data_fire = state_refill_data & backend_rd_valid & backend_rd_ready;

    // The same four local words first snapshot a dirty victim and are then
    // reused as the refill shadow. Port B is synchronous, so valid_q aligns
    // each registered RAM result with its capture index.
    always_ff @(posedge clk) begin
        if (refill_start) begin
            wb_read_issue_count   <= '0;
            wb_read_capture_count <= '0;
            wb_read_valid_q       <= 1'b0;
            wb_send_beat          <= '0;
        end else begin
            if (state_wb_capture) begin
                wb_read_valid_q <= wb_read_issue;
                if (wb_read_issue)
                    wb_read_issue_count <= wb_read_issue_count + 1'b1;
                if (wb_capture_fire) begin
                    line_buffer[wb_read_capture_count] <= wb_selected_data;
                    wb_read_capture_count <= wb_read_capture_count + 1'b1;
                end
            end else begin
                wb_read_valid_q <= 1'b0;
            end

            if (wb_req_fire)
                wb_send_beat <= '0;
            else if (wb_data_fire & ~wb_data_last_fire)
                wb_send_beat <= wb_send_beat + 1'b1;

            if (refill_data_fire)
                line_buffer[refill_word] <= refill_write_data;
        end
    end

    // ================================================================
    //  Data RAM write - unified write port MUX for BRAM IP
    //  Refill and store are mutually exclusive, so they share Port A.
    // ================================================================
    assign refill_write_addr = {refill_index, refill_word};
    wire [INDEX_W+WORD_W-1:0] store_data_addr    = {mem_index, mem_word};

    // A store hit updates the selected cache word. A store miss is merged into
    // the critical word during its write-allocate refill.
    wire        store_cache_write = store_hit_accept;
    wire        store_cache_write_way = hit_way;
    wire [INDEX_W+WORD_W-1:0] store_cache_write_addr = store_data_addr;
    wire [31:0] store_cache_write_data = mem_wdata_aligned;
    wire [ 3:0] store_cache_write_wea = mem_wea;

    // Refill write: one cache data RAM write per accepted backend read beat.
    assign refill_cache_write = refill_data_fire;

    // Unified BRAM write port MUX per way (unrolled, no for-loop w[0])
    // Priority: refill > store (they are mutually exclusive by FSM design)

    // Way 0
    wire refill_w0 = refill_cache_write & ~refill_way;
    wire store_w0  = store_cache_write & ~store_cache_write_way;
    assign data_bram_wea[0]   = refill_w0 ? 4'b1111          : store_w0 ? store_cache_write_wea  : 4'b0000;
    assign data_bram_waddr[0] = refill_w0 ? refill_write_addr   : store_w0 ? store_cache_write_addr : '0;
    assign data_bram_wdata[0] = refill_w0 ? refill_write_data  : store_w0 ? store_cache_write_data : 32'd0;

    // Way 1
    wire refill_w1 = refill_cache_write &  refill_way;
    wire store_w1  = store_cache_write &  store_cache_write_way;
    assign data_bram_wea[1]   = refill_w1 ? 4'b1111          : store_w1 ? store_cache_write_wea  : 4'b0000;
    assign data_bram_waddr[1] = refill_w1 ? refill_write_addr   : store_w1 ? store_cache_write_addr : '0;
    assign data_bram_wdata[1] = refill_w1 ? refill_write_data  : store_w1 ? store_cache_write_data : 32'd0;

    // ================================================================
    //  One-cycle BRAM read-after-write collision bypass
    //
    //  In the store-MEM/load-EX cycle, compare the complete aligned word
    //  addresses directly. A matching physical word necessarily selects the
    //  same cache way as the already-confirmed store hit, so this comparison
    //  does not need to wait for the younger load's tag-RAM lookup.
    //
    //  The payload registers are written unconditionally.  Capture a harmless
    //  same-word candidate without the late request/flush cone, then qualify
    //  its use with the registered MEM-stage load token below.
    // ================================================================
    wire [29:0] raw_bypass_word_addr_diff =
        cpu_addr[31:2] ^ mem_addr[31:2];
    wire raw_bypass_addr_eq0 = ~|raw_bypass_word_addr_diff[5:0];
    wire raw_bypass_addr_eq1 = ~|raw_bypass_word_addr_diff[11:6];
    wire raw_bypass_addr_eq2 = ~|raw_bypass_word_addr_diff[17:12];
    wire raw_bypass_addr_eq3 = ~|raw_bypass_word_addr_diff[23:18];
    wire raw_bypass_addr_eq4 = ~|raw_bypass_word_addr_diff[29:24];
    wire raw_bypass_same_word =
        raw_bypass_addr_eq0 & raw_bypass_addr_eq1
        & raw_bypass_addr_eq2 & raw_bypass_addr_eq3
        & raw_bypass_addr_eq4;
    wire raw_bypass_capture = pipeline_advance
                            & store_cache_write
                            & raw_bypass_same_word;

`ifndef SYNTHESIS
    wire raw_bypass_capture_reference =
        pipeline_advance & store_cache_write
        & cpu_req & ~cpu_wr & ~cpu_uncached & ~flush
        & raw_bypass_same_word;
    logic raw_bypass_valid_reference_q;
`endif

    always_ff @(posedge clk) begin
        raw_bypass_data <= store_cache_write_data;
        raw_bypass_wea  <= store_cache_write_wea;
        if (!rst_n)
            raw_bypass_valid <= 1'b0;
        else
            raw_bypass_valid <= raw_bypass_capture;
    end

    // ================================================================
    //  Tag RAM write
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int w = 0; w < WAYS; w++)
                for (int s = 0; s < SETS; s++)
                    tag_vld[w][s] <= 1'b0;
        end else begin
            // Retain a dirty victim until its writeback succeeds. Invalidate
            // the selected way only when the replacement read is accepted.
            if (refill_req_fire)
                tag_vld[refill_way][refill_index] <= 1'b0;

            // Validate and write tag at the edge entering S_DONE. During
            // S_DONE the next EX tag read already sees the updated LUTRAM.
            if (refill_complete)
                tag_vld[refill_way][refill_index] <= 1'b1;
        end
    end

    // Dirty/tag payload is masked by tag_vld. Every allocation or store hit
    // initializes it before it can influence victim writeback selection.
    always_ff @(posedge clk) begin
        if (refill_req_fire) begin
            if (refill_way)
                dirty_way1[refill_index] <= 1'b0;
            else
                dirty_way0[refill_index] <= 1'b0;
        end

        // A successful writeback leaves a killed load's original line valid
        // but clean. On the normal path it is invalidated next.
        if (wb_resp_ok) begin
            if (refill_way)
                dirty_way1[refill_index] <= 1'b0;
            else
                dirty_way0[refill_index] <= 1'b0;
        end

        if (store_cache_write) begin
            if (store_cache_write_way)
                dirty_way1[mem_index] <= 1'b1;
            else
                dirty_way0[mem_index] <= 1'b1;
        end

        if (refill_complete) begin
            if (refill_way) begin
                tag_mem_way1[refill_index] <= refill_tag;
                dirty_way1[refill_index] <= refill_is_store;
            end else begin
                tag_mem_way0[refill_index] <= refill_tag;
                dirty_way0[refill_index] <= refill_is_store;
            end
        end
    end

    // ================================================================
    //  LRU update
    // ================================================================
    always_ff @(posedge clk) begin
        if (state_idle && mem_req && cache_hit)
            lru[mem_index] <= ~hit_way;
        if (state_done)
            lru[refill_index] <= ~refill_way;
    end

    // ================================================================
    //  External memory backend request/response
    // ================================================================
    assign mem_req_valid = state_refill_req | state_wb_req | state_uc_req;
    assign mem_req_write = state_wb_req | (state_uc_req & mem_wr);
    assign mem_req_addr  = state_wb_req ? victim_line_addr
                         : state_uc_req ? {mem_addr[31:2], 2'b00}
                         : refill_fetch_addr;
    assign mem_req_len   = state_wb_req ? 8'(LINE_WORDS - 1)
                         : state_uc_req ? 8'd0
                                        : 8'(LINE_WORDS - 1);
    assign mem_req_burst = state_refill_req ? 2'b10 : 2'b01;
    assign mem_w_valid   = state_wb_data | state_uc_write_data;
    assign mem_w_data    = state_wb_data ? line_buffer[wb_send_beat]
                         : state_uc_write_data ? mem_wdata_aligned
                                               : 32'd0;
    assign mem_w_strb    = state_wb_data ? 4'b1111
                         : state_uc_write_data ? mem_wea : 4'b0000;
    assign mem_w_last    = state_wb_data
                         ? (wb_send_beat == WORD_W'(LINE_WORDS - 1))
                         : 1'b1;

    assign mem_rd_ready  = backend_rd_ready;
    assign mem_rd_cancel = 1'b0;
    assign mem_wr_ready  = backend_wr_ready;

    // ================================================================
    //  CPU read data formatting and late source selection (MEM stage)
    //
    //  Each BRAM way and the miss/uncached response are formatted in parallel.
    //  The hit-way/source controls therefore select complete 32-bit results at
    //  the end instead of sitting in front of byte extraction and extension.
    // ================================================================
    wire raw_bypass_apply = raw_bypass_valid
                          & mem_req & ~mem_wr & ~mem_uncached;
    wire [3:0] raw_bypass_mask = raw_bypass_wea
                               & {4{raw_bypass_apply}};
    wire [31:0] cache_read_data_way0 = merge_bytes(
        data_rd[0],
        raw_bypass_data,
        raw_bypass_mask
    );
    wire [31:0] cache_read_data_way1 = merge_bytes(
        data_rd[1],
        raw_bypass_data,
        raw_bypass_mask
    );

    wire [31:0] formatted_way0 = format_load_data(
        cache_read_data_way0, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );
    wire [31:0] formatted_way1 = format_load_data(
        cache_read_data_way1, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );

    wire special_read_valid = uc_read_fire
                            | refill_target_fire
                            | (state_done & refill_cpu_pending & ~mem_wr);
    logic [31:0] special_read_data;
    always_comb begin
        if (uc_read_fire)
            special_read_data = backend_rd_data;
        else if (refill_target_fire)
            special_read_data = refill_write_data;
        else if (state_done && refill_cpu_pending && ~mem_wr)
            special_read_data = refill_target_valid
                              ? refill_target_data : 32'd0;
        else
            special_read_data = 32'd0;
    end
    wire [31:0] formatted_special = format_load_data(
        special_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );

    always_comb begin
        if (special_read_valid)
            cpu_rdata = formatted_special;
        else if (hit_way)
            cpu_rdata = formatted_way1;
        else
            cpu_rdata = formatted_way0;
    end

    // ================================================================
    //  CPU ready
    // ================================================================
    wire refill_cpu_ready = refill_target_fire
                          | (state_done & refill_cpu_pending);
    wire idle_load_ready = idle_load_hit;
    wire idle_cpu_ready = idle_load_ready | idle_store_accept;

    assign cpu_ready = ~mem_req
                     | refill_cpu_ready
                     | idle_cpu_ready
                     | uc_read_fire
                     | uc_write_fire;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && mem_req) begin
            if (hit_w0 !== mem_hit_reference_w0)
                $fatal(1, "DCache way-0 split hit pipeline changed behavior");
            if (hit_w1 !== mem_hit_reference_w1)
                $fatal(1, "DCache way-1 split hit pipeline changed behavior");
        end

        if (!rst_n)
            raw_bypass_valid_reference_q <= 1'b0;
        else begin
            raw_bypass_valid_reference_q <= raw_bypass_capture_reference;
            if (mem_req && ~mem_wr && ~mem_uncached
                && (raw_bypass_valid !== raw_bypass_valid_reference_q))
                $fatal(1, "Speculative RAW candidate changed load-visible bypass");
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (refill_req_fire
                && (refill_way ? dirty_way1[refill_index]
                               : dirty_way0[refill_index]))
                $error("DCache started overwriting a dirty victim");
            if (state_wb_req
                && (!mem_req_valid || !mem_req_write
                    || (mem_req_len != 8'(LINE_WORDS - 1))
                    || (mem_req_addr != victim_line_addr)
                    || (mem_req_burst != 2'b01)))
                $error("DCache writeback command shape mismatch");
            if (state_refill_req
                && (mem_req_burst != 2'b10))
                $error("DCache refill burst type mismatch");
            if (refill_data_fire
                && (backend_rd_last
                    != (refill_beat == WORD_W'(LINE_WORDS - 1))))
                $error("DCache four-beat refill RLAST mismatch");
            if (wb_data_fire
                && (mem_w_last
                    != (wb_send_beat == WORD_W'(LINE_WORDS - 1))))
                $error("DCache writeback LAST mismatch");
        end
    end
`endif

endmodule
