// ============================================================
// Module: dcache
// Description: NSCSCC-only 64KB direct-mapped data cache.
//
// Architecture:
//   - Internal EX->MEM pipeline register (synced with cpu_top's ex_mem_reg)
//   - Tag: LUTRAM async read and EX-stage compare, hit result latched EX->MEM
//   - Data: BRAM sync read (addr in EX, data in MEM)
//   - 32-byte line, eight-beat critical-word-first AXI WRAP refill
//   - Load miss: snapshot a dirty victim, then overlap its writeback with refill
//   - WB store hit: update the cache and set one dirty bit
//   - WB store miss: save the store, refill, merge its byte lanes, mark dirty
//   - A one-cycle BRAM RAW-collision bypass handles an immediately following
//     same-word load without a store queue or a load stall
//   - Hit/refill/uncached load data is formatted before a late source select
// ============================================================

module dcache #(
    // The full 32-bit address is still carried to AXI and to the CPU's
    // architectural exception logic.  These parameters describe only the
    // fixed NSCSCC cacheable window used to shorten internal tag metadata.
    parameter logic [31:0] CACHE_ADDR_BASE = 32'h1C08_0000,
    parameter logic [31:0] CACHE_ADDR_MASK = 32'hFFF8_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // --- EX stage inputs ---
    input  logic        cpu_req,
    input  logic        cpu_wr,
    input  logic [31:0] cpu_addr,
    input  logic [16:0] cpu_lookup_addr, // addr[18:2] from the short LSU adder
    input  logic [ 3:0] cpu_wea,
    input  logic [31:0] cpu_wdata,       // raw, aligned after the EX->MEM register
    input  logic [ 1:0] cpu_load_size,
    input  logic        cpu_load_unsigned,
    input  logic        cpu_uncached,

    // --- MEM stage outputs ---
    output logic [31:0] cpu_rdata,
    // Physically independent copy for the remote EX load-repair register.
    output logic [31:0] cpu_rdata_ex,
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
    // Only dirty cache-line eviction commands assert this attribute.  It lets
    // the NSCSCC arbiter overlap the write with reads while uncached/MMIO
    // writes retain their strongly serialized behavior.
    output logic        mem_req_writeback,
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
    localparam SETS       = 2048;
    localparam LINE_WORDS = 8;
    // CACHE_ADDR_MASK fixes addr[31:19].  addr[18:16] is therefore the only
    // tag state required for requests already classified as cacheable using
    // the complete architectural address.
    localparam TAG_W      = 3;
    localparam INDEX_W    = 11;   // addr[15:5]
    localparam WORD_W     = 3;    // addr[4:2]
    // Eight tag banks balance the asynchronous LUTRAM depth against the late
    // registered bank selector.  Each bank contains 256 direct-mapped sets.
    localparam TAG_BANK_BITS    = 3;
    localparam TAG_BANKS        = 1 << TAG_BANK_BITS;
    localparam TAG_BANK_INDEX_W = INDEX_W - TAG_BANK_BITS;
    localparam TAG_BANK_SETS    = SETS / TAG_BANKS;
    localparam logic [12:0] CACHE_ADDR_PREFIX = CACHE_ADDR_BASE[31:19];

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
        begin
            // Select address and size together.  This preserves the previous
            // logical-right-shift behavior for every misaligned combination,
            // but removes the serial 32-bit shift -> size -> sign-extension
            // cone from the BRAM output path.
            case ({load_size, addr_low})
                4'b00_00: format_load_data = {
                    {24{raw_data[7] & ~load_unsigned}}, raw_data[7:0]
                };
                4'b00_01: format_load_data = {
                    {24{raw_data[15] & ~load_unsigned}}, raw_data[15:8]
                };
                4'b00_10: format_load_data = {
                    {24{raw_data[23] & ~load_unsigned}}, raw_data[23:16]
                };
                4'b00_11: format_load_data = {
                    {24{raw_data[31] & ~load_unsigned}}, raw_data[31:24]
                };
                4'b01_00: format_load_data = {
                    {16{raw_data[15] & ~load_unsigned}}, raw_data[15:0]
                };
                4'b01_01: format_load_data = {
                    {16{raw_data[23] & ~load_unsigned}}, raw_data[23:8]
                };
                4'b01_10: format_load_data = {
                    {16{raw_data[31] & ~load_unsigned}}, raw_data[31:16]
                };
                // A logical shift by 24 places zeros in shifted[15:8], so the
                // old signed-halfword result is also zero-extended here.
                4'b01_11: format_load_data = {24'd0, raw_data[31:24]};
                4'b10_00: format_load_data = raw_data;
                4'b10_01: format_load_data = {8'd0, raw_data[31:8]};
                4'b10_10: format_load_data = {16'd0, raw_data[31:16]};
                4'b10_11: format_load_data = {24'd0, raw_data[31:24]};
                default: format_load_data = 32'd0;
            endcase
        end
    endfunction

