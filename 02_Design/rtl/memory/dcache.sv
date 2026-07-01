// ============================================================
// Module: dcache
// Description: 2KB, 2-way set-associative, Write-Through + Write-No-Allocate
//              Data Cache with Store Buffer
//
// Architecture:
//   - Internal EX->MEM pipeline register (synced with cpu_top's ex_mem_reg)
//   - Tag: LUTRAM async read, result latched EX->MEM
//   - Data: BRAM sync read (addr in EX, data in MEM)
//   - Hit detection: MEM stage (combinational)
//   - Load miss: FSM -> refill line from memory backend -> S_DONE
//   - Store hit: WT to cache + store buffer -> memory backend
//   - Store miss: no allocate, store buffer only
//   - Recent-store buffer: retain the latest two stores after backend drain;
//     a fully covered load miss is completed without a line refill
//   - Store-forward: when a store hit writes data to BRAM, the value is
//     forwarded to bypass the 1-cycle BRAM read latency
// ============================================================

module dcache #(
    // Local BRAM backend can discard an in-flight read burst on flush.
    // AXI cannot generally cancel an accepted read, so keep this off there.
    parameter bit BACKEND_CANCEL = 1'b0,
    // Contest BRAM path: bypass the generic backend FSM and drive the
    // external simple-dual-port BRAM directly.
    parameter bit DIRECT_BRAM = 1'b0,
    // BRAM contest path: fetch the missed word first, then wrap inside the
    // 16B line. Keep disabled for generic linear-burst backends.
    parameter bit CRITICAL_WORD_FIRST = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,

    // --- EX stage inputs ---
    input  logic        cpu_req,
    input  logic        cpu_wr,
    input  logic [31:0] cpu_addr,
    input  logic [ 3:0] cpu_wea,
    input  logic [31:0] cpu_wdata,
    input  logic [ 3:0] cpu_load_mask,

    // --- MEM stage outputs ---
    output logic [31:0] cpu_rdata,
    output logic        cpu_ready,

    // Pipeline synchronization
    input  logic        pipeline_stall,  // from cpu_top: ~mem_allowin (keep EX->MEM reg in sync)

    // Pipeline flush
    input  logic        flush,

    // External memory backend interface.
    // Read miss requests use a 4-beat line burst. Store buffer drains use a
    // single write beat with byte strobes.
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic        mem_req_write,
    output logic [31:0] mem_req_addr,
    output logic [ 7:0] mem_req_len,
    output logic [31:0] mem_req_wdata,
    output logic [ 3:0] mem_req_wstrb,

    input  logic        mem_rd_valid,
    output logic        mem_rd_ready,
    input  logic [31:0] mem_rd_data,
    input  logic        mem_rd_last,
    input  logic [ 1:0] mem_rd_resp,
    output logic        mem_rd_cancel,

    input  logic        mem_wr_valid,
    output logic        mem_wr_ready,
    input  logic [ 1:0] mem_wr_resp,

    // Direct BRAM backend interface. Used only when DIRECT_BRAM=1.
    output logic        bram_rd_en,
    output logic [15:0] bram_rd_addr,
    input  logic [31:0] bram_rd_data,
    output logic [15:0] bram_wr_addr,
    output logic [ 3:0] bram_wea,
    output logic [31:0] bram_wdata
);

    // ================================================================
    //  Parameters
    // ================================================================
    localparam WAYS       = 2;
    localparam SETS       = 64;
    localparam LINE_WORDS = 4;
    localparam TAG_W      = 8;    // addr[17:10]
    localparam INDEX_W    = 6;    // addr[9:4]
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

    // ================================================================
    //  EX-stage address decomposition
    // ================================================================
    wire [TAG_W-1:0]   ex_tag   = cpu_addr[17:10];
    wire [INDEX_W-1:0] ex_index = cpu_addr[9:4];
    wire [WORD_W-1:0]  ex_word  = cpu_addr[3:2];

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
    logic [ 3:0]        mem_load_mask;

    // pipeline_advance must match cpu_top's mem_allowin to keep DCache's
    // internal EX->MEM register synchronized with cpu_top's ex_mem_reg.
    // NOTE: Do NOT add "| flush" - flush no longer force-kills the current
    // MEM instruction in ex_mem_reg (see fix: gate ~mem_branch_flush inside
    // mem_allowin path). Both must stall/advance together.
    wire pipeline_advance = ~pipeline_stall;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_req   <= 1'b0;
            mem_tag   <= '0;
            mem_index <= '0;
            mem_word  <= '0;
            mem_addr  <= 32'd0;
            mem_wr    <= 1'b0;
            mem_wea   <= 4'd0;
            mem_wdata <= 32'd0;
            mem_load_mask <= 4'd0;
        end else if (pipeline_advance) begin
            mem_req   <= cpu_req & ~flush;
            mem_tag   <= ex_tag;
            mem_index <= ex_index;
            mem_word  <= ex_word;
            mem_addr  <= cpu_addr;
            mem_wr    <= cpu_wr;
            mem_wea   <= cpu_wea;
            mem_wdata <= cpu_wdata;
            mem_load_mask <= cpu_load_mask;
        end
    end

    // ================================================================
    //  FSM types & signals (declared early for simulator compatibility)
    // ================================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_REFILL_REQ,     // issue line-read request to backend
        S_REFILL_DATA,    // receive line data beats from backend
        S_REFILL_DROP,    // drain an aborted refill after pipeline flush
        S_DONE,
        S_SB_DRAIN_REQ,   // issue store-buffer write request to backend
        S_SB_DRAIN_RESP   // wait for backend write response
    } state_t;

    (* fsm_encoding = "one_hot" *) state_t state;
    state_t state_next;
    wire state_idle          = (state == S_IDLE);
    wire state_refill_req    = (state == S_REFILL_REQ);
    wire state_refill_data   = (state == S_REFILL_DATA);
    wire state_refill_drop   = (state == S_REFILL_DROP);
    wire state_done          = (state == S_DONE);
    wire state_sb_drain_req  = (state == S_SB_DRAIN_REQ);
    wire state_sb_drain_resp = (state == S_SB_DRAIN_RESP);
    wire refill_start;
    logic [WORD_W-1:0]  refill_beat;  // counts data beats received (0..LINE_WORDS-1)
    wire                refill_data_fire; // current cycle has accepted backend data
    logic               refill_way;
    logic [TAG_W-1:0]   refill_tag;
    logic [INDEX_W-1:0] refill_index;
    logic [31:0]        refill_fetch_addr;
    logic [WORD_W-1:0]  refill_target_word;
    wire  [WORD_W-1:0]  refill_word;
    wire [INDEX_W+WORD_W-1:0] refill_write_addr;
    wire                refill_cache_write;
    logic               refill_cpu_pending;
    wire                refill_target_fire;

    // ================================================================
    //  Tag RAM (LUTRAM, async read)
    // ================================================================
    (* ram_style = "distributed" *)
    logic [TAG_W-1:0] tag_mem [WAYS-1:0][SETS-1:0];
    logic             tag_vld [WAYS-1:0][SETS-1:0];

    // Async read with EX-stage index. Refill writes the tag at the clock edge
    // entering S_DONE, so by the S_DONE cycle the next EX tag read sees it.
    wire [TAG_W-1:0] tag_rd_data [WAYS-1:0];
    wire             tag_rd_vld  [WAYS-1:0];
    assign tag_rd_data[0] = tag_mem[0][ex_index];
    assign tag_rd_data[1] = tag_mem[1][ex_index];
    assign tag_rd_vld[0]  = tag_vld[0][ex_index];
    assign tag_rd_vld[1]  = tag_vld[1][ex_index];

    // Latch tag read results EX->MEM
    logic [TAG_W-1:0] mem_tag_rd [WAYS-1:0];
    logic             mem_tag_vld [WAYS-1:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_tag_rd[0]  <= '0;  mem_tag_vld[0] <= 1'b0;
            mem_tag_rd[1]  <= '0;  mem_tag_vld[1] <= 1'b0;
        end else if (pipeline_advance) begin
            mem_tag_rd[0]  <= tag_rd_data[0];
            mem_tag_vld[0] <= tag_rd_vld[0];
            mem_tag_rd[1]  <= tag_rd_data[1];
            mem_tag_vld[1] <= tag_rd_vld[1];
        end
    end

    // ================================================================
    //  Hit detection (MEM stage)
    //  Refill forward covers an immediate same-line access after line fill.
    //  With the current tag write edge it is normally redundant, but it keeps
    //  the next-cycle hit decision independent of LUTRAM read/write phasing.
    // ================================================================
    logic refill_tag_fwd_valid;
    logic refill_tag_fwd_way;
    logic [TAG_W-1:0]   refill_tag_fwd_tag;
    logic [INDEX_W-1:0] refill_tag_fwd_index;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            refill_tag_fwd_valid <= 1'b0;
            refill_tag_fwd_way   <= 1'b0;
            refill_tag_fwd_tag   <= '0;
            refill_tag_fwd_index <= '0;
        end else begin
            if (state_done) begin
                refill_tag_fwd_valid <= 1'b1;
                refill_tag_fwd_way   <= refill_way;
                refill_tag_fwd_tag   <= refill_tag;
                refill_tag_fwd_index <= refill_index;
            end else if (pipeline_advance) begin
                refill_tag_fwd_valid <= 1'b0;
            end
        end
    end

    // Patched tag match: apply refill forward if same set
    wire refill_tag_fwd_match = refill_tag_fwd_valid
                              & (refill_tag_fwd_index == mem_index)
                              & (refill_tag_fwd_tag == mem_tag);

    wire hit_w0_raw = mem_tag_vld[0] & (mem_tag_rd[0] == mem_tag);
    wire hit_w1_raw = mem_tag_vld[1] & (mem_tag_rd[1] == mem_tag);
    wire hit_w0 = hit_w0_raw | (refill_tag_fwd_match & ~refill_tag_fwd_way);
    wire hit_w1 = hit_w1_raw | (refill_tag_fwd_match &  refill_tag_fwd_way);
    wire cache_hit = hit_w0 | hit_w1;
    wire hit_way = hit_w1;

    // ================================================================
    //  Data RAM - BRAM IP instances (one per way)
    // ================================================================
    logic [31:0] data_rd [WAYS-1:0];
    wire [INDEX_W+WORD_W-1:0] data_rd_addr = {ex_index, ex_word};

    wire [INDEX_W+WORD_W-1:0] data_bram_rd_addr = data_rd_addr;

    // BRAM write port signals (unified MUX, defined later)
    wire  [ 3:0] data_bram_wea  [WAYS-1:0];
    wire  [INDEX_W+WORD_W-1:0] data_bram_waddr [WAYS-1:0];
    wire  [31:0] data_bram_wdata [WAYS-1:0];

    // BRAM read port enable: read on pipeline advance.
    wire data_bram_rd_en = pipeline_advance;

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
    logic [1:0]  direct_rd_valid_pipe;
    logic [1:0]  direct_rd_last_pipe;
    logic [WORD_W:0] direct_rd_issue_count;

    // ================================================================
    //  Store Forwarding
    //  A store hit writes the cache RAM at the same edge that a following load
    //  may read it. READ_FIRST BRAM returns the old word, so hold the store
    //  payload for one cycle and merge it into the MEM-stage read result.
    // ================================================================
    logic        store_fwd_valid;
    logic        store_fwd_way;
    logic [INDEX_W+WORD_W-1:0] store_fwd_addr;
    logic [31:0] store_fwd_data;
    logic [ 3:0] store_fwd_wea;

    wire [INDEX_W+WORD_W-1:0] mem_data_addr = {mem_index, mem_word};
    wire store_fwd_hit_w0 = store_fwd_valid & ~store_fwd_way
                          & (mem_data_addr == store_fwd_addr);
    wire store_fwd_hit_w1 = store_fwd_valid &  store_fwd_way
                          & (mem_data_addr == store_fwd_addr);
    wire [3:0] store_fwd_wea_w0 = store_fwd_hit_w0 ? store_fwd_wea : 4'b0000;
    wire [3:0] store_fwd_wea_w1 = store_fwd_hit_w1 ? store_fwd_wea : 4'b0000;
    wire [31:0] data_rd_fwd [WAYS-1:0];

    assign data_rd_fwd[0] = merge_bytes(data_rd[0], store_fwd_data, store_fwd_wea_w0);
    assign data_rd_fwd[1] = merge_bytes(data_rd[1], store_fwd_data, store_fwd_wea_w1);

    // ================================================================
    //  LRU (1-bit per set)
    // ================================================================
    logic [SETS-1:0] lru;
    wire lru_victim = lru[mem_index];

    // ================================================================
    //  Store Buffer interface
    // ================================================================
    wire [1:0]  sb_pending_q;
    wire [1:0]  sb_recent_valid_q;
    wire        sb_alloc_sel;
    wire        sb_drain_sel;
    wire        sb_any_valid;
    wire        sb_full;
    wire [31:0] sb_head_addr;
    wire [ 3:0] sb_head_wea;
    wire [31:0] sb_head_data;
    wire        sb_resp_fire;
    wire        sb_store_enqueue;
    wire        sb_pop   = sb_resp_fire;
    wire        sb_push  = sb_store_enqueue;
    wire [31:0] sb_push_addr = {mem_addr[31:2], 2'b00};

    // ================================================================
    //  Direct BRAM backend datapath
    //  DRAM4MyOwn has a primitive output register, so read data appears two
    //  clocks after the address edge. Request issue and response acceptance
    //  use independent counters to keep the four-word refill back-to-back.
    // ================================================================
    wire [WORD_W-1:0] direct_rd_issue_beat = direct_rd_issue_count[WORD_W-1:0];
    wire [WORD_W-1:0] direct_rd_issue_word = CRITICAL_WORD_FIRST
                                           ? (refill_target_word + direct_rd_issue_beat)
                                           : direct_rd_issue_beat;

    // Speculatively read the current registered MEM load before hit/miss is
    // known. The physical BRAM read is side-effect free; only direct_start_issue
    // below creates a logical refill token when the request is a real miss.
    // This keeps the recent-store compares off the high-fanout BRAM EN path.
    wire direct_idle_spec_read = DIRECT_BRAM & state_idle & mem_req & ~mem_wr;

    // Beat 0 logical issue: mark the speculative read as refill data during the
    // miss-detect cycle. Later beats continue from the registered refill state.
    wire direct_start_issue = DIRECT_BRAM & refill_start & ~flush;
    wire direct_stream_issue = DIRECT_BRAM
                             & ~flush
                             & (state_refill_req | state_refill_data)
                             & (direct_rd_issue_count < (WORD_W + 1)'(LINE_WORDS));
    wire direct_rd_issue_en = direct_start_issue | direct_stream_issue;
    wire direct_rd_issue_last = direct_stream_issue
                              & (direct_rd_issue_beat == WORD_W'(LINE_WORDS - 1));

    // Precompute both address candidates. The registered FSM state performs
    // the late selection; the tag-miss result only validates refill data.
    wire [WORD_W-1:0] direct_start_word = CRITICAL_WORD_FIRST ? mem_word : '0;
    wire [15:0] direct_start_addr_candidate = {mem_addr[17:4], direct_start_word};
    wire [15:0] direct_stream_addr_candidate = {
        refill_fetch_addr[17:4], direct_rd_issue_word
    };

    // Physical read enable is intentionally independent of direct_start_issue.
    // Keep ENB active while valid responses remain in the BRAM/output-register
    // pipeline; otherwise the final refill word never reaches doutb.
    assign bram_rd_en   = direct_idle_spec_read
                        | direct_stream_issue
                        | (|direct_rd_valid_pipe);
    assign bram_rd_addr = state_idle
                        ? direct_start_addr_candidate
                        : direct_stream_addr_candidate;
    assign bram_wr_addr = (DIRECT_BRAM & state_sb_drain_req) ? sb_head_addr[17:2] : 16'd0;
    assign bram_wea     = (DIRECT_BRAM & state_sb_drain_req) ? sb_head_wea : 4'd0;
    assign bram_wdata   = sb_head_data;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            direct_rd_valid_pipe <= 2'b00;
            direct_rd_last_pipe  <= 2'b00;
            direct_rd_issue_count <= '0;
        end else if (DIRECT_BRAM) begin
            if (flush) begin
                direct_rd_valid_pipe <= 2'b00;
                direct_rd_last_pipe  <= 2'b00;
                direct_rd_issue_count <= '0;
            end else begin
                direct_rd_valid_pipe <= {direct_rd_valid_pipe[0], direct_rd_issue_en};
                direct_rd_last_pipe  <= {direct_rd_last_pipe[0], direct_rd_issue_last};
                if (direct_start_issue)
                    direct_rd_issue_count <= (WORD_W + 1)'(1);
                else if (direct_stream_issue)
                    direct_rd_issue_count <= direct_rd_issue_count + 1'b1;
            end
        end else begin
            direct_rd_valid_pipe <= 2'b00;
            direct_rd_last_pipe  <= 2'b00;
            direct_rd_issue_count <= '0;
        end
    end

    wire        backend_req_ready = DIRECT_BRAM ? 1'b1 : mem_req_ready;
    wire        backend_rd_valid  = DIRECT_BRAM ? direct_rd_valid_pipe[1] : mem_rd_valid;
    wire [31:0] backend_rd_data   = DIRECT_BRAM ? bram_rd_data      : mem_rd_data;
    wire        backend_rd_last   = DIRECT_BRAM ? direct_rd_last_pipe[1] : mem_rd_last;
    wire        backend_rd_ready  = state_refill_data | state_refill_drop;
    wire        backend_wr_valid  = DIRECT_BRAM ? state_sb_drain_resp : mem_wr_valid;
    wire        backend_wr_ready  = state_sb_drain_resp;

    wire [31:0] miss_buffer_rdata;
    wire        miss_buffer_covers_load;

    dcache_store_buffer u_store_buffer (
        .clk                (clk),
        .rst_n              (rst_n),
        .push               (sb_push),
        .push_addr          (sb_push_addr),
        .push_wea           (mem_wea),
        .push_data          (mem_wdata),
        .pop                (sb_pop),
        .any_pending        (sb_any_valid),
        .full               (sb_full),
        .drain_addr         (sb_head_addr),
        .drain_wea          (sb_head_wea),
        .drain_data         (sb_head_data),
        .lookup_addr        (mem_addr),
        .lookup_mask        (mem_load_mask),
        .lookup_covers      (miss_buffer_covers_load),
        .lookup_data        (miss_buffer_rdata),
        .refill_capture     (refill_start),
        .refill_line_addr   (mem_addr),
        .refill_word        (refill_word),
        .refill_base_data   (backend_rd_data),
        .refill_merged_data (refill_write_data),
        .pending_q          (sb_pending_q),
        .recent_valid_q     (sb_recent_valid_q),
        .alloc_sel          (sb_alloc_sel),
        .drain_sel          (sb_drain_sel)
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

    // MEM-stage control signals. Keep the late tag compare on load-hit and
    // cache-write decisions; store retirement only needs store-buffer space.
    wire idle_mem_req = state_idle & mem_req;
    wire idle_load    = idle_mem_req & ~mem_wr;
    wire idle_store   = idle_mem_req &  mem_wr;
    wire idle_store_accept = idle_store & ~sb_full;

    wire idle_load_hit   = idle_load &  cache_hit;
    wire idle_load_miss  = idle_load & ~cache_hit;
    wire idle_store_hit  = idle_store &  cache_hit;
    wire idle_store_miss = idle_store & ~cache_hit;
    wire miss_buffer_hit = idle_load_miss & miss_buffer_covers_load;
    wire sb_conflict     = idle_store & sb_full;
    wire store_hit_accept  = idle_store_hit & ~sb_full;
    wire store_miss_accept = idle_store_miss & ~sb_full;
    assign sb_store_enqueue = idle_store_accept;

    wire idle_refill_start = idle_load_miss & ~miss_buffer_hit;
    wire idle_drain_start  = sb_conflict
                           | (sb_any_valid & ~idle_store_accept & ~idle_load_miss);
    assign refill_start = idle_refill_start;

    wire refill_req_fire = state_refill_req & backend_req_ready;
    wire refill_data_last = refill_data_fire & (refill_beat == WORD_W'(LINE_WORDS - 1));
    wire refill_complete = refill_data_last & ~flush;
    assign refill_word = CRITICAL_WORD_FIRST
                       ? (refill_target_word + refill_beat)
                       : refill_beat;
    assign refill_target_fire = refill_data_fire
                              & refill_cpu_pending
                              & (refill_word == refill_target_word)
                              & ~flush;
    wire refill_cancel = (refill_req_fire & flush)
                       | (state_refill_data & flush);
    wire refill_drop_done = state_refill_drop & backend_rd_valid & backend_rd_ready & backend_rd_last;
    wire sb_req_fire = state_sb_drain_req & backend_req_ready;
    assign sb_resp_fire = state_sb_drain_resp & backend_wr_valid & backend_wr_ready;

    always_comb begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (idle_drain_start)
                    state_next = S_SB_DRAIN_REQ;
                else if (idle_refill_start)
                    state_next = S_REFILL_REQ;
            end

            S_REFILL_REQ: begin
                if (refill_req_fire)
                    state_next = flush ? (BACKEND_CANCEL ? S_IDLE : S_REFILL_DROP) : S_REFILL_DATA;
                else if (flush)
                    state_next = S_IDLE;
            end

            S_REFILL_DATA: begin
                if (flush)
                    // A non-cancellable backend has nothing left to drop when
                    // flush coincides with the accepted final beat.
                    state_next = (BACKEND_CANCEL | refill_data_last)
                               ? S_IDLE
                               : S_REFILL_DROP;
                else if (refill_data_last)
                    state_next = S_DONE;
            end

            S_REFILL_DROP: begin
                if (refill_drop_done)
                    state_next = S_IDLE;
            end

            S_DONE:
                state_next = S_IDLE;
            S_SB_DRAIN_REQ: begin
                if (sb_req_fire)
                    state_next = S_SB_DRAIN_RESP;
            end
            S_SB_DRAIN_RESP: begin
                if (sb_resp_fire)
                    state_next = S_IDLE;
            end
            default:
                state_next = S_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            refill_beat <= '0;
            refill_way      <= 1'b0;
            refill_tag      <= '0;
            refill_index      <= '0;
            refill_fetch_addr <= 32'd0;
            refill_target_word <= '0;
            refill_cpu_pending <= 1'b0;
            refill_target_valid <= 1'b0;
            refill_target_data  <= 32'd0;
        end else begin
            if (refill_start) begin
                refill_beat         <= '0;
                refill_way          <= lru_victim;
                refill_tag          <= mem_tag;
                refill_index        <= mem_index;
                refill_fetch_addr   <= CRITICAL_WORD_FIRST
                                     ? {mem_addr[31:4], mem_word, 2'b00}
                                     : {mem_addr[31:4], 4'b0000};
                refill_target_word  <= mem_word;
                refill_cpu_pending  <= 1'b1;
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
            end else if (refill_cancel || refill_drop_done) begin
                refill_cpu_pending <= 1'b0;
            end else if (state_done) begin
                refill_cpu_pending <= 1'b0;
            end
        end
    end

    assign refill_data_fire = state_refill_data & backend_rd_valid & backend_rd_ready;

    // ================================================================
    //  Data RAM write - unified write port MUX for BRAM IP
    //  Refill and store are mutually exclusive, so they share Port A.
    // ================================================================
    assign refill_write_addr = {refill_index, refill_word};
    wire [INDEX_W+WORD_W-1:0] store_data_addr    = {mem_index, mem_word};

    // Track whether a store hit is writing cache this cycle (for forwarding).
    // Store misses are write-no-allocate: they only enqueue the store buffer.
    wire        store_cache_write = store_hit_accept;
    wire        store_cache_write_way = hit_way;
    wire [INDEX_W+WORD_W-1:0] store_cache_write_addr = store_data_addr;
    wire [31:0] store_cache_write_data = mem_wdata;
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

    // Store forward register: capture store info at clock edge
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            store_fwd_valid <= 1'b0;
            store_fwd_way   <= 1'b0;
            store_fwd_addr  <= '0;
            store_fwd_data  <= 32'd0;
            store_fwd_wea   <= 4'd0;
        end else begin
            store_fwd_valid <= store_cache_write;
            store_fwd_way  <= store_cache_write_way;
            store_fwd_addr <= store_cache_write_addr;
            store_fwd_data <= store_cache_write_data;
            store_fwd_wea  <= store_cache_write_wea;
        end
    end

    // ================================================================
    //  Tag RAM write
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int w = 0; w < WAYS; w++)
                for (int s = 0; s < SETS; s++) begin
                    tag_vld[w][s] <= 1'b0;
                    tag_mem[w][s] <= '0;
                end
        end else begin
            // Invalidate victim at refill START so a mid-refill flush
            // leaves no valid-but-corrupted line (BRAM partially overwritten).
            if (refill_start)
                tag_vld[lru_victim][mem_index] <= 1'b0;
            // Validate and write tag at the edge entering S_DONE. During
            // S_DONE the next EX tag read already sees the updated LUTRAM.
            if (refill_complete) begin
                tag_vld[refill_way][refill_index] <= 1'b1;
                tag_mem[refill_way][refill_index] <= refill_tag;
            end
        end
    end

    // ================================================================
    //  LRU update
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n)
            lru <= '0;
        else begin
            if (state_idle && mem_req && cache_hit)
                lru[mem_index] <= ~hit_way;
            if (state_done)
                lru[refill_index] <= ~refill_way;
        end
    end

    // ================================================================
    //  External memory backend request/response
    // ================================================================
    assign mem_req_valid = state_refill_req | state_sb_drain_req;
    assign mem_req_write = state_sb_drain_req;
    assign mem_req_addr  = mem_req_write ? sb_head_addr : refill_fetch_addr;
    assign mem_req_len   = mem_req_write ? 8'd0 : 8'(LINE_WORDS - 1);
    assign mem_req_wdata = sb_head_data;
    assign mem_req_wstrb = sb_head_wea;

    assign mem_rd_ready  = backend_rd_ready;
    assign mem_rd_cancel = BACKEND_CANCEL & refill_cancel;
    assign mem_wr_ready  = backend_wr_ready;

    // ================================================================
    //  CPU read data MUX (MEM stage)
    //  Priority: refill target > recent-store miss hit > cache BRAM
    // ================================================================
    always_comb begin
        if (refill_target_fire)
            cpu_rdata = refill_write_data;
        else if (state_done && refill_cpu_pending && ~mem_wr)
            cpu_rdata = refill_target_valid ? refill_target_data : 32'd0;
        else if (miss_buffer_hit)
            cpu_rdata = miss_buffer_rdata;
        else
            cpu_rdata = hit_way ? data_rd_fwd[1] : data_rd_fwd[0];
    end

    // ================================================================
    //  CPU ready
    // ================================================================
    wire refill_cpu_ready = refill_target_fire
                          | (state_done & refill_cpu_pending);
    wire idle_cpu_ready = idle_load_hit | miss_buffer_hit | idle_store_accept;

    assign cpu_ready = ~mem_req
                     | refill_cpu_ready
                     | idle_cpu_ready;

    // ================================================================
    //  Background SB drain: when idle, SB valid, and no higher-priority
    //  load-miss refill or store-hit conflict -> S_SB_DRAIN_REQ
    //  Already handled in FSM next-state logic above.
    // ================================================================

endmodule
