// ============================================================
// Module: dcache
// Description: 2KB, 2-way set-associative, Write-Through + Write-No-Allocate
//              Data Cache with Store Buffer
//
// Architecture:
//   - Internal EX→MEM pipeline register (synced with cpu_top's ex_mem_reg)
//   - Tag: LUTRAM async read, result latched EX→MEM
//   - Data: BRAM sync read (addr in EX, data in MEM)
//   - Hit detection: MEM stage (combinational)
//   - Load miss: FSM → refill line from memory backend → S_DONE
//   - Store hit: WT to cache + store buffer → memory backend
//   - Store miss: no allocate, store buffer only
//   - Store-forward: when a store hit writes data to BRAM, the value is
//     forwarded to bypass the 1-cycle BRAM read latency
// ============================================================

module dcache (
    input  logic        clk,
    input  logic        rst_n,

    // --- EX stage inputs ---
    input  logic        cpu_req,
    input  logic        cpu_wr,
    input  logic [31:0] cpu_addr,
    input  logic [ 3:0] cpu_wea,
    input  logic [31:0] cpu_wdata,

    // --- MEM stage outputs ---
    output logic [31:0] cpu_rdata,
    output logic        cpu_ready,

    // Pipeline synchronization
    input  logic        pipeline_stall,  // from cpu_top: ~mem_allowin (keep EX→MEM reg in sync)

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

    input  logic        mem_wr_valid,
    output logic        mem_wr_ready,
    input  logic [ 1:0] mem_wr_resp
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
    localparam DATA_DEPTH = SETS * LINE_WORDS;  // 256
    localparam SB_DEPTH   = 2;

    // ================================================================
    //  EX-stage address decomposition
    // ================================================================
    wire [TAG_W-1:0]   ex_tag   = cpu_addr[17:10];
    wire [INDEX_W-1:0] ex_index = cpu_addr[9:4];
    wire [WORD_W-1:0]  ex_word  = cpu_addr[3:2];

    // ================================================================
    //  Internal EX→MEM register (synced with cpu_top's ex_mem_reg)
    // ================================================================
    logic [TAG_W-1:0]   mem_tag;
    logic [INDEX_W-1:0] mem_index;
    logic [WORD_W-1:0]  mem_word;
    logic [31:0]        mem_addr;
    logic               mem_req;
    logic               mem_wr;
    logic [ 3:0]        mem_wea;
    logic [31:0]        mem_wdata;

    // pipeline_advance must match cpu_top's mem_allowin to keep DCache's
    // internal EX→MEM register synchronized with cpu_top's ex_mem_reg.
    // NOTE: Do NOT add "| flush" — flush no longer force-kills the current
    // MEM instruction in ex_mem_reg (see fix: gate ~mem_branch_flush inside
    // mem_allowin path). Both must stall/advance together.
    wire pipeline_advance = ~pipeline_stall;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_req   <= 1'b0;
            mem_tag   <= '0;
            mem_index <= '0;
            mem_word  <= '0;
            mem_addr  <= 32'd0;
            mem_wr    <= 1'b0;
            mem_wea   <= 4'd0;
            mem_wdata <= 32'd0;
        end else if (pipeline_advance) begin
            mem_req   <= cpu_req & ~flush;
            mem_tag   <= ex_tag;
            mem_index <= ex_index;
            mem_word  <= ex_word;
            mem_addr  <= cpu_addr;
            mem_wr    <= cpu_wr;
            mem_wea   <= cpu_wea;
            mem_wdata <= cpu_wdata;
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
        S_DONE_RD,        // DCache BRAM read cycle after refill
        S_DONE,
        S_SB_DRAIN_REQ,   // issue store-buffer write request to backend
        S_SB_DRAIN_RESP   // wait for backend write response
    } state_t;

    (* fsm_encoding = "one_hot" *) state_t state;
    state_t state_nxt;
    logic [WORD_W-1:0]  rf_data_cnt;  // counts data words received (0..LINE_WORDS-1)
    wire                rf_data_valid; // current cycle has accepted backend data
    logic               rf_way;
    logic [TAG_W-1:0]   rf_tag;
    logic [INDEX_W-1:0] rf_idx;
    logic [31:0]        rf_line_addr;
    wire [INDEX_W+WORD_W-1:0] rf_wr_data_addr;
    wire                refill_wr;

    // ================================================================
    //  Tag RAM (LUTRAM, async read)
    // ================================================================
    (* ram_style = "distributed" *)
    logic [TAG_W-1:0] tag_mem [WAYS-1:0][SETS-1:0];
    logic             tag_vld [WAYS-1:0][SETS-1:0];

    // Async read with EX-stage index (no forwarding MUX needed:
    // tag is written in S_DONE_RD, pipeline_advance=0 during S_DONE_RD,
    // so by S_DONE when pipeline_advance=1, LUTRAM already has new value)
    wire [TAG_W-1:0] tag_rd_data [WAYS-1:0];
    wire             tag_rd_vld  [WAYS-1:0];
    assign tag_rd_data[0] = tag_mem[0][ex_index];
    assign tag_rd_data[1] = tag_mem[1][ex_index];
    assign tag_rd_vld[0]  = tag_vld[0][ex_index];
    assign tag_rd_vld[1]  = tag_vld[1][ex_index];

    // Latch tag read results EX→MEM
    logic [TAG_W-1:0] mem_tag_rd [WAYS-1:0];
    logic             mem_tag_vld [WAYS-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
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
    //  Note: refill forward — when S_DONE writes tag at clock edge and
    //  the next instruction's tag read is latched at the same edge,
    //  mem_tag_rd/mem_tag_vld are stale. Use rf_fwd to patch.
    // ================================================================
    logic rf_fwd_valid;
    logic rf_fwd_way;
    logic [TAG_W-1:0]   rf_fwd_tag;
    logic [INDEX_W-1:0] rf_fwd_idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_fwd_valid <= 1'b0;
            rf_fwd_way   <= 1'b0;
            rf_fwd_tag   <= '0;
            rf_fwd_idx   <= '0;
        end else begin
            if (state == S_DONE) begin
                rf_fwd_valid <= 1'b1;
                rf_fwd_way <= rf_way;
                rf_fwd_tag <= rf_tag;
                rf_fwd_idx <= rf_idx;
            end else if (pipeline_advance) begin
                rf_fwd_valid <= 1'b0;
            end
        end
    end

    // Patched tag match: apply refill forward if same set
    wire rf_fwd_match = rf_fwd_valid & (rf_fwd_idx == mem_index) & (rf_fwd_tag == mem_tag);

    wire hit_w0_raw = mem_tag_vld[0] & (mem_tag_rd[0] == mem_tag);
    wire hit_w1_raw = mem_tag_vld[1] & (mem_tag_rd[1] == mem_tag);
    wire hit_w0 = hit_w0_raw | (rf_fwd_match & ~rf_fwd_way);
    wire hit_w1 = hit_w1_raw | (rf_fwd_match &  rf_fwd_way);
    wire cache_hit = hit_w0 | hit_w1;
    wire hit_way = hit_w1;

    // ================================================================
    //  Data RAM — BRAM IP instances (one per way)
    // ================================================================
    logic [31:0] data_rd [WAYS-1:0];
    wire [INDEX_W+WORD_W-1:0] data_rd_addr = {ex_index, ex_word};

    // BRAM read address MUX: normal path (EX addr) or refill-done path
    wire bram_rd_for_refill = (state == S_DONE_RD);
    wire [INDEX_W+WORD_W-1:0] bram_rd_addr = bram_rd_for_refill
                                            ? {rf_idx, mem_word}
                                            : data_rd_addr;

    // BRAM write port signals (unified MUX, defined later)
    wire  [ 3:0] bram_wea  [WAYS-1:0];
    wire  [INDEX_W+WORD_W-1:0] bram_waddr [WAYS-1:0];
    wire  [31:0] bram_wdata [WAYS-1:0];

    // BRAM read port enable: read on pipeline advance or refill-done
    wire bram_rd_en = pipeline_advance | bram_rd_for_refill;

    // Gate BRAM read address: hold previous address during stalls
    // This prevents BRAM from outputting wrong data during pipeline stalls
    logic [INDEX_W+WORD_W-1:0] bram_rd_addr_r;
    always_ff @(posedge clk) begin
        if (bram_rd_en)
            bram_rd_addr_r <= bram_rd_addr;
    end
    wire [INDEX_W+WORD_W-1:0] bram_rd_addr_gated = bram_rd_en ? bram_rd_addr : bram_rd_addr_r;

    // Raw BRAM output — directly used as data_rd
    // BRAM has inherent 1-cycle read latency, matching original FF behavior

    dcache_data_ram u_data_way0 (
        .clka  (clk),
        .wea   (bram_wea[0]),
        .addra (bram_waddr[0]),
        .dina  (bram_wdata[0]),
        .clkb  (clk),
        .addrb (bram_rd_addr_gated),
        .doutb (data_rd[0])
    );

    dcache_data_ram u_data_way1 (
        .clka  (clk),
        .wea   (bram_wea[1]),
        .addra (bram_waddr[1]),
        .dina  (bram_wdata[1]),
        .clkb  (clk),
        .addrb (bram_rd_addr_gated),
        .doutb (data_rd[1])
    );

    // Refill-last-word forwarding: when S_DONE_RD reads the same word
    // that was just written by the last refill write, BRAM gives stale data.
    // Capture the last refill write for forwarding.
    logic        rf_last_fwd_valid;
    logic        rf_last_fwd_way;
    logic [INDEX_W+WORD_W-1:0] rf_last_fwd_addr;
    logic [31:0] rf_last_fwd_data;
    wire  [31:0] refill_write_data;

    // Capture the pending store-buffer entry once when a refill starts.
    // The line compare is resolved up front; each refill beat then only
    // needs a narrow word check and byte selection.
    logic                 rf_merge_valid [SB_DEPTH-1:0];
    logic [1:0]           rf_merge_word  [SB_DEPTH-1:0];
    logic [ 3:0]          rf_merge_wea   [SB_DEPTH-1:0];
    logic [31:0]          rf_merge_data  [SB_DEPTH-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_last_fwd_valid <= 1'b0;
            rf_last_fwd_way   <= 1'b0;
            rf_last_fwd_addr  <= '0;
            rf_last_fwd_data  <= 32'd0;
        end else begin
            if (refill_wr) begin
                rf_last_fwd_valid <= 1'b1;
                rf_last_fwd_way  <= rf_way;
                rf_last_fwd_addr <= rf_wr_data_addr;
                rf_last_fwd_data <= refill_write_data;
            end else if (state == S_DONE) begin
                rf_last_fwd_valid <= 1'b0;
            end
        end
    end

    // ================================================================
    //  Store forwarding register
    //  When a store writes to data_mem at clock edge, and a load reads
    //  from the same addr at the same edge, the BRAM read gets stale data.
    //  This register captures the store and is checked on the next cycle.
    // ================================================================
    logic        st_fwd_valid;
    logic        st_fwd_way;
    logic [INDEX_W+WORD_W-1:0] st_fwd_addr;
    logic [31:0] st_fwd_data;
    logic [ 3:0] st_fwd_wea;

    // Detect if current BRAM read result needs forwarding
    wire fwd_match_w0 = st_fwd_valid & ~st_fwd_way & (data_rd_addr == st_fwd_addr);
    wire fwd_match_w1 = st_fwd_valid &  st_fwd_way & (data_rd_addr == st_fwd_addr);

    // Note: data_rd_addr is latched (EX→MEM), so we need to compare with MEM-stage addr
    // Actually, data_rd_addr uses ex_index/ex_word which were registered into data_rd
    // So the match should use the MEM-stage version:
    wire [INDEX_W+WORD_W-1:0] mem_data_addr = {mem_index, mem_word};
    wire fwd_hit_w0 = st_fwd_valid & ~st_fwd_way & (mem_data_addr == st_fwd_addr);
    wire fwd_hit_w1 = st_fwd_valid &  st_fwd_way & (mem_data_addr == st_fwd_addr);

    // Apply byte-level forwarding to produce corrected data (AND-OR, no always_comb)
    wire [31:0] data_rd_fwd [WAYS-1:0];

    // Way 0: per-byte MUX — forward if fwd_hit_w0 && wea bit set, else keep BRAM data
    assign data_rd_fwd[0][ 7: 0] = (fwd_hit_w0 & st_fwd_wea[0]) ? st_fwd_data[ 7: 0] : data_rd[0][ 7: 0];
    assign data_rd_fwd[0][15: 8] = (fwd_hit_w0 & st_fwd_wea[1]) ? st_fwd_data[15: 8] : data_rd[0][15: 8];
    assign data_rd_fwd[0][23:16] = (fwd_hit_w0 & st_fwd_wea[2]) ? st_fwd_data[23:16] : data_rd[0][23:16];
    assign data_rd_fwd[0][31:24] = (fwd_hit_w0 & st_fwd_wea[3]) ? st_fwd_data[31:24] : data_rd[0][31:24];

    // Way 1: same structure
    assign data_rd_fwd[1][ 7: 0] = (fwd_hit_w1 & st_fwd_wea[0]) ? st_fwd_data[ 7: 0] : data_rd[1][ 7: 0];
    assign data_rd_fwd[1][15: 8] = (fwd_hit_w1 & st_fwd_wea[1]) ? st_fwd_data[15: 8] : data_rd[1][15: 8];
    assign data_rd_fwd[1][23:16] = (fwd_hit_w1 & st_fwd_wea[2]) ? st_fwd_data[23:16] : data_rd[1][23:16];
    assign data_rd_fwd[1][31:24] = (fwd_hit_w1 & st_fwd_wea[3]) ? st_fwd_data[31:24] : data_rd[1][31:24];

    // ================================================================
    //  LRU (1-bit per set)
    // ================================================================
    logic [SETS-1:0] lru;
    wire lru_victim = lru[mem_index];

    // ================================================================
    //  Store Buffer (2 entries)
    // ================================================================
    logic [SB_DEPTH-1:0] sb_valid_q;
    logic [31:0]         sb_addr_q [SB_DEPTH-1:0];
    logic [ 3:0]         sb_wea_q  [SB_DEPTH-1:0];
    logic [31:0]         sb_data_q [SB_DEPTH-1:0];

    logic [SB_DEPTH-1:0] sb_valid_n;
    logic [31:0]         sb_addr_n [SB_DEPTH-1:0];
    logic [ 3:0]         sb_wea_n  [SB_DEPTH-1:0];
    logic [31:0]         sb_data_n [SB_DEPTH-1:0];

    wire        sb_valid = |sb_valid_q;
    wire        sb_full  = &sb_valid_q;
    wire [31:0] sb_addr  = sb_addr_q[0];
    wire [ 3:0] sb_wea   = sb_wea_q[0];
    wire [31:0] sb_data  = sb_data_q[0];
    wire        sb_resp_fire;
    wire        sb_store_enqueue;
    wire        sb_pop   = sb_resp_fire;
    wire        sb_push  = sb_store_enqueue;
    wire [31:0] sb_push_addr = {mem_addr[31:2], 2'b00};

    // Parallel FIFO candidates. Payload may update under an invalid slot; the
    // valid bits are the architectural guard.
    wire sb_push_slot0 = sb_push & (~sb_valid_q[0] | (sb_pop & ~sb_valid_q[1]));
    wire sb_push_slot1 = sb_push & ((sb_valid_q[0] & ~sb_pop) | (sb_pop & sb_valid_q[1]));
    wire sb_after_pop_valid0 = sb_pop ? sb_valid_q[1] : sb_valid_q[0];
    wire sb_after_pop_valid1 = sb_pop ? 1'b0 : sb_valid_q[1];
    wire [31:0] sb_after_pop_addr0 = sb_pop ? sb_addr_q[1] : sb_addr_q[0];
    wire [31:0] sb_after_pop_addr1 = sb_pop ? 32'd0 : sb_addr_q[1];
    wire [ 3:0] sb_after_pop_wea0  = sb_pop ? sb_wea_q[1] : sb_wea_q[0];
    wire [ 3:0] sb_after_pop_wea1  = sb_pop ? 4'd0 : sb_wea_q[1];
    wire [31:0] sb_after_pop_data0  = sb_pop ? sb_data_q[1] : sb_data_q[0];
    wire [31:0] sb_after_pop_data1  = sb_pop ? 32'd0 : sb_data_q[1];

    assign sb_valid_n[0] = sb_push_slot0 | sb_after_pop_valid0;
    assign sb_valid_n[1] = sb_push_slot1 | sb_after_pop_valid1;

    assign sb_addr_n[0] = sb_push_slot0 ? sb_push_addr : sb_after_pop_addr0;
    assign sb_addr_n[1] = sb_push_slot1 ? sb_push_addr : sb_after_pop_addr1;

    assign sb_wea_n[0] = sb_push_slot0 ? mem_wea : sb_after_pop_wea0;
    assign sb_wea_n[1] = sb_push_slot1 ? mem_wea : sb_after_pop_wea1;

    assign sb_data_n[0] = sb_push_slot0 ? mem_wdata : sb_after_pop_data0;
    assign sb_data_n[1] = sb_push_slot1 ? mem_wdata : sb_after_pop_data1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int e = 0; e < SB_DEPTH; e++) begin
                rf_merge_valid[e] <= 1'b0;
                rf_merge_word[e]  <= '0;
                rf_merge_wea[e]   <= 4'd0;
                rf_merge_data[e]  <= 32'd0;
            end
        end else if (state == S_IDLE && state_nxt == S_REFILL_REQ) begin
            for (int e = 0; e < SB_DEPTH; e++) begin
                rf_merge_valid[e] <= sb_valid_q[e] & (sb_addr_q[e][31:4] == mem_addr[31:4]);
                rf_merge_word[e]  <= sb_addr_q[e][3:2];
                rf_merge_wea[e]   <= sb_wea_q[e];
                rf_merge_data[e]  <= sb_data_q[e];
            end
        end
    end

    // If a load miss refills a line while a store-buffer entry for the same
    // line is still pending, merge the pending store bytes into the cache line.
    // Entry 0 is older; entry 1 is younger and wins for overlapping bytes.
    wire refill_sb0_same_word = rf_merge_valid[0] & (rf_merge_word[0] == rf_data_cnt);
    wire refill_sb1_same_word = rf_merge_valid[1] & (rf_merge_word[1] == rf_data_cnt);
    wire [31:0] refill_sb0_data;
    wire [31:0] refill_sb1_data;

    assign refill_sb0_data[ 7: 0] = (refill_sb0_same_word & rf_merge_wea[0][0]) ? rf_merge_data[0][ 7: 0] : mem_rd_data[ 7: 0];
    assign refill_sb0_data[15: 8] = (refill_sb0_same_word & rf_merge_wea[0][1]) ? rf_merge_data[0][15: 8] : mem_rd_data[15: 8];
    assign refill_sb0_data[23:16] = (refill_sb0_same_word & rf_merge_wea[0][2]) ? rf_merge_data[0][23:16] : mem_rd_data[23:16];
    assign refill_sb0_data[31:24] = (refill_sb0_same_word & rf_merge_wea[0][3]) ? rf_merge_data[0][31:24] : mem_rd_data[31:24];

    assign refill_sb1_data[ 7: 0] = (refill_sb1_same_word & rf_merge_wea[1][0]) ? rf_merge_data[1][ 7: 0] : mem_rd_data[ 7: 0];
    assign refill_sb1_data[15: 8] = (refill_sb1_same_word & rf_merge_wea[1][1]) ? rf_merge_data[1][15: 8] : mem_rd_data[15: 8];
    assign refill_sb1_data[23:16] = (refill_sb1_same_word & rf_merge_wea[1][2]) ? rf_merge_data[1][23:16] : mem_rd_data[23:16];
    assign refill_sb1_data[31:24] = (refill_sb1_same_word & rf_merge_wea[1][3]) ? rf_merge_data[1][31:24] : mem_rd_data[31:24];

    assign refill_write_data = refill_sb1_same_word ? refill_sb1_data :
                               refill_sb0_same_word ? refill_sb0_data :
                                                       mem_rd_data;

    // ================================================================
    //  FSM — variable-latency refill/store backend
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= state_nxt;
    end

    // MEM-stage control signals
    wire state_idle = (state == S_IDLE);
    wire state_done = (state == S_DONE);

    wire idle_load_miss  = mem_req & ~mem_wr & ~cache_hit & state_idle;
    wire idle_store_miss = mem_req &  mem_wr & ~cache_hit & state_idle;
    wire idle_store_hit  = mem_req &  mem_wr &  cache_hit & state_idle;
    wire idle_store      = mem_req &  mem_wr & state_idle;
    wire sb_conflict     = idle_store & sb_full;
    wire store_hit_accept  = idle_store_hit & ~sb_full;
    wire store_miss_accept = idle_store_miss & ~sb_full;
    assign sb_store_enqueue = store_hit_accept | store_miss_accept;


    wire refill_req_fire = (state == S_REFILL_REQ) & mem_req_ready;
    wire refill_data_last = rf_data_valid & (rf_data_cnt == WORD_W'(LINE_WORDS - 1));
    wire refill_drop_done = (state == S_REFILL_DROP) & mem_rd_valid & mem_rd_ready & mem_rd_last;
    wire sb_req_fire = (state == S_SB_DRAIN_REQ) & mem_req_ready;
    assign sb_resp_fire = (state == S_SB_DRAIN_RESP) & mem_wr_valid & mem_wr_ready;

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE: begin
                if (sb_conflict)
                    state_nxt = S_SB_DRAIN_REQ;
                else if (idle_load_miss)
                    state_nxt = S_REFILL_REQ;
                else if (sb_valid & ~sb_store_enqueue)
                    // Background drain. Load misses are allowed to refill
                    // before drain; same-line SB data is merged into refill.
                    state_nxt = S_SB_DRAIN_REQ;
            end

            S_REFILL_REQ: begin
                if (refill_req_fire)
                    state_nxt = flush ? S_REFILL_DROP : S_REFILL_DATA;
                else if (flush)
                    state_nxt = S_IDLE;
            end

            S_REFILL_DATA: begin
                if (flush)
                    state_nxt = S_REFILL_DROP;
                else if (refill_data_last)
                    state_nxt = S_DONE_RD;
            end

            S_REFILL_DROP: begin
                if (refill_drop_done)
                    state_nxt = S_IDLE;
            end

            S_DONE_RD:
                state_nxt = flush ? S_IDLE : S_DONE;
            S_DONE:
                state_nxt = S_IDLE;
            S_SB_DRAIN_REQ: begin
                if (sb_req_fire)
                    state_nxt = S_SB_DRAIN_RESP;
            end
            S_SB_DRAIN_RESP: begin
                if (sb_resp_fire)
                    state_nxt = S_IDLE;
            end
            default:
                state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_data_cnt <= '0;
            rf_way      <= 1'b0;
            rf_tag      <= '0;
            rf_idx      <= '0;
            rf_line_addr <= 32'd0;
        end else begin
            if (state == S_IDLE && state_nxt == S_REFILL_REQ) begin
                rf_data_cnt  <= '0;
                rf_way       <= lru_victim;
                rf_tag       <= mem_tag;
                rf_idx       <= mem_index;
                rf_line_addr <= {mem_addr[31:4], 4'b0000};
            end else if (state == S_REFILL_DATA && rf_data_valid) begin
                rf_data_cnt <= rf_data_cnt + 1'b1;
            end
        end
    end

    assign rf_data_valid = (state == S_REFILL_DATA) & mem_rd_valid & mem_rd_ready;

    // ================================================================
    //  Data RAM write — unified write port MUX for BRAM IP
    //  Refill and store are mutually exclusive, so they share Port A.
    // ================================================================
    assign rf_wr_data_addr = {rf_idx, rf_data_cnt};
    wire [INDEX_W+WORD_W-1:0] st_data_addr    = {mem_index, mem_word};

    // Track whether a store hit is writing cache this cycle (for forwarding).
    // Store misses are write-no-allocate: they only enqueue the store buffer.
    wire        doing_store = store_hit_accept;
    wire        doing_store_way = hit_way;
    wire [INDEX_W+WORD_W-1:0] doing_store_addr = st_data_addr;
    wire [31:0] doing_store_data = mem_wdata;
    wire [ 3:0] doing_store_wea = mem_wea;

    // Refill write: one cache data RAM write per accepted backend read beat.
    assign refill_wr = rf_data_valid;

    // Unified BRAM write port MUX per way (unrolled, no for-loop w[0])
    // Priority: refill > store (they are mutually exclusive by FSM design)

    // Way 0
    wire refill_w0 = refill_wr & ~rf_way;
    wire store_w0  = doing_store & ~doing_store_way;
    assign bram_wea[0]   = refill_w0 ? 4'b1111          : store_w0 ? doing_store_wea  : 4'b0000;
    assign bram_waddr[0] = refill_w0 ? rf_wr_data_addr   : store_w0 ? doing_store_addr : '0;
    assign bram_wdata[0] = refill_w0 ? refill_write_data  : store_w0 ? doing_store_data : 32'd0;

    // Way 1
    wire refill_w1 = refill_wr &  rf_way;
    wire store_w1  = doing_store &  doing_store_way;
    assign bram_wea[1]   = refill_w1 ? 4'b1111          : store_w1 ? doing_store_wea  : 4'b0000;
    assign bram_waddr[1] = refill_w1 ? rf_wr_data_addr   : store_w1 ? doing_store_addr : '0;
    assign bram_wdata[1] = refill_w1 ? refill_write_data  : store_w1 ? doing_store_data : 32'd0;

    // Store forward register: capture store info at clock edge
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_fwd_valid <= 1'b0;
            st_fwd_way   <= 1'b0;
            st_fwd_addr  <= '0;
            st_fwd_data  <= 32'd0;
            st_fwd_wea   <= 4'd0;
        end else begin
            st_fwd_valid <= doing_store;
            st_fwd_way  <= doing_store_way;
            st_fwd_addr <= doing_store_addr;
            st_fwd_data <= doing_store_data;
            st_fwd_wea  <= doing_store_wea;
        end
    end

    // ================================================================
    //  Tag RAM write
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int w = 0; w < WAYS; w++)
                for (int s = 0; s < SETS; s++) begin
                    tag_vld[w][s] <= 1'b0;
                    tag_mem[w][s] <= '0;
                end
        end else begin
            // Invalidate victim at refill START so a mid-refill flush
            // leaves no valid-but-corrupted line (BRAM partially overwritten).
            if (state == S_IDLE && state_nxt == S_REFILL_REQ)
                tag_vld[lru_victim][mem_index] <= 1'b0;
            // Validate and write tag in S_DONE_RD (one cycle before S_DONE).
            // By S_DONE, LUTRAM has the new value, so pipeline_advance can
            // latch correct tag without forwarding MUX.
            if (state == S_DONE_RD) begin
                tag_vld[rf_way][rf_idx] <= 1'b1;
                tag_mem[rf_way][rf_idx] <= rf_tag;
            end
        end
    end

    // ================================================================
    //  LRU update
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lru <= '0;
        else begin
            if (state == S_IDLE && mem_req && cache_hit)
                lru[mem_index] <= ~hit_way;
            if (state == S_DONE)
                lru[rf_idx] <= ~rf_way;
        end
    end

    // ================================================================
    //  Store Buffer
    // ================================================================
    // Drain SB to memory backend when S_SB_DRAIN_REQ/RESP or when IDLE.
    // Enqueue on accepted store hit or store miss. Store miss is WNA and does
    // not allocate/update the cache line.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sb_valid_q <= '0;
            for (int e = 0; e < SB_DEPTH; e++) begin
                sb_addr_q[e] <= 32'd0;
                sb_wea_q[e]  <= 4'd0;
                sb_data_q[e] <= 32'd0;
            end
        end else begin
            sb_valid_q <= sb_valid_n;
            for (int e = 0; e < SB_DEPTH; e++) begin
                sb_addr_q[e] <= sb_addr_n[e];
                sb_wea_q[e]  <= sb_wea_n[e];
                sb_data_q[e] <= sb_data_n[e];
            end
        end
    end

    // ================================================================
    //  External memory backend request/response
    // ================================================================
    assign mem_req_valid = (state == S_REFILL_REQ) | (state == S_SB_DRAIN_REQ);
    assign mem_req_write = (state == S_SB_DRAIN_REQ);
    assign mem_req_addr  = mem_req_write ? sb_addr : rf_line_addr;
    assign mem_req_len   = mem_req_write ? 8'd0 : 8'(LINE_WORDS - 1);
    assign mem_req_wdata = sb_data;
    assign mem_req_wstrb = sb_wea;

    assign mem_rd_ready  = (state == S_REFILL_DATA) | (state == S_REFILL_DROP);
    assign mem_wr_ready  = (state == S_SB_DRAIN_RESP);

    // ================================================================
    //  CPU read data MUX (MEM stage)
    //  Priority: refill-last-word forward > store forward > BRAM read
    // ================================================================
    // S_DONE path: BRAM was read during S_DONE_RD, data_rd has the result.
    // But if the read word matches the last refill write, need forwarding.
    logic [31:0] done_rdata;
    always_comb begin
        done_rdata = data_rd[rf_way];
        // Forward last refill word if it conflicts with BRAM read
        if (rf_last_fwd_valid && rf_last_fwd_way == rf_way &&
            rf_last_fwd_addr == {rf_idx, mem_word})
            done_rdata = rf_last_fwd_data;
    end

    always_comb begin
        if (state == S_DONE && ~mem_wr)
            cpu_rdata = done_rdata;
        else
            cpu_rdata = hit_way ? data_rd_fwd[1] : data_rd_fwd[0];
    end

    // ================================================================
    //  CPU ready
    // ================================================================
    assign cpu_ready = ~mem_req
                     | state_done
                     | store_miss_accept
                     | (state_idle & cache_hit & ~sb_conflict);

    // ================================================================
    //  Background SB drain: when idle, SB valid, and no higher-priority
    //  load-miss refill or store-hit conflict → S_SB_DRAIN_REQ
    //  Already handled in FSM next-state logic above.
    // ================================================================

endmodule
