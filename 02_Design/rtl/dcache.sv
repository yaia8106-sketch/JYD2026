// ============================================================
// Module: dcache
// Description: 2KB, 2-way set-associative, Write-Through + Write-Allocate
//              Data Cache with Store Buffer
//
// Architecture:
//   - Internal EX→MEM pipeline register (synced with cpu_top's ex_mem_reg)
//   - Tag: LUTRAM async read, result latched EX→MEM
//   - Data: BRAM sync read (addr in EX, data in MEM)
//   - Hit detection: MEM stage (combinational)
//   - Miss: FSM → refill line from DRAM → S_DONE
//   - Store: WT to cache + store buffer → DRAM
//   - Store-forward: when S_DONE writes store data to BRAM,
//     the value is forwarded to bypass the 1-cycle BRAM read latency
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

    // DRAM BRAM interface (SDP)
    output logic [15:0] dram_rd_addr,
    input  logic [31:0] dram_rdata,      // raw DRAM output (registered internally as dram_rdata_r)
    output logic [15:0] dram_wr_addr,
    output logic [ 3:0] dram_wea,
    output logic [31:0] dram_wdata
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
            mem_wr    <= 1'b0;
            mem_wea   <= 4'd0;
            mem_wdata <= 32'd0;
        end else if (pipeline_advance) begin
            mem_req   <= cpu_req & ~flush;
            mem_tag   <= ex_tag;
            mem_index <= ex_index;
            mem_word  <= ex_word;
            mem_wr    <= cpu_wr;
            mem_wea   <= cpu_wea;
            mem_wdata <= cpu_wdata;
        end
    end

    wire [15:0] mem_word_addr = {mem_tag, mem_index, mem_word};

    // ================================================================
    //  FSM types & signals (declared early for iverilog compatibility)
    // ================================================================
    localparam DRAM_LATENCY = 4;  // registered addr(1) + BRAM read(1) + DOB_REG(1) + dram_rdata_r(1)

    typedef enum logic [2:0] {
        S_IDLE,
        S_REFILL_BURST,   // sending addresses (may also receive data)
        S_REFILL_DRAIN,   // receiving remaining data after all addrs sent
        S_DONE_RD,        // DCache BRAM read cycle after refill
        S_DONE,
        S_SB_DRAIN
    } state_t;

    state_t state, state_nxt;
    logic [WORD_W-1:0]  rf_addr_cnt;  // counts addresses sent (0..LINE_WORDS-1)
    logic [WORD_W-1:0]  rf_data_cnt;  // counts data words received (0..LINE_WORDS-1)
    logic               rf_addr_done; // all addresses sent
    wire                rf_data_valid; // current cycle has valid DRAM data
    logic               rf_way;
    logic [TAG_W-1:0]   rf_tag;
    logic [INDEX_W-1:0] rf_idx;
    logic [3:0]         rf_burst_cycle;
    wire [INDEX_W+WORD_W-1:0] rf_wr_data_addr;
    wire                refill_wr;

    // ================================================================
    //  DRAM read-data pipeline register (breaks DRAM output MUX → DCache BRAM path)
    // ================================================================
    logic [31:0] dram_rdata_r;
    always_ff @(posedge clk) begin
        dram_rdata_r <= dram_rdata;
    end

    // ================================================================
    //  Tag RAM (LUTRAM, async read)
    // ================================================================
    (* ram_style = "distributed" *)
    logic [TAG_W-1:0] tag_mem [WAYS-1:0][SETS-1:0];
    logic             tag_vld [WAYS-1:0][SETS-1:0];

    // Async read with EX-stage index
    wire [TAG_W-1:0] tag_rd_data [WAYS-1:0];
    wire             tag_rd_vld  [WAYS-1:0];
    wire [TAG_W-1:0] tag_rd_data_fwd0 = (state == S_DONE && rf_way == 0 && rf_idx == ex_index) ? rf_tag : tag_mem[0][ex_index];
    wire [TAG_W-1:0] tag_rd_data_fwd1 = (state == S_DONE && rf_way == 1 && rf_idx == ex_index) ? rf_tag : tag_mem[1][ex_index];
    wire             tag_rd_vld_fwd0  = (state == S_DONE && rf_way == 0 && rf_idx == ex_index) ? 1'b1   : tag_vld[0][ex_index];
    wire             tag_rd_vld_fwd1  = (state == S_DONE && rf_way == 1 && rf_idx == ex_index) ? 1'b1   : tag_vld[1][ex_index];

    // Latch tag read results EX→MEM
    logic [TAG_W-1:0] mem_tag_rd [WAYS-1:0];
    logic             mem_tag_vld [WAYS-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_tag_rd[0]  <= '0;  mem_tag_vld[0] <= 1'b0;
            mem_tag_rd[1]  <= '0;  mem_tag_vld[1] <= 1'b0;
        end else if (pipeline_advance) begin
            mem_tag_rd[0]  <= tag_rd_data_fwd0;
            mem_tag_vld[0] <= tag_rd_vld_fwd0;
            mem_tag_rd[1]  <= tag_rd_data_fwd1;
            mem_tag_vld[1] <= tag_rd_vld_fwd1;
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
                rf_last_fwd_data <= dram_rdata_r;
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
    //  Store Buffer (1 entry)
    // ================================================================
    logic        sb_valid;
    logic [15:0] sb_addr;
    logic [ 3:0] sb_wea;
    logic [31:0] sb_data;

    // ================================================================
    //  FSM — Pipelined refill for DRAM with output register
    //  DRAM has 2-cycle read latency (1 BRAM + 1 output register).
    //  Refill sends addresses in consecutive cycles (burst), and
    //  receives data starting 2 cycles later.
    //
    //  Timeline (4 words, DRAM_LATENCY = 4 with dram_rdata_r):
    //    Cycle 0: S_REFILL_BURST  send addr[0]
    //    Cycle 1: S_REFILL_BURST  send addr[1]
    //    Cycle 2: S_REFILL_BURST  send addr[2]
    //    Cycle 3: S_REFILL_BURST  send addr[3],              dram_rdata_r=data[0] → write
    //    Cycle 4: S_REFILL_DRAIN               dram_rdata_r=data[1] → write
    //    Cycle 5: S_REFILL_DRAIN               dram_rdata_r=data[2] → write
    //    Cycle 6: S_REFILL_DRAIN               dram_rdata_r=data[3] → write
    //    Cycle 7: S_DONE_RD       DCache BRAM read for hit word
    //    Cycle 8: S_DONE          output data, update tag, signal ready
    //  Total: LINE_WORDS + DRAM_LATENCY + 1 = 9 cycles
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else if (flush && (state != S_IDLE && state != S_SB_DRAIN))
            state <= S_IDLE;
        else
            state <= state_nxt;
    end

    // MEM-stage control signals
    wire idle_miss      = mem_req & ~cache_hit & (state == S_IDLE);
    wire idle_store_hit = mem_req & cache_hit & mem_wr & (state == S_IDLE);
    wire idle_load_hit  = mem_req & cache_hit & ~mem_wr & (state == S_IDLE);
    wire sb_conflict    = idle_store_hit & sb_valid;


    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE: begin
                if (sb_conflict)
                    state_nxt = S_SB_DRAIN;
                else if (sb_valid)
                    // MUST drain SB before any refill — otherwise refill
                    // reads stale DRAM data (SB hasn't written back yet).
                    // After drain, FSM returns to IDLE and re-evaluates
                    // the miss, starting the refill with up-to-date DRAM.
                    state_nxt = S_SB_DRAIN;
                else if (idle_miss)
                    state_nxt = S_REFILL_BURST;
            end
            S_REFILL_BURST: begin
                if (rf_addr_done)
                    state_nxt = S_REFILL_DRAIN;  // all addrs sent, wait for remaining data
            end
            S_REFILL_DRAIN: begin
                if (rf_data_valid && rf_data_cnt == WORD_W'(LINE_WORDS - 1))
                    state_nxt = S_DONE_RD;
            end
            S_DONE_RD:
                state_nxt = S_DONE;
            S_DONE:
                state_nxt = S_IDLE;
            S_SB_DRAIN:
                state_nxt = S_IDLE;
            default:
                state_nxt = S_IDLE;
        endcase
    end

    // Refill control — simple cycle-based approach
    //
    // Timeline for DRAM_LATENCY=2, LINE_WORDS=4 (dram_rd_addr is REGISTERED):
    //   burst_cycle=0: dram_rd_addr_r<=addr[0] (registered from IDLE transition)
    //   burst_cycle=1: dram_rd_addr_r<=addr[1], DRAM sees addr[0]
    //   burst_cycle=2: dram_rd_addr_r<=addr[2], DRAM sees addr[1], dram_rdata=data[0] → write
    //   burst_cycle=3: dram_rd_addr_r<=addr[3], DRAM sees addr[2], dram_rdata=data[1] → write
    //   burst_cycle=4: (DRAIN)                  DRAM sees addr[3], dram_rdata=data[2] → write
    //   burst_cycle=5: (DRAIN)                                     dram_rdata=data[3] → write
    //
    // rf_burst_cycle declared early (iverilog compat)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rf_addr_cnt    <= '0;
            rf_data_cnt    <= '0;
            rf_addr_done   <= 1'b0;
            rf_way         <= 1'b0;
            rf_tag         <= '0;
            rf_idx         <= '0;
            rf_burst_cycle <= '0;
        end else if (state == S_IDLE && state_nxt == S_REFILL_BURST) begin
            // Start refill — addr[0] will be registered this cycle edge
            rf_addr_cnt    <= WORD_W'(1);  // addr[0] being registered now
            rf_data_cnt    <= '0;
            rf_addr_done   <= (LINE_WORDS == 1);
            rf_way         <= lru_victim;
            rf_tag         <= mem_tag;
            rf_idx         <= mem_index;
            rf_burst_cycle <= 4'd1;  // cycle 0 is "now", next is cycle 1
        end else if (state == S_REFILL_BURST || state == S_REFILL_DRAIN) begin
            rf_burst_cycle <= rf_burst_cycle + 1'b1;
            // Send next address (during BURST only)
            if (state == S_REFILL_BURST && !rf_addr_done) begin
                rf_addr_cnt  <= rf_addr_cnt + 1'b1;
                rf_addr_done <= (rf_addr_cnt == WORD_W'(LINE_WORDS - 1));
            end
            // Count received data
            if (rf_data_valid)
                rf_data_cnt <= rf_data_cnt + 1'b1;
        end
    end

    // Data valid: DRAM data is available after address pipeline latency
    // dram_rd_addr registered(+1) + BRAM read(+1) + DOB_REG(+1) + dram_rdata_r(+1) = 4 cycles
    // Total latency = 4 cycles from address computation to registered data = DRAM_LATENCY
    // Note: cannot use WORD_W'(LINE_WORDS) since 2'd4 truncates to 0!
    assign rf_data_valid = (rf_burst_cycle >= 4'(DRAM_LATENCY)) &
                           (state == S_REFILL_BURST | state == S_REFILL_DRAIN);

    // ================================================================
    //  Data RAM write — unified write port MUX for BRAM IP
    //  Refill and store are mutually exclusive, so they share Port A.
    // ================================================================
    assign rf_wr_data_addr = {rf_idx, rf_data_cnt};
    wire [INDEX_W+WORD_W-1:0] st_data_addr    = {mem_index, mem_word};

    // Track whether a store is being written this cycle (for forwarding)
    logic        doing_store;
    logic        doing_store_way;
    logic [INDEX_W+WORD_W-1:0] doing_store_addr;
    logic [31:0] doing_store_data;
    logic [ 3:0] doing_store_wea;

    always_comb begin
        doing_store = 1'b0;
        doing_store_way = 1'b0;
        doing_store_addr = '0;
        doing_store_data = 32'd0;
        doing_store_wea = 4'd0;

        if (idle_store_hit & ~sb_conflict) begin
            doing_store = 1'b1;
            doing_store_way = hit_way;
            doing_store_addr = st_data_addr;
            doing_store_data = mem_wdata;
            doing_store_wea = mem_wea;
        end
        if (state == S_DONE && mem_req && mem_wr) begin
            doing_store = 1'b1;
            doing_store_way = rf_way;
            doing_store_addr = st_data_addr;
            doing_store_data = mem_wdata;
            doing_store_wea = mem_wea;
        end
    end

    // Refill write: when DRAM data is valid during burst/drain
    assign refill_wr = rf_data_valid & (state == S_REFILL_BURST || state == S_REFILL_DRAIN);

    // Unified BRAM write port MUX per way (unrolled, no for-loop w[0])
    // Priority: refill > store (they are mutually exclusive by FSM design)

    // Way 0
    wire refill_w0 = refill_wr & ~rf_way;
    wire store_w0  = doing_store & ~doing_store_way;
    assign bram_wea[0]   = refill_w0 ? 4'b1111          : store_w0 ? doing_store_wea  : 4'b0000;
    assign bram_waddr[0] = refill_w0 ? rf_wr_data_addr   : store_w0 ? doing_store_addr : '0;
    assign bram_wdata[0] = refill_w0 ? dram_rdata_r       : store_w0 ? doing_store_data : 32'd0;

    // Way 1
    wire refill_w1 = refill_wr &  rf_way;
    wire store_w1  = doing_store &  doing_store_way;
    assign bram_wea[1]   = refill_w1 ? 4'b1111          : store_w1 ? doing_store_wea  : 4'b0000;
    assign bram_waddr[1] = refill_w1 ? rf_wr_data_addr   : store_w1 ? doing_store_addr : '0;
    assign bram_wdata[1] = refill_w1 ? dram_rdata_r       : store_w1 ? doing_store_data : 32'd0;

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
            if (doing_store) begin
                st_fwd_way  <= doing_store_way;
                st_fwd_addr <= doing_store_addr;
                st_fwd_data <= doing_store_data;
                st_fwd_wea  <= doing_store_wea;
            end
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
            if (state == S_IDLE && state_nxt == S_REFILL_BURST)
                tag_vld[lru_victim][mem_index] <= 1'b0;
            // Validate and write tag only on successful refill completion
            if (state == S_DONE) begin
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
    // Drain SB to DRAM when S_SB_DRAIN or when IDLE and no miss
    // Enqueue on store hit or store-miss-done
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sb_valid <= 1'b0;
            sb_addr  <= '0;
            sb_wea   <= 4'd0;
            sb_data  <= 32'd0;
        end else begin
            // Drain takes priority (clear valid)
            if (state == S_SB_DRAIN)
                sb_valid <= 1'b0;
            // Enqueue store (after drain priority, so enqueue wins if same cycle)
            if (doing_store) begin
                sb_valid <= 1'b1;
                sb_addr  <= mem_word_addr;
                sb_wea   <= doing_store_wea;
                sb_data  <= doing_store_data;
            end
        end
    end

    // ================================================================
    //  DRAM read address (REGISTERED for timing — breaks long routing to DRAM BRAMs)
    // ================================================================
    logic [15:0] dram_rd_addr_nxt;
    always_comb begin
        dram_rd_addr_nxt = 16'd0;
        if (state == S_IDLE && state_nxt == S_REFILL_BURST)
            // First address: registered during IDLE→BURST transition
            dram_rd_addr_nxt = {mem_tag, mem_index, {WORD_W{1'b0}}};
        else if (state == S_REFILL_BURST && !rf_addr_done)
            // Subsequent addresses: burst
            dram_rd_addr_nxt = {rf_tag, rf_idx, rf_addr_cnt};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dram_rd_addr <= 16'd0;
        else
            dram_rd_addr <= dram_rd_addr_nxt;
    end

    // ================================================================
    //  DRAM write port (SB drain)
    // ================================================================
    always_comb begin
        if (state == S_SB_DRAIN) begin
            dram_wr_addr = sb_addr;
            dram_wea     = sb_wea;
            dram_wdata   = sb_data;
        end else begin
            dram_wr_addr = 16'd0;
            dram_wea     = 4'd0;
            dram_wdata   = 32'd0;
        end
    end

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
    always_comb begin
        if (!mem_req)
            cpu_ready = 1'b1;
        else begin
            case (state)
                S_IDLE:
                    cpu_ready = cache_hit & ~sb_conflict;
                S_DONE:
                    cpu_ready = 1'b1;
                default:
                    cpu_ready = 1'b0;
            endcase
        end
    end

    // ================================================================
    //  Background SB drain: when idle, no miss, SB valid → drain
    //  FSM: IDLE + sb_valid + no miss → S_SB_DRAIN
    //  Already handled in FSM next-state logic above.
    // ================================================================

endmodule
