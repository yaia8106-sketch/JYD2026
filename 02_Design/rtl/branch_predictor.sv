// ============================================================
// Module: branch_predictor
// Description: Tournament branch predictor with NLP timing optimization
//   IF stage: L0 fast prediction (BTB direct-mapped + Bimodal bht[1])
//   ID stage: L1 Tournament verification (Bimodal vs GShare via Selector)
//   EX stage: all state updates (no speculative update)
//
//   Architecture change (NLP optimization):
//   - BTB: 128-entry direct-mapped (was 2-way 32-set)
//   - IF: uses bht[1] for BRANCH direction (was full Tournament)
//   - BTB target even-bank address is stored beside full bp_target
//     so cpu_top does not run target → bank-address adders on the IROM path.
//   - RAS follows x1/x5 link-register hints: JAL/JALR with rd=x1/x5
//     pushes, JALR x0, 0(x1/x5) pops.
//   - x5 JALR call/ret entries live in a tiny sidecar so libgcc helper
//     returns do not evict hot branch/JAL entries from the main BTB.
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
    output logic [11:0] bp_even_addr,
    output logic [11:0] bp_odd_addr,
    output logic        bp_fetch_odd,
    output logic [11:0] bp_plus4_even_addr,
    output logic [11:0] bp_plus4_odd_addr,
    output logic        bp_plus4_fetch_odd,
    output logic [11:0] bp_plus8_even_addr,
    output logic [11:0] bp_plus8_odd_addr,
    output logic        bp_plus8_fetch_odd,
    output logic [11:0] bp_plus12_even_addr,
    output logic [11:0] bp_plus12_odd_addr,
    output logic        bp_plus12_fetch_odd,

    // Snapshot outputs (pass through pipeline IF→ID→EX for update)
    output logic [ 7:0] bp_ghr_snap,    // GHR at prediction time
    output logic        bp_btb_hit,     // BTB hit
    output logic [ 1:0] bp_btb_type,    // hit entry type (NLP: for ID verification)
    output logic [ 1:0] bp_btb_bht,     // Bimodal counter from BTB entry
    output logic [ 1:0] bp_pht_cnt,     // GShare PHT counter
    output logic [ 1:0] bp_sel_cnt,     // Selector counter

    // ==== Slot1 candidate snapshot ====
    // Read-only metadata for the instruction at if_pc + 4.  This port uses the
    // same non-bypassed history snapshot as BP0 so the value carried to EX is
    // the state observed by this fetch packet, not a same-edge EX update.
    input  logic [31:0] s1_pc,
    output logic        s1_bp_taken,
    output logic [31:0] s1_bp_target,
    output logic [ 7:0] s1_bp_ghr_snap,
    output logic        s1_bp_btb_hit,
    output logic [ 1:0] s1_bp_btb_type,
    output logic [ 1:0] s1_bp_btb_bht,
    output logic [ 1:0] s1_bp_pht_cnt,
    output logic [ 1:0] s1_bp_sel_cnt,

    // ==== Lookahead L0 prediction ====
    // Used by cpu_top to pre-budget the next-cycle skip_inst0 fetch.  History
    // counters use lightweight same-edge bypassing, while target tables are
    // read as a snapshot to keep EX branch compare out of frontend registers.
    input  logic [31:0] la_pc,
    output logic        la_bp_taken,
    output logic [31:0] la_bp_target,
    output logic [11:0] la_bp_even_addr,
    output logic [11:0] la_bp_odd_addr,
    output logic        la_bp_fetch_odd,
    output logic [ 7:0] la_bp_ghr_snap,
    output logic        la_bp_btb_hit,
    output logic [ 1:0] la_bp_btb_type,
    output logic [ 1:0] la_bp_btb_bht,
    output logic [ 1:0] la_bp_pht_cnt,
    output logic [ 1:0] la_bp_sel_cnt,

    // ==== Buffered slot prediction ====
    // cpu_top stores these beside inst_buf, removing inst_buf_before_window
    // from the IF PC -> BP lookup -> IROM address path.
    input  logic [31:0] buf_pc,
    output logic        buf_bp_taken,
    output logic [31:0] buf_bp_target,
    output logic [11:0] buf_bp_even_addr,
    output logic [11:0] buf_bp_odd_addr,
    output logic        buf_bp_fetch_odd,
    output logic [ 7:0] buf_bp_ghr_snap,
    output logic        buf_bp_btb_hit,
    output logic [ 1:0] buf_bp_btb_type,
    output logic [ 1:0] buf_bp_btb_bht,
    output logic [ 1:0] buf_bp_pht_cnt,
    output logic [ 1:0] buf_bp_sel_cnt,

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
    input  logic        ex_btb_allocate,    // allow allocating a new branch BTB entry

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
    localparam BTB_ENTRIES = 128;
    localparam BTB_IDX_W   = 7;     // log2(128)
    localparam BTB_TAG_W   = 5;     // PC[13:9] (5-bit: compare+valid fits 1 LUT6)
    localparam BTB_TGT_W   = 30;    // PC[31:2]

    localparam JALR_ENTRIES = 8;
    localparam JALR_IDX_W   = 3;
    localparam JALR_TAG_W   = 9;     // PC[13:5], unique within 16KB IROM

    localparam GHR_W      = 8;
    localparam PHT_SIZE   = 256;   // 2^GHR_W
    localparam SEL_SIZE   = 256;

    localparam RAS_DEPTH  = 4;

    // Type encoding
    localparam [1:0] TYPE_JAL    = 2'b00;
    localparam [1:0] TYPE_CALL   = 2'b01;
    localparam [1:0] TYPE_BRANCH = 2'b10;
    localparam [1:0] TYPE_RET    = 2'b11;

    function automatic [11:0] btb_even_bank_addr(input logic [BTB_TGT_W-1:0] tgt);
        btb_even_bank_addr = {1'b0, tgt[11:1]} + {11'd0, tgt[0]};
    endfunction

    function automatic [11:0] btb_odd_bank_addr(input logic [BTB_TGT_W-1:0] tgt);
        btb_odd_bank_addr = {1'b0, tgt[11:1]};
    endfunction

    function automatic [11:0] full_even_bank_addr(input logic [31:0] addr);
        full_even_bank_addr = {1'b0, addr[13:3]} + {11'd0, addr[2]};
    endfunction

    function automatic [11:0] full_odd_bank_addr(input logic [31:0] addr);
        full_odd_bank_addr = {1'b0, addr[13:3]};
    endfunction

    // ================================================================
    //  Storage declarations
    // ================================================================

    // ---- BTB: Direct-mapped, 128 entries ----
    // NLP: 1 way only (no way selection → fewer logic levels in IF)
    // All fields are LUTRAM (no reset → 1-level read, vs FF 64:1 MUX ~2-3 levels)
    (* ram_style = "distributed" *) logic                  btb_valid [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [BTB_TAG_W-1:0]  btb_tag   [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [BTB_TGT_W-1:0]  btb_tgt   [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [11:0]           btb_even  [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [11:0]           btb_p4_even  [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [11:0]           btb_p8_even  [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [11:0]           btb_p12_even [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [1:0]            btb_type  [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic [1:0]            btb_bht   [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic                  btb_l0_taken [0:BTB_ENTRIES-1];
    (* ram_style = "distributed" *) logic                  btb_needs_ras [0:BTB_ENTRIES-1];

    // ---- JALR sidecar ----
    // x5-link JALR sites are very few but hot in the contest COE programs.
    // Keeping them out of the main direct-mapped BTB avoids pathological
    // aliasing with hot JAL/branch entries while still enabling RAS returns.
    (* ram_style = "distributed" *) logic                  jalr_valid [0:JALR_ENTRIES-1];
    (* ram_style = "distributed" *) logic [JALR_TAG_W-1:0] jalr_tag   [0:JALR_ENTRIES-1];
    (* ram_style = "distributed" *) logic [BTB_TGT_W-1:0]  jalr_tgt   [0:JALR_ENTRIES-1];
    (* ram_style = "distributed" *) logic [11:0]           jalr_even  [0:JALR_ENTRIES-1];
    (* ram_style = "distributed" *) logic [11:0]           jalr_p4_even  [0:JALR_ENTRIES-1];
    (* ram_style = "distributed" *) logic [11:0]           jalr_p8_even  [0:JALR_ENTRIES-1];
    (* ram_style = "distributed" *) logic [11:0]           jalr_p12_even [0:JALR_ENTRIES-1];
    (* ram_style = "distributed" *) logic                  jalr_needs_ras [0:JALR_ENTRIES-1];

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
    wire [BTB_IDX_W-1:0] if_idx = if_pc[8:2];     // 7 bits for 128 entries
    wire [BTB_TAG_W-1:0] if_tag = if_pc[13:9];     // 5 bits → 1 LUT6 compare

    wire                  r_valid = btb_valid[if_idx];
    wire [BTB_TAG_W-1:0]  r_tag   = btb_tag  [if_idx];
    wire [BTB_TGT_W-1:0]  r_tgt   = btb_tgt  [if_idx];
    wire [11:0]           r_even  = btb_even [if_idx];
    wire [11:0]           r_p4_even  = btb_p4_even  [if_idx];
    wire [11:0]           r_p8_even  = btb_p8_even  [if_idx];
    wire [11:0]           r_p12_even = btb_p12_even [if_idx];
    wire [1:0]            r_type  = btb_type [if_idx];
    wire [1:0]            r_bht   = btb_bht  [if_idx];
    wire                  r_l0_taken = btb_l0_taken[if_idx];
    wire                  r_needs_ras = btb_needs_ras[if_idx];

    // Tag compare (used by bp_taken in parallel, not serial)
    wire tag_match  = (r_tag == if_tag);
    wire btb_hit_w  = r_valid & tag_match;

    // ---- GShare PHT read (parallel, not on critical path) ----
    wire [GHR_W-1:0] if_pht_idx = ghr ^ if_pc[9:2];
    wire [1:0]       if_pht_val = pht[if_pht_idx];

    // ---- Selector read (parallel, not on critical path) ----
    wire [GHR_W-1:0] if_sel_idx = ghr;
    wire [1:0]       if_sel_val = sel_table[if_sel_idx];

    // ---- RAS top ----
    wire [31:0] ras_top   = ras[0];
    wire        ras_valid = (ras_count != 3'd0);

    // ---- x5 JALR sidecar lookup (parallel to main BTB) ----
    wire [JALR_IDX_W-1:0] if_jalr_idx = if_pc[4:2];
    wire [JALR_TAG_W-1:0] if_jalr_tag = if_pc[13:5];

    wire                  jr_valid = jalr_valid[if_jalr_idx];
    wire [JALR_TAG_W-1:0] jr_tag   = jalr_tag  [if_jalr_idx];
    wire [BTB_TGT_W-1:0]  jr_tgt   = jalr_tgt  [if_jalr_idx];
    wire [11:0]           jr_even  = jalr_even [if_jalr_idx];
    wire [11:0]           jr_p4_even  = jalr_p4_even  [if_jalr_idx];
    wire [11:0]           jr_p8_even  = jalr_p8_even  [if_jalr_idx];
    wire [11:0]           jr_p12_even = jalr_p12_even [if_jalr_idx];
    wire                  jr_needs_ras = jalr_needs_ras[if_jalr_idx];

    wire jr_hit       = jr_valid & (jr_tag == if_jalr_tag);
    wire jr_taken     = jr_hit & (~jr_needs_ras | ras_valid);

    // ---- L0 Fast prediction (parallelized: tag_match as late AND) ----
    // NLP key: BRANCH direction uses bht[1] only (Bimodal)
    // Full Tournament verification deferred to ID stage
    //
    // Parallel structure:
    //   Main BTB path keeps tag_match as the late AND.
    //   x5 JALR sidecar runs in parallel and only ORs into the final result.
    wire bp_taken_raw = r_valid & r_l0_taken & (~r_needs_ras | ras_valid);
    wire btb_taken = bp_taken_raw & tag_match;
    assign bp_taken = jr_taken | btb_taken;

    wire [11:0] jr_tgt_odd_addr  = btb_odd_bank_addr(jr_tgt);
    wire [11:0] r_tgt_odd_addr  = btb_odd_bank_addr(r_tgt);
    wire [11:0] ras_even_addr   = full_even_bank_addr(ras_top);
    wire [11:0] ras_odd_addr    = full_odd_bank_addr(ras_top);
    wire [11:0] ras_p4_even_addr  = ras_odd_addr + 12'd1;
    wire [11:0] ras_p8_even_addr  = ras_even_addr + 12'd1;
    wire [11:0] ras_p12_even_addr = ras_odd_addr + 12'd2;

    // Target/address candidates are built in two independent trees:
    //   sidecar JALR candidate and main BTB/RAS candidate.
    // The old one-hot AND-OR form fed ~jr_taken into every main candidate bit,
    // so the JALR tag-compare result serialized through the main target mux.
    // Keep the two candidates parallel and use jr_taken only as the final
    // priority select.  When bp_taken=0 the address outputs are don't-care.
    // Address candidates do not need r_valid in their local select.  If the
    // BTB entry is invalid, bp_taken is false and these addresses are not used.
    // Keeping r_valid out avoids serializing valid RAM read into the bank
    // address mux select on the PC -> IROM path.
    wire main_select_ras = r_needs_ras & ras_valid;
    wire jr_select_ras = jr_needs_ras;

    wire [31:0] main_target = main_select_ras ? ras_top : {r_tgt, 2'b00};
    wire [31:0] jr_target = jr_select_ras ? ras_top : {jr_tgt, 2'b00};

    wire [11:0] main_even_addr = main_select_ras ? ras_even_addr : r_even;
    wire [11:0] main_odd_addr = main_select_ras ? ras_odd_addr : r_tgt_odd_addr;
    wire        main_fetch_odd = main_select_ras ? ras_top[2] : r_tgt[0];
    wire [11:0] jr_even_addr = jr_select_ras ? ras_even_addr : jr_even;
    wire [11:0] jr_odd_addr = jr_select_ras ? ras_odd_addr : jr_tgt_odd_addr;
    wire        jr_fetch_odd = jr_select_ras ? ras_top[2] : jr_tgt[0];

    assign bp_target = jr_taken ? jr_target : main_target;
    assign bp_even_addr = jr_taken ? jr_even_addr : main_even_addr;
    assign bp_odd_addr = jr_taken ? jr_odd_addr : main_odd_addr;
    assign bp_fetch_odd = jr_taken ? jr_fetch_odd : main_fetch_odd;

    wire [11:0] main_plus4_even_addr = main_select_ras ? ras_p4_even_addr : r_p4_even;
    wire [11:0] main_plus4_odd_addr = main_select_ras ? ras_even_addr : r_even;
    wire [11:0] jr_plus4_even_addr = jr_select_ras ? ras_p4_even_addr : jr_p4_even;
    wire [11:0] jr_plus4_odd_addr = jr_select_ras ? ras_even_addr : jr_even;
    assign bp_plus4_even_addr = jr_taken ? jr_plus4_even_addr : main_plus4_even_addr;
    assign bp_plus4_odd_addr = jr_taken ? jr_plus4_odd_addr : main_plus4_odd_addr;
    assign bp_plus4_fetch_odd = ~bp_fetch_odd;

    wire [11:0] main_plus8_even_addr = main_select_ras ? ras_p8_even_addr : r_p8_even;
    wire [11:0] main_plus8_odd_addr = main_select_ras ? ras_p4_even_addr : r_p4_even;
    wire [11:0] jr_plus8_even_addr = jr_select_ras ? ras_p8_even_addr : jr_p8_even;
    wire [11:0] jr_plus8_odd_addr = jr_select_ras ? ras_p4_even_addr : jr_p4_even;
    assign bp_plus8_even_addr = jr_taken ? jr_plus8_even_addr : main_plus8_even_addr;
    assign bp_plus8_odd_addr = jr_taken ? jr_plus8_odd_addr : main_plus8_odd_addr;
    assign bp_plus8_fetch_odd = bp_fetch_odd;

    wire [11:0] main_plus12_even_addr = main_select_ras ? ras_p12_even_addr : r_p12_even;
    wire [11:0] main_plus12_odd_addr = main_select_ras ? ras_p8_even_addr : r_p8_even;
    wire [11:0] jr_plus12_even_addr = jr_select_ras ? ras_p12_even_addr : jr_p12_even;
    wire [11:0] jr_plus12_odd_addr = jr_select_ras ? ras_p8_even_addr : jr_p8_even;
    assign bp_plus12_even_addr = jr_taken ? jr_plus12_even_addr : main_plus12_even_addr;
    assign bp_plus12_odd_addr = jr_taken ? jr_plus12_odd_addr : main_plus12_odd_addr;
    assign bp_plus12_fetch_odd = ~bp_fetch_odd;

    // ---- Snapshot outputs ----
    assign bp_ghr_snap = ghr;
    assign bp_btb_hit  = btb_hit_w;
    assign bp_btb_type = btb_hit_w ? r_type : 2'b00;
    assign bp_btb_bht  = r_bht;
    assign bp_pht_cnt  = if_pht_val;
    assign bp_sel_cnt  = if_sel_val;

    // ================================================================
    //  Slot1 candidate snapshot
    // ================================================================

    wire [BTB_IDX_W-1:0] s1_idx = s1_pc[8:2];
    wire [BTB_TAG_W-1:0] s1_tag = s1_pc[13:9];
    wire [JALR_IDX_W-1:0] s1_jalr_idx = s1_pc[4:2];
    wire [JALR_TAG_W-1:0] s1_jalr_tag = s1_pc[13:5];

    wire                 s1_r_valid = btb_valid[s1_idx];
    wire [BTB_TAG_W-1:0] s1_r_tag   = btb_tag  [s1_idx];
    wire [BTB_TGT_W-1:0] s1_r_tgt   = btb_tgt  [s1_idx];
    wire [1:0]           s1_r_type  = btb_type [s1_idx];
    wire [1:0]           s1_r_bht   = btb_bht  [s1_idx];
    wire                 s1_r_l0_taken = btb_l0_taken[s1_idx];
    wire                 s1_r_needs_ras = btb_needs_ras[s1_idx];

    wire                  s1_jr_valid = jalr_valid[s1_jalr_idx];
    wire [JALR_TAG_W-1:0] s1_jr_tag   = jalr_tag  [s1_jalr_idx];
    wire [BTB_TGT_W-1:0]  s1_jr_tgt   = jalr_tgt  [s1_jalr_idx];
    wire                  s1_jr_needs_ras = jalr_needs_ras[s1_jalr_idx];

    wire s1_tag_match = (s1_r_tag == s1_tag);
    wire s1_btb_hit_w = s1_r_valid & s1_tag_match;
    wire s1_jr_hit    = s1_jr_valid & (s1_jr_tag == s1_jalr_tag);
    wire s1_jr_taken  = s1_jr_hit & (~s1_jr_needs_ras | ras_valid);
    wire s1_btb_taken = s1_r_valid & s1_r_l0_taken
                      & (~s1_r_needs_ras | ras_valid)
                      & s1_tag_match;

    wire [GHR_W-1:0] s1_pht_idx = ghr ^ s1_pc[9:2];
    wire [1:0]       s1_pht_val = pht[s1_pht_idx];
    wire [GHR_W-1:0] s1_sel_idx = ghr;
    wire [1:0]       s1_sel_val = sel_table[s1_sel_idx];

    wire [31:0] s1_main_target = s1_r_needs_ras ? ras_top
                                                 : {s1_r_tgt, 2'b00};
    wire [31:0] s1_jr_target = s1_jr_needs_ras ? ras_top
                                                : {s1_jr_tgt, 2'b00};

    assign s1_bp_taken = s1_jr_taken | s1_btb_taken;
    assign s1_bp_target = s1_jr_taken ? s1_jr_target : s1_main_target;
    assign s1_bp_ghr_snap = ghr;
    assign s1_bp_btb_hit  = s1_btb_hit_w;
    assign s1_bp_btb_type = s1_btb_hit_w ? s1_r_type : 2'b00;
    assign s1_bp_btb_bht  = s1_r_bht;
    assign s1_bp_pht_cnt  = s1_pht_val;
    assign s1_bp_sel_cnt  = s1_sel_val;

    // ================================================================
    //  EX stage — Update logic (combinational signals for sequential)
    // ================================================================

    // ---- Instruction type classification ----
    // RISC-V uses x1 (ra) and x5 (t0) as link-register hints.  The COE
    // workloads use x5 for libgcc helper returns (jr t0), so treating x5 as
    // a RAS link register avoids repeated EX-stage redirects.
    wire ex_rd_is_x1    = (ex_rd == 5'd1);
    wire ex_rd_is_x5    = (ex_rd == 5'd5);
    wire ex_rs1_is_x1   = (ex_rs1_addr == 5'd1);
    wire ex_rs1_is_x5   = (ex_rs1_addr == 5'd5);
    wire ex_rd_is_link  = ex_rd_is_x1 | ex_rd_is_x5;
    wire ex_rs1_is_link = ex_rs1_is_x1 | ex_rs1_is_x5;

    wire ex_is_jalr_call = ex_is_jalr & ex_rd_is_link;
    wire ex_is_call      = (ex_is_jal & ex_rd_is_link) | ex_is_jalr_call;
    wire ex_is_jal_nc    = ex_is_jal & ~ex_rd_is_link;   // JAL, not CALL
    wire ex_is_ret       = ex_is_jalr & (ex_rd == 5'd0) & ex_rs1_is_link;
    wire ex_is_jalr_nr   = ex_is_jalr & ~ex_is_ret & ~ex_is_jalr_call;
    wire ex_track_jalr   = ex_is_jalr & ~ex_is_jalr_nr;  // CALL-like or RET-like JALR
    wire ex_sidecar_jalr = ex_track_jalr & (ex_rd_is_x5 | ex_rs1_is_x5);
    wire ex_main_jalr    = ex_track_jalr & ~ex_sidecar_jalr;

    // Any update-worthy instruction in EX
    wire ex_update = ex_valid & (ex_is_branch | ex_is_jal | ex_is_jalr);

    // BTB hit updates and direct jumps write regardless of actual direction.
    // Only a taken branch miss with allocation enabled needs actual_taken.
    wire ex_btb_write_always = ex_update &
                               (ex_is_jal | ex_main_jalr | (ex_is_branch & ex_btb_hit));
    wire ex_btb_write_alloc_taken = ex_update & ex_is_branch
                                  & ex_btb_allocate & ex_actual_taken;
    wire ex_btb_write = ex_btb_write_always | ex_btb_write_alloc_taken;

    wire ex_jalr_side_write = ex_update & ex_sidecar_jalr;

    // BTB addressing (direct-mapped)
    wire [BTB_IDX_W-1:0] ex_idx = ex_pc[8:2];
    wire [BTB_TAG_W-1:0] ex_tag = ex_pc[13:9];
    wire [JALR_IDX_W-1:0] ex_jalr_idx = ex_pc[4:2];
    wire [JALR_TAG_W-1:0] ex_jalr_tag = ex_pc[13:5];

    // Type for BTB entry
    wire [1:0] ex_wr_type = ex_is_call   ? TYPE_CALL :
                            ex_is_jal_nc ? TYPE_JAL  :
                            ex_is_ret    ? TYPE_RET  :
                                           TYPE_BRANCH;

    // BHT value for BTB entry (parallelized: actual_taken as late MUX select)
    wire [1:0] ex_bht_inc = (ex_btb_bht == 2'd3) ? 2'd3 : ex_btb_bht + 2'd1;
    wire [1:0] ex_bht_dec = (ex_btb_bht == 2'd0) ? 2'd0 : ex_btb_bht - 2'd1;

    wire [1:0] ex_wr_bht_if_taken     = ex_is_branch ? (ex_btb_hit ? ex_bht_inc : 2'b10) : 2'b11;
    wire [1:0] ex_wr_bht_if_not_taken = ex_is_branch ? (ex_btb_hit ? ex_bht_dec : 2'b01) : 2'b11;
    wire [1:0] ex_wr_bht = ex_actual_taken ? ex_wr_bht_if_taken : ex_wr_bht_if_not_taken;
    wire       ex_wr_l0_taken = ex_is_branch ? ex_wr_bht[1] : 1'b1;
    wire       ex_wr_needs_ras = ex_is_ret;

    // Target for BTB entry
    wire [BTB_TGT_W-1:0] ex_wr_tgt = ex_actual_target[31:2];
    wire [11:0] ex_wr_even = btb_even_bank_addr(ex_wr_tgt);
    wire [11:0] ex_wr_odd = btb_odd_bank_addr(ex_wr_tgt);
    wire [11:0] ex_wr_p4_even  = ex_wr_odd + 12'd1;
    wire [11:0] ex_wr_p8_even  = ex_wr_even + 12'd1;
    wire [11:0] ex_wr_p12_even = ex_wr_odd + 12'd2;

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

    wire ex_sel_write = ex_valid & ex_is_branch & ex_btb_hit &
                        (ex_bimodal_pred != ex_gshare_pred);

    wire [GHR_W-1:0] ex_sel_idx = ex_ghr_snap;
    wire [1:0] ex_sel_inc = (ex_sel_cnt == 2'd3) ? 2'd3 : ex_sel_cnt + 2'd1;
    wire [1:0] ex_sel_dec = (ex_sel_cnt == 2'd0) ? 2'd0 : ex_sel_cnt - 2'd1;
    // Parallelized: actual_taken as late MUX select
    // if taken:     bimodal_ok = bimodal_pred  → inc if pred=1, dec if pred=0
    // if not taken: bimodal_ok = ~bimodal_pred → dec if pred=1, inc if pred=0
    wire [1:0] ex_new_sel_if_taken     = ex_bimodal_pred ? ex_sel_inc : ex_sel_dec;
    wire [1:0] ex_new_sel_if_not_taken = ex_bimodal_pred ? ex_sel_dec : ex_sel_inc;
    wire [1:0] ex_new_sel = ex_actual_taken ? ex_new_sel_if_taken : ex_new_sel_if_not_taken;

    // ---- RAS push/pop ----
    wire ex_ras_push = ex_valid & ex_is_call;
    wire ex_ras_pop  = ex_valid & ex_is_ret;

    // ================================================================
    //  Lookahead L0 prediction
    // ================================================================

    // Model the lightweight history/RAS state as it will appear immediately
    // after this clock edge.  BTB/JALR target tables deliberately do not
    // bypass EX updates here: cpu_top registers these outputs unconditionally,
    // so a target bypass would recreate an EX-compare -> frontend-register
    // timing path.  A missed same-edge table update costs at most one stale
    // skip-slot prediction and is corrected by the normal EX redirect path.
    wire [GHR_W-1:0] la_ghr_next = ex_ghr_write ? {ghr[GHR_W-2:0], ex_actual_taken}
                                                : ghr;

    wire [31:0] la_ras_top_next = ex_ras_push ? (ex_pc + 32'd4) :
                                  ex_ras_pop  ? ras[1] :
                                                ras[0];
    wire [2:0] la_ras_count_next = ex_ras_push ? ((ras_count < 3'd4) ? (ras_count + 3'd1) : ras_count) :
                                   ex_ras_pop  ? ((ras_count > 3'd0) ? (ras_count - 3'd1) : ras_count) :
                                                 ras_count;
    wire la_ras_valid_next = (la_ras_count_next != 3'd0);

    wire [BTB_IDX_W-1:0] la_idx = la_pc[8:2];
    wire [BTB_TAG_W-1:0] la_tag = la_pc[13:9];
    wire [JALR_IDX_W-1:0] la_jalr_idx = la_pc[4:2];
    wire [JALR_TAG_W-1:0] la_jalr_tag = la_pc[13:5];

    wire                 la_r_valid = btb_valid[la_idx];
    wire [BTB_TAG_W-1:0] la_r_tag   = btb_tag  [la_idx];
    wire [BTB_TGT_W-1:0] la_r_tgt   = btb_tgt  [la_idx];
    wire [11:0]          la_r_even  = btb_even [la_idx];
    wire [1:0]           la_r_type  = btb_type [la_idx];
    wire [1:0]           la_r_bht   = btb_bht  [la_idx];
    wire                 la_r_l0_taken = btb_l0_taken[la_idx];
    wire                 la_r_needs_ras = btb_needs_ras[la_idx];

    wire                  la_jr_valid = jalr_valid[la_jalr_idx];
    wire [JALR_TAG_W-1:0] la_jr_tag   = jalr_tag  [la_jalr_idx];
    wire [BTB_TGT_W-1:0]  la_jr_tgt   = jalr_tgt  [la_jalr_idx];
    wire                  la_jr_needs_ras = jalr_needs_ras[la_jalr_idx];

    wire la_tag_match = (la_r_tag == la_tag);
    wire la_btb_hit_w = la_r_valid & la_tag_match;
    wire la_jr_hit     = la_jr_valid & (la_jr_tag == la_jalr_tag);
    wire la_jr_taken   = la_jr_hit & (~la_jr_needs_ras | la_ras_valid_next);

    wire [GHR_W-1:0] la_pht_idx = la_ghr_next ^ la_pc[9:2];
    wire [1:0]       la_pht_raw = pht[la_pht_idx];
    wire             la_pht_bypass = ex_pht_write & (ex_pht_idx == la_pht_idx);
    wire [1:0]       la_pht_val = la_pht_bypass ? ex_new_pht : la_pht_raw;

    wire [GHR_W-1:0] la_sel_idx = la_ghr_next;
    wire [1:0]       la_sel_raw = sel_table[la_sel_idx];
    wire             la_sel_bypass = ex_sel_write & (ex_sel_idx == la_sel_idx);
    wire [1:0]       la_sel_val = la_sel_bypass ? ex_new_sel : la_sel_raw;

    wire la_bp_taken_raw = la_r_valid & la_r_l0_taken & (~la_r_needs_ras | la_ras_valid_next);
    wire la_btb_taken = la_bp_taken_raw & la_tag_match;
    assign la_bp_taken = la_jr_taken | la_btb_taken;

    wire la_sel_jr_btb = la_jr_hit & ~la_jr_needs_ras;
    wire la_sel_jr_ras = la_jr_hit &  la_jr_needs_ras & la_ras_valid_next;
    wire la_sel_btb = ~la_jr_taken & la_btb_hit_w & ~la_r_needs_ras;
    wire la_sel_ras = ~la_jr_taken & la_btb_hit_w & la_r_l0_taken &  la_r_needs_ras & la_ras_valid_next;

    assign la_bp_target = ({32{la_sel_jr_btb}} & {la_jr_tgt, 2'b00})
                        | ({32{la_sel_jr_ras}} & la_ras_top_next)
                        | ({32{la_sel_btb}} & {la_r_tgt, 2'b00})
                        | ({32{la_sel_ras}} & la_ras_top_next);

    wire [11:0] la_jr_tgt_even_addr = btb_even_bank_addr(la_jr_tgt);
    wire [11:0] la_jr_tgt_odd_addr  = btb_odd_bank_addr(la_jr_tgt);
    wire [11:0] la_r_tgt_odd_addr  = btb_odd_bank_addr(la_r_tgt);
    wire [11:0] la_ras_even_addr   = full_even_bank_addr(la_ras_top_next);
    wire [11:0] la_ras_odd_addr    = full_odd_bank_addr(la_ras_top_next);

    assign la_bp_even_addr = ({12{la_sel_jr_btb}} & la_jr_tgt_even_addr)
                           | ({12{la_sel_jr_ras}} & la_ras_even_addr)
                           | ({12{la_sel_btb}} & la_r_even)
                           | ({12{la_sel_ras}} & la_ras_even_addr);
    assign la_bp_odd_addr = ({12{la_sel_jr_btb}} & la_jr_tgt_odd_addr)
                          | ({12{la_sel_jr_ras}} & la_ras_odd_addr)
                          | ({12{la_sel_btb}} & la_r_tgt_odd_addr)
                          | ({12{la_sel_ras}} & la_ras_odd_addr);
    assign la_bp_fetch_odd = (la_sel_jr_btb & la_jr_tgt[0])
                           | (la_sel_jr_ras & la_ras_top_next[2])
                           | (la_sel_btb & la_r_tgt[0])
                           | (la_sel_ras & la_ras_top_next[2]);

    assign la_bp_ghr_snap = la_ghr_next;
    assign la_bp_btb_hit  = la_btb_hit_w;
    assign la_bp_btb_type = la_btb_hit_w ? la_r_type : 2'b00;
    assign la_bp_btb_bht  = la_r_bht;
    assign la_bp_pht_cnt  = la_pht_val;
    assign la_bp_sel_cnt  = la_sel_val;

    // ================================================================
    //  Buffered-slot prediction
    // ================================================================

    wire [BTB_IDX_W-1:0] buf_idx = buf_pc[8:2];
    wire [BTB_TAG_W-1:0] buf_tag = buf_pc[13:9];
    wire [JALR_IDX_W-1:0] buf_jalr_idx = buf_pc[4:2];
    wire [JALR_TAG_W-1:0] buf_jalr_tag = buf_pc[13:5];

    // Do not bypass freshly resolved EX targets into the buffered-slot target
    // snapshot: that would recreate an EX-result -> frontend-register timing
    // path.  A same-edge BTB/JALR update missed here costs at most one stale
    // buffered prediction and is corrected by the normal EX redirect path.
    wire                 buf_r_valid = btb_valid[buf_idx];
    wire [BTB_TAG_W-1:0] buf_r_tag   = btb_tag  [buf_idx];
    wire [BTB_TGT_W-1:0] buf_r_tgt   = btb_tgt  [buf_idx];
    wire [11:0]          buf_r_even  = btb_even [buf_idx];
    wire [1:0]           buf_r_type  = btb_type [buf_idx];
    wire [1:0]           buf_r_bht   = btb_bht  [buf_idx];
    wire                 buf_r_l0_taken = btb_l0_taken[buf_idx];
    wire                 buf_r_needs_ras = btb_needs_ras[buf_idx];

    wire                  buf_jr_valid = jalr_valid[buf_jalr_idx];
    wire [JALR_TAG_W-1:0] buf_jr_tag   = jalr_tag  [buf_jalr_idx];
    wire [BTB_TGT_W-1:0]  buf_jr_tgt   = jalr_tgt  [buf_jalr_idx];
    wire                  buf_jr_needs_ras = jalr_needs_ras[buf_jalr_idx];

    wire buf_tag_match = (buf_r_tag == buf_tag);
    wire buf_btb_hit_w = buf_r_valid & buf_tag_match;
    wire buf_jr_hit     = buf_jr_valid & (buf_jr_tag == buf_jalr_tag);
    wire buf_jr_taken   = buf_jr_hit & (~buf_jr_needs_ras | la_ras_valid_next);

    wire [GHR_W-1:0] buf_pht_idx = la_ghr_next ^ buf_pc[9:2];
    wire [1:0]       buf_pht_raw = pht[buf_pht_idx];
    wire             buf_pht_bypass = ex_pht_write & (ex_pht_idx == buf_pht_idx);
    wire [1:0]       buf_pht_val = buf_pht_bypass ? ex_new_pht : buf_pht_raw;

    wire [GHR_W-1:0] buf_sel_idx = la_ghr_next;
    wire [1:0]       buf_sel_raw = sel_table[buf_sel_idx];
    wire             buf_sel_bypass = ex_sel_write & (ex_sel_idx == buf_sel_idx);
    wire [1:0]       buf_sel_val = buf_sel_bypass ? ex_new_sel : buf_sel_raw;

    wire buf_bp_taken_raw = buf_r_valid & buf_r_l0_taken & (~buf_r_needs_ras | la_ras_valid_next);
    wire buf_btb_taken = buf_bp_taken_raw & buf_tag_match;
    assign buf_bp_taken = buf_jr_taken | buf_btb_taken;

    wire buf_sel_jr_btb = buf_jr_hit & ~buf_jr_needs_ras;
    wire buf_sel_jr_ras = buf_jr_hit &  buf_jr_needs_ras & la_ras_valid_next;
    wire buf_sel_btb = ~buf_jr_taken & buf_btb_hit_w & ~buf_r_needs_ras;
    wire buf_sel_ras = ~buf_jr_taken & buf_btb_hit_w & buf_r_l0_taken &  buf_r_needs_ras & la_ras_valid_next;

    assign buf_bp_target = ({32{buf_sel_jr_btb}} & {buf_jr_tgt, 2'b00})
                         | ({32{buf_sel_jr_ras}} & la_ras_top_next)
                         | ({32{buf_sel_btb}} & {buf_r_tgt, 2'b00})
                         | ({32{buf_sel_ras}} & la_ras_top_next);

    wire [11:0] buf_jr_tgt_even_addr = btb_even_bank_addr(buf_jr_tgt);
    wire [11:0] buf_jr_tgt_odd_addr  = btb_odd_bank_addr(buf_jr_tgt);
    wire [11:0] buf_r_tgt_odd_addr   = btb_odd_bank_addr(buf_r_tgt);
    wire [11:0] buf_ras_even_addr    = full_even_bank_addr(la_ras_top_next);
    wire [11:0] buf_ras_odd_addr     = full_odd_bank_addr(la_ras_top_next);

    assign buf_bp_even_addr = ({12{buf_sel_jr_btb}} & buf_jr_tgt_even_addr)
                            | ({12{buf_sel_jr_ras}} & buf_ras_even_addr)
                            | ({12{buf_sel_btb}} & buf_r_even)
                            | ({12{buf_sel_ras}} & buf_ras_even_addr);
    assign buf_bp_odd_addr = ({12{buf_sel_jr_btb}} & buf_jr_tgt_odd_addr)
                           | ({12{buf_sel_jr_ras}} & buf_ras_odd_addr)
                           | ({12{buf_sel_btb}} & buf_r_tgt_odd_addr)
                           | ({12{buf_sel_ras}} & buf_ras_odd_addr);
    assign buf_bp_fetch_odd = (buf_sel_jr_btb & buf_jr_tgt[0])
                            | (buf_sel_jr_ras & la_ras_top_next[2])
                            | (buf_sel_btb & buf_r_tgt[0])
                            | (buf_sel_ras & la_ras_top_next[2]);

    assign buf_bp_ghr_snap = la_ghr_next;
    assign buf_bp_btb_hit  = buf_btb_hit_w;
    assign buf_bp_btb_type = buf_btb_hit_w ? buf_r_type : 2'b00;
    assign buf_bp_btb_bht  = buf_r_bht;
    assign buf_bp_pht_cnt  = buf_pht_val;
    assign buf_bp_sel_cnt  = buf_sel_val;

    // ================================================================
    //  Sequential update (all at posedge clk)
    // ================================================================

    // ---- BTB: direct-mapped, all LUTRAM (no reset) ----
    // Cold-start safe: uninitialized valid may cause wrong predictions,
    // but branch_unit will detect misprediction and flush → functionally correct.
    // Same pattern as PHT and selector.
    initial begin
        for (int i = 0; i < BTB_ENTRIES; i++) begin
            btb_valid[i] = 1'b0;
            btb_l0_taken[i] = 1'b0;
            btb_needs_ras[i] = 1'b0;
        end
    end
    always_ff @(posedge clk) begin
        if (ex_btb_write) begin
            btb_valid[ex_idx] <= 1'b1;
            btb_tag  [ex_idx] <= ex_tag;
            btb_tgt  [ex_idx] <= ex_wr_tgt;
            btb_even [ex_idx] <= ex_wr_even;
            btb_p4_even [ex_idx] <= ex_wr_p4_even;
            btb_p8_even [ex_idx] <= ex_wr_p8_even;
            btb_p12_even[ex_idx] <= ex_wr_p12_even;
            btb_type [ex_idx] <= ex_wr_type;
            btb_bht  [ex_idx] <= ex_wr_bht;
            btb_l0_taken[ex_idx] <= ex_wr_l0_taken;
            btb_needs_ras[ex_idx] <= ex_wr_needs_ras;
        end
    end

    // ---- x5 JALR sidecar ----
    initial begin
        for (int i = 0; i < JALR_ENTRIES; i++) begin
            jalr_valid[i] = 1'b0;
            jalr_needs_ras[i] = 1'b0;
        end
    end
    always_ff @(posedge clk) begin
        if (ex_jalr_side_write) begin
            jalr_valid[ex_jalr_idx] <= 1'b1;
            jalr_tag  [ex_jalr_idx] <= ex_jalr_tag;
            jalr_tgt  [ex_jalr_idx] <= ex_wr_tgt;
            jalr_even [ex_jalr_idx] <= ex_wr_even;
            jalr_p4_even [ex_jalr_idx] <= ex_wr_p4_even;
            jalr_p8_even [ex_jalr_idx] <= ex_wr_p8_even;
            jalr_p12_even[ex_jalr_idx] <= ex_wr_p12_even;
            jalr_needs_ras[ex_jalr_idx] <= ex_is_ret;
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