`ifndef SYNTHESIS
    // Literal reference for the former serial implementation.  Keep it out of
    // synthesis and compare it at the registered request boundary below.
    function automatic [31:0] format_load_data_reference (
        input logic [31:0] raw_data,
        input logic [ 1:0] addr_low,
        input logic [ 1:0] load_size,
        input logic        load_unsigned
    );
        logic [31:0] shifted;
        begin
            case (addr_low)
                2'd0: shifted = raw_data;
                2'd1: shifted = { 8'd0, raw_data[31:8]};
                2'd2: shifted = {16'd0, raw_data[31:16]};
                default: shifted = {24'd0, raw_data[31:24]};
            endcase
            case (load_size)
                2'b00: format_load_data_reference = {
                    {24{shifted[7] & ~load_unsigned}}, shifted[7:0]
                };
                2'b01: format_load_data_reference = {
                    {16{shifted[15] & ~load_unsigned}}, shifted[15:0]
                };
                2'b10: format_load_data_reference = shifted;
                default: format_load_data_reference = 32'd0;
            endcase
        end
    endfunction
`endif

    // ================================================================
    //  EX-stage address decomposition
    // ================================================================
    wire [TAG_W-1:0]   ex_tag   = cpu_lookup_addr[16:14];
    wire [INDEX_W-1:0] ex_index = cpu_lookup_addr[13:3];
    wire [WORD_W-1:0]  ex_word  = cpu_lookup_addr[2:0];

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
        S_WB_CAPTURE,     // read eight victim words into the local line buffer
        S_WB_REQ,         // issue one eight-beat writeback command
        S_WB_JOIN_DONE,   // refill installed; wait for dirty writeback success
        S_WB_JOIN_IDLE,   // killed refill; wait for dirty writeback success
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
    wire state_wb_join_done  = (state == S_WB_JOIN_DONE);
    wire state_wb_join_idle  = (state == S_WB_JOIN_IDLE);
    wire state_uc_req        = (state == S_UC_REQ);
    wire state_uc_read       = (state == S_UC_READ);
    wire state_uc_write_data = (state == S_UC_WRITE_DATA);
    wire state_uc_write_resp = (state == S_UC_WRITE_RESP);
    wire refill_start;
    logic [WORD_W-1:0]  refill_beat;  // counts data beats received (0..LINE_WORDS-1)
    wire                refill_data_fire; // current cycle has accepted backend data
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
    wire                refill_cpu_ready;

    // A dirty victim owns line_buffer until its B response succeeds.  Refill
    // data goes straight to the selected BRAM, so write and read progress can
    // advance independently without a second cache-line buffer.
    typedef enum logic [1:0] {
        WB_IDLE,
        WB_CMD,
        WB_DATA,
        WB_RESP
    } wb_state_t;
    wb_state_t wb_state;
    wire wb_state_cmd  = (wb_state == WB_CMD);
    wire wb_state_data = (wb_state == WB_DATA);
    wire wb_state_resp = (wb_state == WB_RESP);
    logic wb_required;
    logic wb_done;
    logic refill_read_accepted;
    wire refill_complete;
    wire refill_req_fire;

    // ================================================================
    //  Tag RAM (LUTRAM, async read)
    // ================================================================
    // The direct-mapped tag array is split into eight 256-set physical banks.
    // All banks read from local copies of the low index bits in parallel; the
    // three high index bits are registered with the request and perform only
    // the final selection in MEM.
    wire [TAG_BANK_BITS-1:0] refill_tag_bank =
        refill_index[INDEX_W-1 -: TAG_BANK_BITS];
    wire [TAG_BANK_INDEX_W-1:0] refill_tag_set =
        refill_index[TAG_BANK_INDEX_W-1:0];

    wire [TAG_W:0] tag_rd_entry [TAG_BANKS-1:0];
    wire [TAG_W-1:0] tag_rd_data [TAG_BANKS-1:0];
    wire tag_rd_vld [TAG_BANKS-1:0];
    wire tag_rd_match [TAG_BANKS-1:0];

    // Store valid beside tag in LUTRAM and clear all physical banks in
    // parallel during the first 256 cycles after reset. Non-memory pipeline
    // traffic may continue; the first memory request is held until the clear
    // and one replay read have completed.
    logic [TAG_BANK_INDEX_W-1:0] tag_init_set;
    logic tag_init_done;
    logic tag_init_release_q;
    wire tag_init_replay = tag_init_done & ~tag_init_release_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tag_init_set       <= '0;
            tag_init_done      <= 1'b0;
            tag_init_release_q <= 1'b0;
        end else begin
            if (!tag_init_done) begin
                if (tag_init_set
                    == TAG_BANK_INDEX_W'(TAG_BANK_SETS - 1))
                    tag_init_done <= 1'b1;
                else
                    tag_init_set <= tag_init_set + 1'b1;
            end
            // One cycle after the last LUTRAM write, replay any request that
            // entered MEM while initialization was still in progress.
            tag_init_release_q <= tag_init_done;
        end
    end

    wire tag_lookup_from_mem = state_replay | tag_init_replay;
    wire [TAG_BANK_INDEX_W-1:0] tag_read_set_source =
        tag_lookup_from_mem
        ? mem_index[TAG_BANK_INDEX_W-1:0]
        : ex_index[TAG_BANK_INDEX_W-1:0];
    wire [TAG_BANK_BITS-1:0] tag_lookup_bank = tag_lookup_from_mem
        ? mem_index[INDEX_W-1 -: TAG_BANK_BITS]
        : ex_index[INDEX_W-1 -: TAG_BANK_BITS];
    wire [TAG_W-1:0] tag_lookup_tag = tag_lookup_from_mem
        ? mem_tag : ex_tag;

    generate
        for (genvar tag_bank = 0;
             tag_bank < TAG_BANKS;
             tag_bank++) begin : g_tag_bank
            (* ram_style = "distributed" *)
            logic [TAG_W:0] tag_mem [0:TAG_BANK_SETS-1];

            wire [TAG_BANK_INDEX_W-1:0] tag_read_set =
                tag_read_set_source;
            assign tag_rd_entry[tag_bank] = tag_mem[tag_read_set];
            assign tag_rd_data[tag_bank] =
                tag_rd_entry[tag_bank][TAG_W-1:0];
            assign tag_rd_vld[tag_bank] = tag_rd_entry[tag_bank][TAG_W];
            assign tag_rd_match[tag_bank] =
                tag_rd_data[tag_bank] == tag_lookup_tag;

            // One indexed write per physical memory retains the canonical
            // single-write-port LUTRAM template. Refill completion keeps the
            // old priority over invalidation.
            always_ff @(posedge clk) begin
                if (rst_n) begin
                    if (!tag_init_done)
                        tag_mem[tag_init_set] <= '0;
                    else if (refill_complete
                        && (refill_tag_bank
                            == TAG_BANK_BITS'(tag_bank)))
                        tag_mem[refill_tag_set] <= {1'b1, refill_tag};
                    else if (refill_req_fire
                        && (refill_tag_bank
                            == TAG_BANK_BITS'(tag_bank)))
                        tag_mem[refill_tag_set] <= '0;
                end
            end
        end
    endgenerate

    // Dirty metadata has one asynchronous lookup and at most one logical
    // update per cycle. It needs no reset because tag valid masks every entry.
    (* ram_style = "distributed" *)
    logic dirty [0:SETS-1];

    // Capture every physical bank. The registered high index bits choose the
    // architecturally addressed candidate in MEM.
    logic [TAG_W-1:0] mem_tag_rd_bank [TAG_BANKS-1:0];
    logic mem_tag_vld_bank [TAG_BANKS-1:0];
    logic mem_tag_match_bank [TAG_BANKS-1:0];

`ifndef SYNTHESIS
    // Executable reference for the original single-table lookup. It selects
    // the addressed bank before the edge and must agree with the new late
    // selection after the edge.
    wire lookup_hit_reference =
        tag_rd_vld[tag_lookup_bank]
        & tag_rd_match[tag_lookup_bank];
    logic mem_hit_reference;
`endif

    always_ff @(posedge clk) begin
        if (pipeline_advance | state_replay | tag_init_replay) begin
            for (int capture_bank = 0;
                 capture_bank < TAG_BANKS;
                 capture_bank++) begin
                mem_tag_rd_bank[capture_bank]
                    <= tag_rd_data[capture_bank];
                mem_tag_vld_bank[capture_bank]
                    <= tag_rd_vld[capture_bank];
                mem_tag_match_bank[capture_bank]
                    <= tag_rd_match[capture_bank];
            end
`ifndef SYNTHESIS
            mem_hit_reference <= lookup_hit_reference;
`endif
        end
    end

    // ================================================================
    //  Hit result (MEM stage)
    //
    //  Each bank's valid and comparison terminate at separate registers. The
    //  registered high index bits perform only the final bank selection here.
    // ================================================================
    wire [TAG_BANK_BITS-1:0] mem_tag_bank =
        mem_index[INDEX_W-1 -: TAG_BANK_BITS];
    wire [TAG_W-1:0] mem_tag_rd = mem_tag_rd_bank[mem_tag_bank];
    wire mem_tag_vld = mem_tag_vld_bank[mem_tag_bank];
    wire mem_tag_match = mem_tag_match_bank[mem_tag_bank];
    wire tag_hit = mem_tag_vld & mem_tag_match;
    // mem_uncached comes from the full 32-bit window comparison in
    // memory_access_unit.  It is authoritative: an out-of-window address
    // sharing the shortened tag/index must never hit or perturb replacement
    // state.
    wire cache_hit = ~mem_uncached & tag_hit;

    // ================================================================
    //  Data RAM - one 16384x32 logical BRAM bank
    // ================================================================
    logic [31:0] data_rd;
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
    wire [31:0] wb_selected_data = data_rd;

    wire [INDEX_W+WORD_W-1:0] data_rd_addr = {ex_index, ex_word};
    wire [INDEX_W+WORD_W-1:0] replay_read_addr = {mem_index, mem_word};
    wire [INDEX_W+WORD_W-1:0] data_bram_rd_addr =
        wb_read_issue ? wb_read_addr
      : (state_replay | tag_init_replay) ? replay_read_addr
                      : data_rd_addr;

    // BRAM write port signals (unified MUX, defined later)
    wire  [ 3:0] data_bram_wea;
    wire  [INDEX_W+WORD_W-1:0] data_bram_waddr;
    wire  [31:0] data_bram_wdata;

    // Victim capture and replay are registered miss-only address candidates.
    // Normal load-hit timing still sees only the original pipeline address.
    wire data_bram_rd_en = pipeline_advance | wb_read_issue | state_replay
                          | tag_init_replay;

    // Hold the BRAM output with its native ENB instead of muxing the late
    // pipeline-ready response into every address bit.  The same address is
    // sampled on exactly the same edge as before, but AXI write completion now
    // terminates at a local enable instead of the 14-bit address path.

    // Raw BRAM output - directly used as data_rd
    // BRAM has inherent 1-cycle read latency, matching original FF behavior

    dcache_data_ram u_data (
        .clka  (clk),
        .wea   (data_bram_wea),
        .addra (data_bram_waddr),
        .dina  (data_bram_wdata),
        .clkb  (clk),
        .enb   (data_bram_rd_en),
        .addrb (data_bram_rd_addr),
        .doutb (data_rd)
    );

    wire  [31:0] refill_write_data;
    logic        refill_target_valid;
    logic [31:0] refill_target_data;
    logic        raw_bypass_valid;
    logic [31:0] raw_bypass_data;
    logic [ 3:0] raw_bypass_wea;

    // Direct mapping makes the addressed entry the sole victim candidate.
    // Dirty metadata remains absent from the normal hit-result cone.
    wire victim_valid_candidate = mem_tag_vld;
    wire victim_dirty_candidate = dirty[mem_index];
    wire [TAG_W-1:0] victim_tag_candidate = mem_tag_rd;
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
    wire        backend_wr_ready  = wb_state_resp | state_uc_write_resp;

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
    // A request may enter the otherwise-empty MEM stage while tag LUTRAM is
    // being cleared.  Hold it in S_IDLE until the initialization replay has
    // produced trustworthy registered tag and data candidates.
    wire idle_mem_req = state_idle & mem_req & tag_init_release_q;
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

    // An accepted AXI read cannot be cancelled. A killed load drains the
    // remainder without installing it; a store allocation must always finish.
    wire refill_abort = flush & ~refill_is_store;
    wire refill_data_last = refill_data_fire & (refill_beat == WORD_W'(LINE_WORDS - 1));
    assign refill_complete = refill_data_last & ~refill_abort;
    assign refill_word = refill_target_word + refill_beat;
    assign refill_target_fire = refill_data_fire
                              & refill_cpu_pending
                              & (refill_word == refill_target_word)
                              & ~refill_abort;
    wire refill_drop_done = state_refill_drop & backend_rd_valid & backend_rd_ready & backend_rd_last;
    wire wb_req_fire = wb_state_cmd & backend_req_ready;
    wire wb_data_fire = wb_state_data & mem_w_ready;
    wire wb_data_last_fire = wb_data_fire
                           & (wb_send_beat == WORD_W'(LINE_WORDS - 1));
    wire wb_resp_fire = wb_state_resp & backend_wr_valid
                      & backend_wr_ready;
    wire wb_resp_ok = wb_resp_fire & (mem_wr_resp == 2'b00);
    wire writeback_complete_now = ~wb_required | wb_done | wb_resp_ok;
    // A retrying writeback command has priority if it happens to coincide with
    // the still-pending refill command.
    assign refill_req_fire = state_refill_req & ~wb_state_cmd
                           & backend_req_ready;
    // refill_cpu_pending also remembers a one-cycle flush that coincided with
    // acceptance of the non-cancellable writeback command.
    wire refill_cancel_before_read = ~refill_is_store
                                   & (refill_abort | ~refill_cpu_pending);
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
                else if (refill_cancel_before_read) begin
                    if (wb_required & ~writeback_complete_now)
                        state_next = S_WB_JOIN_IDLE;
                    else
                        state_next = S_IDLE;
                end
            end

            S_REFILL_DATA: begin
                if (refill_abort)
                    // A non-cancellable backend has nothing left to drop when
                    // flush coincides with the accepted final beat.
                    if (refill_data_last) begin
                        if (writeback_complete_now)
                            state_next = S_IDLE;
                        else
                            state_next = S_WB_JOIN_IDLE;
                    end
                    else
                        state_next = S_REFILL_DROP;
                else if (refill_data_last) begin
                    if (writeback_complete_now)
                        state_next = S_DONE;
                    else
                        state_next = S_WB_JOIN_DONE;
                end
            end

            S_REFILL_DROP: begin
                if (refill_drop_done) begin
                    if (writeback_complete_now)
                        state_next = S_IDLE;
                    else
                        state_next = S_WB_JOIN_IDLE;
                end
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
                    state_next = S_REFILL_REQ;
                else if (refill_abort)
                    state_next = S_IDLE;
            end
            S_WB_JOIN_DONE: begin
                if (writeback_complete_now)
                    state_next = S_DONE;
            end
            S_WB_JOIN_IDLE: begin
                if (writeback_complete_now)
                    state_next = S_IDLE;
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

    // Dirty writeback is an independent transaction once its command is
    // accepted.  A failed B response replays the same buffered command/data;
    // flush may discard a load refill, but it cannot discard accepted memory
    // side effects or the only surviving copy of the victim line.
    always_ff @(posedge clk) begin
        if (!rst_n)
            wb_state <= WB_IDLE;
        else if (refill_start)
            wb_state <= WB_IDLE;
        else begin
            case (wb_state)
                WB_IDLE: begin
                    if (wb_capture_last & ~refill_abort)
                        wb_state <= WB_CMD;
                end
                WB_CMD: begin
                    if (wb_req_fire)
                        wb_state <= WB_DATA;
                    else if (state_wb_req & refill_abort)
                        wb_state <= WB_IDLE;
                end
                WB_DATA: begin
                    if (wb_data_last_fire)
                        wb_state <= WB_RESP;
                end
                WB_RESP: begin
                    if (wb_resp_fire) begin
                        if (mem_wr_resp == 2'b00)
                            wb_state <= WB_IDLE;
                        else
                            wb_state <= WB_CMD;
                    end
                end
                default:
                    wb_state <= WB_IDLE;
            endcase
        end
    end

    // These are ownership/progress bits, not payload.  They are the only new
    // state needed to join the independently completing read and write paths.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_required <= 1'b0;
            wb_done <= 1'b0;
            refill_read_accepted <= 1'b0;
        end else if (refill_start) begin
            wb_required <= victim_needs_writeback;
            wb_done <= 1'b0;
            refill_read_accepted <= 1'b0;
        end else begin
            if (wb_resp_ok)
                wb_done <= 1'b1;
            if (refill_req_fire)
                refill_read_accepted <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (refill_start) begin
            refill_beat         <= '0;
            refill_tag          <= mem_tag;
            refill_index        <= mem_index;
            refill_fetch_addr   <= {mem_addr[31:5], mem_word, 2'b00};
            refill_target_word  <= mem_word;
            refill_is_store     <= mem_wr;
            refill_store_data   <= mem_wdata_aligned;
            refill_store_wea    <= mem_wea;
            victim_line_addr    <= {
                CACHE_ADDR_PREFIX, victim_tag_candidate,
                mem_index, 5'b00000
            };
            refill_cpu_pending  <= ~mem_wr;
            refill_target_valid <= 1'b0;
            refill_target_data  <= 32'd0;
        end else begin
            if (refill_data_fire) begin
                refill_beat <= refill_beat + 1'b1;
                if (refill_word == refill_target_word) begin
                    refill_target_valid <= 1'b1;
                    refill_target_data  <= refill_write_data;
                end
            end
            if (refill_cpu_ready | refill_abort | refill_drop_done | state_done)
                refill_cpu_pending <= 1'b0;
        end
    end

    assign refill_data_fire = state_refill_data & backend_rd_valid & backend_rd_ready;

    // The eight local words exclusively snapshot the dirty victim until B
    // succeeds. Port B is synchronous, so valid_q aligns each registered RAM
    // result with its capture index. Refill beats never overwrite this buffer.
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
    wire [INDEX_W+WORD_W-1:0] store_cache_write_addr = store_data_addr;
    wire [31:0] store_cache_write_data = mem_wdata_aligned;
    wire [ 3:0] store_cache_write_wea = mem_wea;

    // Refill write: one cache data RAM write per accepted backend read beat.
    assign refill_cache_write = refill_data_fire;

    // Unified BRAM write port MUX.
    // Priority: refill > store (they are mutually exclusive by FSM design)
    assign data_bram_wea = refill_cache_write ? 4'b1111
                         : store_cache_write ? store_cache_write_wea
                                             : 4'b0000;
    assign data_bram_waddr = refill_cache_write ? refill_write_addr
                           : store_cache_write ? store_cache_write_addr
                                               : '0;
    assign data_bram_wdata = refill_cache_write ? refill_write_data
                           : store_cache_write ? store_cache_write_data
                                               : 32'd0;

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
    // Both visible sides of this bypass are cacheable and therefore share the
    // platform-owned addr[31:19] prefix.  Compare only the stored cache word
    // identity, sourced from the parallel short address adder.  Three six-bit
    // groups avoid recreating a serial wide equality/carry structure.
    wire [16:0] raw_bypass_word_addr_diff =
        cpu_lookup_addr ^ {mem_tag, mem_index, mem_word};
    wire raw_bypass_addr_eq0 = ~|raw_bypass_word_addr_diff[5:0];
    wire raw_bypass_addr_eq1 = ~|raw_bypass_word_addr_diff[11:6];
    wire raw_bypass_addr_eq2 = ~|raw_bypass_word_addr_diff[16:12];
    wire raw_bypass_same_word =
        raw_bypass_addr_eq0 & raw_bypass_addr_eq1
        & raw_bypass_addr_eq2;
    wire raw_bypass_capture = pipeline_advance
                            & store_cache_write
                            & raw_bypass_same_word;

`ifndef SYNTHESIS
    wire raw_bypass_capture_reference =
        pipeline_advance & store_cache_write
        & cpu_req & ~cpu_wr & ~cpu_uncached & ~flush
        & (cpu_addr[31:2] == mem_addr[31:2]);
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
    // Dirty/tag payload is masked by tag_vld. Every allocation or store hit
    // initializes it before it can influence victim writeback selection.
    //
    // The four architectural events below are mutually exclusive except that
    // writeback completion may coincide with refill request/completion for the
    // same captured victim. Preserve the old procedural priority exactly:
    // refill install > store hit > writeback clean > refill invalidation.
    logic               dirty_write_valid;
    logic [INDEX_W-1:0] dirty_write_index;
    logic               dirty_write_data;

    always_comb begin
        dirty_write_valid = 1'b0;
        dirty_write_index = refill_index;
        dirty_write_data  = 1'b0;

        if (refill_req_fire) begin
            dirty_write_valid = 1'b1;
        end

        // A successful writeback leaves a killed load's original line valid
        // but clean. On the normal path it is invalidated next.
        if (wb_resp_ok & ~refill_read_accepted) begin
            dirty_write_valid = 1'b1;
        end

        if (store_cache_write) begin
            dirty_write_valid = 1'b1;
            dirty_write_index = mem_index;
            dirty_write_data  = 1'b1;
        end

        if (refill_complete) begin
            dirty_write_valid = 1'b1;
            dirty_write_index = refill_index;
            dirty_write_data  = refill_is_store;
        end
    end

    // One indexed assignment per memory is the canonical single-write-port
    // distributed-RAM template. No reset is required because tag_vld masks every
    // unallocated entry.
    always_ff @(posedge clk) begin
        if (dirty_write_valid)
            dirty[dirty_write_index] <= dirty_write_data;
    end

`ifndef SYNTHESIS
    // The single-write-port representation is cycle-equivalent provided a
    // normal store hit cannot update a different line while refill/writeback
    // metadata is being updated.  Same-line overlaps are legal and the
    // priority above matches the former nonblocking-assignment ordering.
    wire dirty_refill_metadata_event = refill_req_fire
        | (wb_resp_ok & ~refill_read_accepted)
        | refill_complete;
    always_ff @(posedge clk) begin
        if (rst_n && store_cache_write && dirty_refill_metadata_event
                  && (mem_index != refill_index))
            $fatal(1, "DCache dirty metadata received two distinct writes in one cycle");
    end
`endif

    // ================================================================
    //  External memory backend request/response
    // ================================================================
    assign mem_req_valid = wb_state_cmd | state_refill_req | state_uc_req;
    assign mem_req_write = wb_state_cmd | (state_uc_req & mem_wr);
    assign mem_req_writeback = wb_state_cmd;
    assign mem_req_addr  = wb_state_cmd ? victim_line_addr
                         : state_uc_req ? {mem_addr[31:2], 2'b00}
                         : refill_fetch_addr;
    assign mem_req_len   = wb_state_cmd ? 8'(LINE_WORDS - 1)
                         : state_uc_req ? 8'd0
                                        : 8'(LINE_WORDS - 1);
    assign mem_req_burst = (state_refill_req & ~wb_state_cmd)
                         ? 2'b10 : 2'b01;
    assign mem_w_valid   = wb_state_data | state_uc_write_data;
    assign mem_w_data    = wb_state_data ? line_buffer[wb_send_beat]
                         : state_uc_write_data ? mem_wdata_aligned
                                               : 32'd0;
    assign mem_w_strb    = wb_state_data ? 4'b1111
                         : state_uc_write_data ? mem_wea : 4'b0000;
    assign mem_w_last    = wb_state_data
                         ? (wb_send_beat == WORD_W'(LINE_WORDS - 1))
                         : 1'b1;

    assign mem_rd_ready  = backend_rd_ready;
    assign mem_rd_cancel = 1'b0;
    assign mem_wr_ready  = backend_wr_ready;

    // ================================================================
    //  CPU read data formatting and late source selection (MEM stage)
    //
    //  The BRAM hit and miss/uncached responses are formatted in parallel.
    //  The late source control selects complete 32-bit results instead of
    //  sitting in front of byte extraction and extension.
    // ================================================================
    wire raw_bypass_apply = raw_bypass_valid
                          & mem_req & ~mem_wr & ~mem_uncached;
    wire [3:0] raw_bypass_mask = raw_bypass_wea
                               & {4{raw_bypass_apply}};
    wire [31:0] cache_read_data = merge_bytes(
        data_rd,
        raw_bypass_data,
        raw_bypass_mask
    );

    wire [31:0] formatted_hit = format_load_data(
        cache_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );

    wire special_read_valid = uc_read_fire | refill_cpu_ready;
    logic [31:0] special_read_data;
    always_comb begin
        if (uc_read_fire)
            special_read_data = backend_rd_data;
        else if (refill_target_fire)
            special_read_data = refill_write_data;
        else if (refill_cpu_ready)
            special_read_data = refill_target_data;
        else
            special_read_data = 32'd0;
    end
    wire [31:0] formatted_special = format_load_data(
        special_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );

`ifndef SYNTHESIS
    wire [31:0] formatted_hit_reference = format_load_data_reference(
        cache_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );
    wire [31:0] formatted_special_reference = format_load_data_reference(
        special_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );
`endif

    // Duplicate only the late source selector.  Formatting and RAW-merge
    // logic remain shared, while each distant MEM/WB destination receives a
    // physically independent final LUT cone.
    dcache_read_result_select u_read_select_wb (
        .special_valid   (special_read_valid),
        .formatted_hit   (formatted_hit),
        .formatted_special(formatted_special),
        .selected_data   (cpu_rdata)
    );

    dcache_read_result_select u_read_select_ex (
        .special_valid   (special_read_valid),
        .formatted_hit   (formatted_hit),
        .formatted_special(formatted_special),
        .selected_data   (cpu_rdata_ex)
    );

    // ================================================================
    //  CPU ready
    // ================================================================
    assign refill_cpu_ready = refill_cpu_pending
                            & writeback_complete_now
                            & ~refill_abort
                            & (refill_target_fire | refill_target_valid);
    wire idle_load_ready = idle_load_hit;
    wire idle_cpu_ready = idle_load_ready | idle_store_accept;

    assign cpu_ready = ~mem_req
                     | (tag_init_release_q
                        & (refill_cpu_ready
                           | idle_cpu_ready
                           | uc_read_fire
                           | uc_write_fire));

`ifndef SYNTHESIS
    initial begin
        if (CACHE_ADDR_MASK != 32'hFFF8_0000)
            $fatal(1, "DCache three-bit tag requires addr[31:19] fixed");
        if ((CACHE_ADDR_BASE & ~CACHE_ADDR_MASK) != 32'd0)
            $fatal(1, "DCache cacheable window base is not mask-aligned");
    end

    always_ff @(posedge clk) begin
        if (rst_n && mem_req) begin
            if ((formatted_hit !== formatted_hit_reference)
                || (formatted_special !== formatted_special_reference))
                $fatal(1, "DCache parallel load formatter changed behavior");
            if (tag_hit !== mem_hit_reference)
                $fatal(1, "DCache split tag-hit pipeline changed behavior");

            // Both copies are deliberately identical logically; only their
            // physical destinations differ.
            if (cpu_ready && (cpu_rdata_ex !== cpu_rdata))
                $fatal(1, "DCache duplicated load result changed behavior");

            // The shortened tag is legal only after the complete address was
            // classified by the platform window.  This assertion guards the
            // boundary contract without putting a 13-bit comparison onto the
            // synthesized hit path.
            if (mem_uncached !== (((mem_addr & CACHE_ADDR_MASK)
                                  != (CACHE_ADDR_BASE & CACHE_ADDR_MASK))))
                $fatal(1, "DCache cacheability disagrees with full address window");
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
            if (refill_req_fire && wb_required
                && (wb_state == WB_IDLE) && !wb_done && !wb_resp_ok)
                $error("DCache refill lost ownership of its dirty victim buffer");
            if (wb_state_cmd
                && (!mem_req_valid || !mem_req_write
                    || !mem_req_writeback
                    || (mem_req_len != 8'(LINE_WORDS - 1))
                    || (mem_req_addr != victim_line_addr)
                    || (mem_req_burst != 2'b01)))
                $error("DCache writeback command shape mismatch");
            if (state_refill_req && ~wb_state_cmd
                && (mem_req_burst != 2'b10))
                $error("DCache refill burst type mismatch");
            if (state_uc_req && mem_req_writeback)
                $error("DCache uncached command was marked as writeback");
            if (refill_target_fire && wb_required
                && !writeback_complete_now && refill_cpu_ready)
                $error("DCache released dirty-miss data before B success");
            if (refill_data_fire
                && (backend_rd_last
                    != (refill_beat == WORD_W'(LINE_WORDS - 1))))
                $error("DCache eight-beat refill RLAST mismatch");
            if (wb_data_fire
                && (mem_w_last
                    != (wb_send_beat == WORD_W'(LINE_WORDS - 1))))
                $error("DCache writeback LAST mismatch");
        end
    end
`endif

endmodule

// Keep the two instances separate through synthesis.  This module contains
// only the final source select, so duplication does not replicate byte-lane
// extraction, sign extension, BRAMs, or state.
(* keep_hierarchy = "yes" *)
module dcache_read_result_select (
    input  logic        special_valid,
    input  logic [31:0] formatted_hit,
    input  logic [31:0] formatted_special,
    (* keep = "true" *) output logic [31:0] selected_data
);
    always_comb begin
        if (special_valid)
            selected_data = formatted_special;
        else
            selected_data = formatted_hit;
    end
endmodule
