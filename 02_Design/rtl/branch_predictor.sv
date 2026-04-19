// ============================================================
// Module: branch_predictor
// Description: Tournament branch predictor (IF read / EX update)
//   - BTB: 64-entry, 2-way set-associative, 32 sets
//   - GShare: 8-bit GHR + 256-entry PHT
//   - Selector: 256 × 2-bit, GHR-indexed
//   - RAS: 4-entry shift-register stack
// Spec: 02_Design/spec/branch_predictor_spec.md
//
// Key principle: IF stage is pure combinational read (no state change).
//   All state updates happen in EX stage (no speculative update).
// ============================================================

module branch_predictor (
    input  logic        clk,
    input  logic        rst_n,

    // ==== IF stage: prediction (combinational read) ====
    input  logic [31:0] if_pc,
    output logic        bp_taken,
    output logic [31:0] bp_target,

    // Snapshot outputs (pass through pipeline IF→ID→EX for update)
    output logic [ 7:0] bp_ghr_snap,    // GHR at prediction time
    output logic        bp_btb_hit,     // BTB hit
    output logic        bp_btb_way,     // hit way (0 or 1)
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
    input  logic        ex_btb_way,
    input  logic [ 1:0] ex_btb_bht,
    input  logic [ 1:0] ex_pht_cnt,
    input  logic [ 1:0] ex_sel_cnt
);

    // ================================================================
    //  Parameters
    // ================================================================
    localparam BTB_SETS   = 32;
    localparam BTB_IDX_W  = 5;     // log2(32)
    localparam BTB_TAG_W  = 8;     // PC[14:7]
    localparam BTB_TGT_W  = 30;    // PC[31:2]

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

    // ---- BTB Way 0 ----
    // OPT-3/FIX-B: 数据字段用 LUTRAM，valid 位保持 FF（需要 reset）
    logic                  btb_v0    [0:BTB_SETS-1];    // valid: FF（有 reset）
    (* ram_style = "distributed" *) logic [BTB_TAG_W-1:0]  btb_tag0  [0:BTB_SETS-1];
    (* ram_style = "distributed" *) logic [BTB_TGT_W-1:0]  btb_tgt0  [0:BTB_SETS-1];
    (* ram_style = "distributed" *) logic [1:0]            btb_type0 [0:BTB_SETS-1];
    (* ram_style = "distributed" *) logic [1:0]            btb_bht0  [0:BTB_SETS-1];

    // ---- BTB Way 1 ----
    logic                  btb_v1    [0:BTB_SETS-1];    // valid: FF（有 reset）
    (* ram_style = "distributed" *) logic [BTB_TAG_W-1:0]  btb_tag1  [0:BTB_SETS-1];
    (* ram_style = "distributed" *) logic [BTB_TGT_W-1:0]  btb_tgt1  [0:BTB_SETS-1];
    (* ram_style = "distributed" *) logic [1:0]            btb_type1 [0:BTB_SETS-1];
    (* ram_style = "distributed" *) logic [1:0]            btb_bht1  [0:BTB_SETS-1];

    // ---- BTB LRU (1 bit per set) ----
    // Convention: lru[s]=0 → way0 is LRU; lru[s]=1 → way1 is LRU
    logic                  btb_lru   [0:BTB_SETS-1];

    // ---- GShare ----
    logic [GHR_W-1:0]      ghr;
    (* ram_style = "distributed" *) logic [1:0]            pht       [0:PHT_SIZE-1];

    // ---- Selector ----
    (* ram_style = "distributed" *) logic [1:0]            sel_table [0:SEL_SIZE-1];

    // ---- RAS ----
    logic [31:0]           ras       [0:RAS_DEPTH-1];
    logic [2:0]            ras_count;   // 0..4

    // ================================================================
    //  IF stage — Prediction (combinational, read-only)
    // ================================================================

    // ---- BTB lookup ----
    wire [BTB_IDX_W-1:0] if_set = if_pc[6:2];
    wire [BTB_TAG_W-1:0] if_tag = if_pc[14:7];

    // Read both ways (asynchronous)
    wire                  r_v0    = btb_v0   [if_set];
    wire [BTB_TAG_W-1:0]  r_tag0  = btb_tag0 [if_set];
    wire [BTB_TGT_W-1:0]  r_tgt0  = btb_tgt0 [if_set];
    wire [1:0]            r_type0 = btb_type0[if_set];
    wire [1:0]            r_bht0  = btb_bht0 [if_set];

    wire                  r_v1    = btb_v1   [if_set];
    wire [BTB_TAG_W-1:0]  r_tag1  = btb_tag1 [if_set];
    wire [BTB_TGT_W-1:0]  r_tgt1  = btb_tgt1 [if_set];
    wire [1:0]            r_type1 = btb_type1[if_set];
    wire [1:0]            r_bht1  = btb_bht1 [if_set];

    // Tag compare
    wire hit0 = r_v0 & (r_tag0 == if_tag);
    wire hit1 = r_v1 & (r_tag1 == if_tag);
    wire btb_hit_w = hit0 | hit1;
    wire btb_way_w = hit1;   // 0 = way0, 1 = way1

    // Hit-entry MUX (parallel AND-OR)
    wire [BTB_TGT_W-1:0] hit_tgt  = ({BTB_TGT_W{hit0}} & r_tgt0)
                                   | ({BTB_TGT_W{hit1}} & r_tgt1);
    wire [1:0]            hit_type = ({2{hit0}} & r_type0)
                                   | ({2{hit1}} & r_type1);
    wire [1:0]            hit_bht  = ({2{hit0}} & r_bht0)
                                   | ({2{hit1}} & r_bht1);

    // ---- GShare PHT read ----
    wire [GHR_W-1:0] if_pht_idx = ghr ^ if_pc[9:2];
    wire [1:0]       if_pht_val = pht[if_pht_idx];

    // ---- Selector read ----
    wire [GHR_W-1:0] if_sel_idx = ghr;
    wire [1:0]       if_sel_val = sel_table[if_sel_idx];

    // ---- RAS top ----
    wire [31:0] ras_top   = ras[0];
    wire        ras_valid = (ras_count != 3'd0);

    // ---- Direction prediction ----
    wire bimodal_taken = (hit_bht >= 2'd2);
    wire gshare_taken  = (if_pht_val >= 2'd2);
    wire use_bimodal   = (if_sel_val >= 2'd2);

    // ---- Final prediction ----
    always_comb begin
        bp_taken  = 1'b0;
        bp_target = if_pc + 32'd4;   // default: predict not-taken

        if (btb_hit_w) begin
            case (hit_type)
                TYPE_JAL: begin
                    bp_taken  = 1'b1;
                    bp_target = {hit_tgt, 2'b00};
                end
                TYPE_CALL: begin
                    bp_taken  = 1'b1;
                    bp_target = {hit_tgt, 2'b00};
                end
                TYPE_BRANCH: begin
                    bp_taken  = use_bimodal ? bimodal_taken : gshare_taken;
                    bp_target = bp_taken ? {hit_tgt, 2'b00} : (if_pc + 32'd4);
                end
                TYPE_RET: begin
                    if (ras_valid) begin
                        bp_taken  = 1'b1;
                        bp_target = ras_top;
                    end
                    // else: not-taken (default)
                end
                default: ;
            endcase
        end
    end

    // ---- Snapshot outputs ----
    assign bp_ghr_snap = ghr;
    assign bp_btb_hit  = btb_hit_w;
    assign bp_btb_way  = btb_way_w;
    assign bp_btb_bht  = hit_bht;
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
    // JAL/CALL/RET: always write
    // BRANCH taken: write (allocate or update)
    // BRANCH not-taken + BTB hit: update bht only (rewrite same entry)
    // BRANCH not-taken + BTB miss: don't allocate
    // JALR non-RET: never write
    wire ex_btb_write = ex_update & ~ex_is_jalr_nr &
                        (ex_is_jal | ex_is_ret |
                         (ex_is_branch & (ex_actual_taken | ex_btb_hit)));

    // BTB addressing
    wire [BTB_IDX_W-1:0] ex_set = ex_pc[6:2];
    wire [BTB_TAG_W-1:0] ex_tag = ex_pc[14:7];

    // Write way: hit → same way; miss → LRU way
    wire ex_wr_way = ex_btb_hit ? ex_btb_way : btb_lru[ex_set];

    // Type for BTB entry
    wire [1:0] ex_wr_type = ex_is_jal_nc ? TYPE_JAL  :
                            ex_is_call   ? TYPE_CALL :
                            ex_is_ret    ? TYPE_RET  :
                                           TYPE_BRANCH;

    // BHT value for BTB entry
    //   BRANCH + hit:  saturating inc/dec existing counter
    //   BRANCH + miss: init to weakly taken/not-taken
    //   JAL/CALL/RET:  type field drives prediction, bht set to 11 (don't-care)
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

    // ---- BTB: 合并块，reset 只清 valid+LRU（数据字段不 reset → LUTRAM 友好）----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < BTB_SETS; i++) begin
                btb_v0[i]  <= 1'b0;
                btb_v1[i]  <= 1'b0;
                btb_lru[i] <= 1'b0;
            end
        end else if (ex_btb_write) begin
            if (!ex_wr_way) begin
                btb_v0   [ex_set] <= 1'b1;
                btb_tag0 [ex_set] <= ex_tag;
                btb_tgt0 [ex_set] <= ex_wr_tgt;
                btb_type0[ex_set] <= ex_wr_type;
                btb_bht0 [ex_set] <= ex_wr_bht;
            end else begin
                btb_v1   [ex_set] <= 1'b1;
                btb_tag1 [ex_set] <= ex_tag;
                btb_tgt1 [ex_set] <= ex_wr_tgt;
                btb_type1[ex_set] <= ex_wr_type;
                btb_bht1 [ex_set] <= ex_wr_bht;
            end
            btb_lru[ex_set] <= ex_wr_way ? 1'b0 : 1'b1;
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
