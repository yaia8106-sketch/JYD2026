// ============================================================
// Module: branch_predictor
// Description: Tournament branch predictor with NLP timing optimization
//   IF stage: L0 fast prediction (BTB direct-mapped + Bimodal bht[1])
//   ID stage: L1 Tournament verification (Bimodal vs GShare via Selector)
//   EX stage: all state updates (no speculative update)
//
//   Architecture change (NLP optimization):
//   - BTB: 64-entry direct-mapped (was 2-way 32-set)
//   - IF: uses bht[1] for BRANCH direction (was full Tournament)
//   - Critical path: PC → LUTRAM read → tag compare → bht MUX → IROM
//     = 2-3 logic levels (~3.3ns), down from 8 levels (~7.5ns)
//
// Spec: 02_Design/spec/branch_predictor_spec.md
// ============================================================

module branch_predictor (
    input  logic        clk,
    input  logic        rst_n,

    // ==== IF stage: L0 prediction (combinational read) ====
    input  logic [31:0] if_pc,
    output logic        bp_taken,
    output logic [31:0] bp_target,

    // Snapshot outputs (pass through pipeline IF→ID→EX for update)
    output logic [ 7:0] bp_ghr_snap,    // GHR at prediction time
    output logic        bp_btb_hit,     // BTB hit
    output logic [ 1:0] bp_btb_type,    // hit entry type (NLP: for ID verification)
    output logic [ 1:0] bp_btb_bht,     // Bimodal counter from BTB entry
    output logic [ 1:0] bp_pht_cnt,     // GShare PHT counter
    output logic [ 1:0] bp_sel_cnt,     // Selector counter

    // ==== EX stage: update (sequential write) ====
    input  logic        ex_valid,
    input  logic [31:0] ex_pc,
    input  logic        ex_is_branch,
    input  logic        ex_is_jal,
    input  logic        ex_is_jalr,
    input  logic [ 4:0] ex_rd,
    input  logic [ 4:0] ex_rs1_addr,
    input  logic        ex_actual_taken,    // actual outcome (from branch_unit)
    input  logic [31:0] ex_actual_target,   // actual target  (from branch_unit)

    // Snapshot inputs (from pipeline, originally produced in IF)
    input  logic [ 7:0] ex_ghr_snap,
    input  logic        ex_btb_hit,
    input  logic [ 1:0] ex_btb_bht,
    input  logic [ 1:0] ex_pht_cnt,
    input  logic [ 1:0] ex_sel_cnt
);

    // ================================================================
    //  Parameters
    // ================================================================
    localparam BTB_ENTRIES = 64;
    localparam BTB_IDX_W   = 6;     // log2(64)
    localparam BTB_TAG_W   = 7;     // PC[14:8]
    localparam BTB_TGT_W   = 30;    // PC[31:2]

    localparam GHR_W      = 8;
    localparam PHT_SIZE   = 256;   // 2^GHR_W
    localparam SEL_SIZE   = 256;

    localparam RAS_DEPTH  = 4;

    // Type encoding
    localparam [1:0] TYPE_JAL    = 2'b00;
    localparam [1:0] TYPE_CALL   = 2'b01;
    localparam [1:0] TYPE_BRANCH = 2'b10;
    localparam [1:0] TYPE_RET    = 2'b11;

    // ================================================================
    //  Storage declarations
    // ================================================================

    // ---- BTB: Direct-mapped, 64 entries ----
    // NLP: 1 way only (no way selection → fewer logic levels in IF)
    // All fields are LUTRAM (no reset → 1-level read, vs FF 64:1 MUX ~2-3 levels)
    (* ram_style = "distributed" *) logic                  btb_valid [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [BTB_TAG_W-1:0]  btb_tag   [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [BTB_TGT_W-1:0]  btb_tgt   [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [1:0]            btb_type  [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [1:0]            btb_bht   [0:BTB_ENTRIES-1];

    // ---- GShare ----
    logic [GHR_W-1:0]      ghr;
    (* ram_style = "distributed" *) logic [1:0]            pht       [0:PHT_SIZE-1];

    // ---- Selector ----
    (* ram_style = "distributed" *) logic [1:0]            sel_table [0:SEL_SIZE-1];

    // ---- RAS ----
    logic [31:0]           ras       [0:RAS_DEPTH-1];
    logic [2:0]            ras_count;   // 0..4

    // ================================================================
    //  IF stage — L0 Prediction (combinational, read-only)
    //  Critical path: PC → LUTRAM → tag compare → bht[1] MUX → target
    //  Logic levels: 2-3 (vs 8 in old 2-way Tournament scheme)
    // ================================================================

    // ---- BTB lookup (direct-mapped: single read) ----
    wire [BTB_IDX_W-1:0] if_idx = if_pc[7:2];     // 6 bits for 64 entries
    wire [BTB_TAG_W-1:0] if_tag = if_pc[14:8];     // 7 bits

    wire                  r_valid = btb_valid[if_idx];
    wire [BTB_TAG_W-1:0]  r_tag   = btb_tag  [if_idx];
    wire [BTB_TGT_W-1:0]  r_tgt   = btb_tgt  [if_idx];
    wire [1:0]            r_type  = btb_type [if_idx];
    wire [1:0]            r_bht   = btb_bht  [if_idx];

    // Tag compare (1 LUT level)
    wire btb_hit_w = r_valid & (r_tag == if_tag);

    // ---- GShare PHT read (parallel, not on critical path) ----
    wire [GHR_W-1:0] if_pht_idx = ghr ^ if_pc[9:2];
    wire [1:0]       if_pht_val = pht[if_pht_idx];

    // ---- Selector read (parallel, not on critical path) ----
    wire [GHR_W-1:0] if_sel_idx = ghr;
    wire [1:0]       if_sel_val = sel_table[if_sel_idx];

    // ---- RAS top ----
    wire [31:0] ras_top   = ras[0];
    wire        ras_valid = (ras_count != 3'd0);

    // ---- L0 Fast prediction (AND-OR, flat logic) ----
    // NLP key: BRANCH direction uses bht[1] only (Bimodal)
    // Full Tournament verification deferred to ID stage

    // bp_taken: 5 inputs → single LUT6
    //   hit=0 → 0
    //   JAL/CALL (type[1]=0) → 1 (always taken)
    //   BRANCH  (type=10)    → bht[1] (bimodal direction)
    //   RET     (type=11)    → ras_valid
    assign bp_taken = btb_hit_w & (
          ~r_type[1]                    // JAL/CALL: always taken
        | (~r_type[0] & r_bht[1])      // BRANCH: bimodal direction
        | ( r_type[0] & ras_valid)     // RET: RAS valid
    );

    // bp_target: 3-way AND-OR MUX (one-hot selects)
    //   JAL/CALL/BRANCH → BTB target (ID stage needs it for redirect)
    //   RET + ras_valid → RAS top
    //   otherwise       → PC+4 (sequential)
    wire sel_btb = btb_hit_w & ~(r_type[1] & r_type[0]);          // JAL/CALL/BRANCH
    wire sel_ras = btb_hit_w &   r_type[1] & r_type[0] & ras_valid; // RET
    wire sel_seq = ~sel_btb & ~sel_ras;                             // default

    assign bp_target = ({32{sel_btb}} & {r_tgt, 2'b00})
                     | ({32{sel_ras}} & ras_top)
                     | ({32{sel_seq}} & (if_pc + 32'd4));

    // ---- Snapshot outputs ----
    assign bp_ghr_snap = ghr;
    assign bp_btb_hit  = btb_hit_w;
    assign bp_btb_type = btb_hit_w ? r_type : 2'b00;
    assign bp_btb_bht  = r_bht;
    assign bp_pht_cnt  = if_pht_val;
    assign bp_sel_cnt  = if_sel_val;

    // ================================================================
    //  EX stage — Update logic (combinational signals for sequential)
    // ================================================================

    // ---- Instruction type classification ----
    wire ex_is_call    = ex_is_jal  & (ex_rd == 5'd1);
    wire ex_is_jal_nc  = ex_is_jal  & (ex_rd != 5'd1);   // JAL, not CALL
    wire ex_is_ret     = ex_is_jalr & (ex_rs1_addr == 5'd1) & (ex_rd == 5'd0);
    wire ex_is_jalr_nr = ex_is_jalr & ~ex_is_ret;         // non-RET JALR

    // Any update-worthy instruction in EX
    wire ex_update = ex_valid & (ex_is_branch | ex_is_jal | ex_is_jalr);

    // ---- BTB write decision ----
    wire ex_btb_write = ex_update & ~ex_is_jalr_nr &
                        (ex_is_jal | ex_is_ret |
                         (ex_is_branch & (ex_actual_taken | ex_btb_hit)));

    // BTB addressing (direct-mapped)
    wire [BTB_IDX_W-1:0] ex_idx = ex_pc[7:2];
    wire [BTB_TAG_W-1:0] ex_tag = ex_pc[14:8];

    // Type for BTB entry
    wire [1:0] ex_wr_type = ex_is_jal_nc ? TYPE_JAL  :
                            ex_is_call   ? TYPE_CALL :
                            ex_is_ret    ? TYPE_RET  :
                                           TYPE_BRANCH;

    // BHT value for BTB entry
    wire [1:0] ex_bht_inc = (ex_btb_bht == 2'd3) ? 2'd3 : ex_btb_bht + 2'd1;
    wire [1:0] ex_bht_dec = (ex_btb_bht == 2'd0) ? 2'd0 : ex_btb_bht - 2'd1;

    wire [1:0] ex_wr_bht;
    assign ex_wr_bht = ex_is_branch ?
                           (ex_btb_hit ?
                               (ex_actual_taken ? ex_bht_inc : ex_bht_dec) :
                               (ex_actual_taken ? 2'b10 : 2'b01)) :
                           2'b11;

    // Target for BTB entry
    wire [BTB_TGT_W-1:0] ex_wr_tgt = ex_actual_target[31:2];

    // ---- GShare PHT update (BRANCH only) ----
    wire [GHR_W-1:0] ex_pht_idx = ex_ghr_snap ^ ex_pc[9:2];
    wire [1:0] ex_pht_inc = (ex_pht_cnt == 2'd3) ? 2'd3 : ex_pht_cnt + 2'd1;
    wire [1:0] ex_pht_dec = (ex_pht_cnt == 2'd0) ? 2'd0 : ex_pht_cnt - 2'd1;
    wire [1:0] ex_new_pht = ex_actual_taken ? ex_pht_inc : ex_pht_dec;

    wire ex_pht_write = ex_valid & ex_is_branch;

    // ---- GHR shift (BRANCH only) ----
    wire ex_ghr_write = ex_valid & ex_is_branch;

    // ---- Selector update (BRANCH + BTB hit + bimodal≠gshare) ----
    wire ex_bimodal_pred = (ex_btb_bht >= 2'd2);
    wire ex_gshare_pred  = (ex_pht_cnt >= 2'd2);

    wire ex_bimodal_ok = (ex_bimodal_pred == ex_actual_taken);
    wire ex_gshare_ok  = (ex_gshare_pred  == ex_actual_taken);

    wire ex_sel_write = ex_valid & ex_is_branch & ex_btb_hit &
                        (ex_bimodal_pred != ex_gshare_pred);

    wire [GHR_W-1:0] ex_sel_idx = ex_ghr_snap;
    wire [1:0] ex_sel_inc = (ex_sel_cnt == 2'd3) ? 2'd3 : ex_sel_cnt + 2'd1;
    wire [1:0] ex_sel_dec = (ex_sel_cnt == 2'd0) ? 2'd0 : ex_sel_cnt - 2'd1;
    wire [1:0] ex_new_sel = ex_bimodal_ok ? ex_sel_inc : ex_sel_dec;

    // ---- RAS push/pop ----
    wire ex_ras_push = ex_valid & ex_is_call;
    wire ex_ras_pop  = ex_valid & ex_is_ret;

    // ================================================================
    //  Sequential update (all at posedge clk)
    // ================================================================

    // ---- BTB: direct-mapped, all LUTRAM (no reset) ----
    // Cold-start safe: uninitialized valid may cause wrong predictions,
    // but branch_unit will detect misprediction and flush → functionally correct.
    // Same pattern as PHT and selector.
    initial begin
        for (int i = 0; i < BTB_ENTRIES; i++) btb_valid[i] = 1'b0;
    end
    always_ff @(posedge clk) begin
        if (ex_btb_write) begin
            btb_valid[ex_idx] <= 1'b1;
            btb_tag  [ex_idx] <= ex_tag;
            btb_tgt  [ex_idx] <= ex_wr_tgt;
            btb_type [ex_idx] <= ex_wr_type;
            btb_bht  [ex_idx] <= ex_wr_bht;
        end
    end

    // ---- GHR ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ghr <= '0;
        else if (ex_ghr_write)
            ghr <= {ghr[GHR_W-2:0], ex_actual_taken};
    end

    // ---- GShare PHT: 无 reset（使 LUTRAM 推断生效）----
    // FIX-B: 冷启动时预测不准，但功能正确（错了会 flush 重取）
    // initial 块仅用于仿真初始化，不阻止 Vivado LUTRAM 推断
    initial begin
        for (int i = 0; i < PHT_SIZE; i++) pht[i] = 2'b01;
    end
    always_ff @(posedge clk) begin
        if (ex_pht_write)
            pht[ex_pht_idx] <= ex_new_pht;
    end

    // ---- Selector: 无 reset（使 LUTRAM 推断生效）----
    initial begin
        for (int i = 0; i < SEL_SIZE; i++) sel_table[i] = 2'b01;
    end
    always_ff @(posedge clk) begin
        if (ex_sel_write)
            sel_table[ex_sel_idx] <= ex_new_sel;
    end

    // ---- RAS: 保留 reset（仅 4 entry，不影响 LUTRAM）----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < RAS_DEPTH; i++)
                ras[i] <= 32'd0;
            ras_count <= 3'd0;
        end else if (ex_ras_push) begin
            // Shift down and push new entry at top
            ras[3] <= ras[2];
            ras[2] <= ras[1];
            ras[1] <= ras[0];
            ras[0] <= ex_pc + 32'd4;       // return address = CALL_pc + 4
            if (ras_count < 3'd4)
                ras_count <= ras_count + 3'd1;
        end else if (ex_ras_pop) begin
            // Shift up (pop top)
            ras[0] <= ras[1];
            ras[1] <= ras[2];
            ras[2] <= ras[3];
            ras[3] <= 32'd0;
            if (ras_count > 3'd0)
                ras_count <= ras_count - 3'd1;
        end
    end

endmodule
