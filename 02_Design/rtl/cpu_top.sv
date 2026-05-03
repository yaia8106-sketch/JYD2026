// ============================================================
// Module: cpu_top
// Description: RV32I 5-stage pipeline processor top-level
// Rule: WIRING ONLY — no logic, no assign expressions with operators
// IROM: 外部例化，通过端口访问
// DRAM: 通过 DCache 访问（student_top 中例化）
// Branch Prediction: Tournament (BTB+GShare+Selector+RAS)
// ============================================================

module cpu_top (
    input  logic        clk,
    input  logic        rst_n,

    // IROM 接口 (IF stage)
    output logic [31:0] irom_addr,       // = next_pc（预取，IF 阶段）
    input  logic [63:0] irom_data,       // 64-bit fetch window (Phase 0 uses low 32-bit inst0)

    // DCache 接口 (EX → MEM stage)
    output logic        cache_req,       // EX stage: 有访存请求
    output logic        cache_wr,        // EX stage: 0=load, 1=store
    output logic [31:0] cache_addr,      // EX stage: 访存地址
    output logic [ 3:0] cache_wea,       // EX stage: 字节写使能
    output logic [31:0] cache_wdata,     // EX stage: 写数据
    input  logic [31:0] cache_rdata,     // MEM stage: 读数据 (from DCache)
    input  logic        cache_ready,     // MEM stage: 命中或完成
    output logic        cache_flush,     // MEM stage: pipeline flush (abort refill)
    output logic        cache_pipeline_stall, // DCache sync: ~mem_allowin

    // MMIO 接口 (保留原有 perip 风格)
    output logic [31:0] mmio_addr,       // EX stage: 地址
    output logic [31:0] mmio_wr_addr,    // MEM stage: 写地址
    output logic [ 3:0] mmio_wea,        // MEM stage: 写使能
    output logic [31:0] mmio_wdata,      // MEM stage: 写数据
    input  logic [31:0] mmio_rdata       // MEM stage: 读数据
);

    // ================================================================
    //  Internal wires
    // ================================================================

    // ---- PC & IF ----
    wire [31:0] pc;
    // next_pc eliminated: inlined into irom_addr for 1 fewer LUT level on PC→IROM path
    wire        if_valid;

    // 250MHz: Pre-computed PC+4 register — eliminates carry chain from irom_addr default path
    // Each branch computes +4 independently from its registered source (no irom_addr feedback)
    logic [31:0] pc_plus4;

    // ---- IF/ID ----
    wire        id_valid;
    wire        id_allowin;
    wire        id_ready_go;
    wire [31:0] id_pc;
    wire [31:0] id_inst;           // registered instruction from IF/ID
    wire [31:0] id_inst1;          // registered slot1 candidate instruction
    wire        id_s1_valid;       // Phase 1: always 0 (slot1 not issued)

    // ---- IROM ----
    wire [31:0] irom_inst0;        // Phase 0: low 32-bit instruction from 64-bit IROM data
    wire [31:0] irom_inst1;        // Phase 1: high 32-bit instruction from 64-bit IROM data

    // ---- Decoder outputs ----
    wire [ 3:0] dec_alu_op;
    wire [ 1:0] dec_alu_src1_sel;
    wire        dec_alu_src2_sel;
    wire        dec_reg_write_en;
    wire [ 1:0] dec_wb_sel;
    wire        dec_mem_read_en;
    wire        dec_mem_write_en;
    wire [ 1:0] dec_mem_size;
    wire        dec_mem_unsigned;
    wire        dec_is_branch;
    wire [ 2:0] dec_branch_cond;
    wire        dec_is_jal;
    wire        dec_is_jalr;
    wire [ 2:0] dec_imm_type;

    // ---- Slot 1 decoder outputs (decoded but not issued in Phase 1) ----
    wire [ 3:0] dec1_alu_op;
    wire [ 1:0] dec1_alu_src1_sel;
    wire        dec1_alu_src2_sel;
    wire        dec1_reg_write_en;
    wire [ 1:0] dec1_wb_sel;
    wire        dec1_mem_read_en;
    wire        dec1_mem_write_en;
    wire [ 1:0] dec1_mem_size;
    wire        dec1_mem_unsigned;
    wire        dec1_is_branch;
    wire [ 2:0] dec1_branch_cond;
    wire        dec1_is_jal;
    wire        dec1_is_jalr;
    wire [ 2:0] dec1_imm_type;

    // ---- Immediate ----
    wire [31:0] id_imm;

    // ---- Regfile ----
    wire [31:0] rf_rs1_data;
    wire [31:0] rf_rs2_data;

    // ---- Forwarding ----
    wire [31:0] fwd_rs1_data;
    wire [31:0] fwd_rs2_data;

    // ---- ALU src MUX (in ID stage) ----
    wire [31:0] id_alu_src1;
    wire [31:0] id_alu_src2;

    // ---- ID/EX ----
    wire        ex_valid;
    wire        ex_allowin;
    wire [31:0] ex_pc;
    wire [31:0] ex_alu_src1, ex_alu_src2;   // pre-selected in ID
    wire [31:0] ex_rs1_data, ex_rs2_data;   // raw, for branch/store
    wire [ 4:0] ex_rd, ex_rs1_addr, ex_rs2_addr;
    wire [ 3:0] ex_alu_op;
    wire        ex_reg_write_en;
    wire [ 1:0] ex_wb_sel;
    wire        ex_mem_read_en;
    wire        ex_mem_write_en;
    wire [ 1:0] ex_mem_size;
    wire        ex_mem_unsigned;
    wire        ex_is_branch;
    wire [ 2:0] ex_branch_cond;
    wire        ex_is_jal;
    wire        ex_is_jalr;

    // ---- Slot 1 shadow pipeline (valid stays 0 in Phase 1) ----
    wire        ex_s1_valid;
    wire [31:0] ex_s1_pc;
    wire [31:0] ex_s1_inst;
    wire [ 4:0] ex_s1_rd, ex_s1_rs1_addr, ex_s1_rs2_addr;
    wire [ 3:0] ex_s1_alu_op;
    wire        ex_s1_reg_write_en;
    wire [ 1:0] ex_s1_wb_sel;
    wire        ex_s1_mem_read_en;
    wire        ex_s1_mem_write_en;
    wire [ 1:0] ex_s1_mem_size;
    wire        ex_s1_mem_unsigned;
    wire        ex_s1_is_branch;
    wire [ 2:0] ex_s1_branch_cond;
    wire        ex_s1_is_jal;
    wire        ex_s1_is_jalr;

    // ---- ALU ----
    wire [31:0] alu_result;
    wire [31:0] alu_sum;               // ALU 加法器直出（跳过 output MUX）
    wire [31:0] alu_addr;              // FIX-A: 独立地址加法器（不依赖 alu_op）

    // ---- Branch ----
    wire        branch_flush;          // EX stage combinational (for predictor update)
    wire [31:0] branch_target;         // EX stage combinational
    wire        actual_taken;          // for predictor update
    wire [31:0] actual_target;         // for predictor update

    // ---- Registered branch flush (MEM stage, for 250MHz timing) ----
    wire        mem_branch_flush;      // branch_flush delayed 1 cycle (from EX/MEM reg)
    wire [31:0] mem_branch_target;     // branch_target delayed 1 cycle (from EX/MEM reg)

    // ---- Store interface (EX stage) ----
    wire [31:0] store_data_shifted;

    // ---- Memory interface ----
    wire [ 3:0] dram_wea;
    wire [31:0] mem_load_data;         // MEM stage: from cache (cacheable) or mmio (uncacheable)
    wire        is_cacheable;          // EX stage: addr in DRAM range

    // ---- EX pre-computed ----
    wire [31:0] ex_pc_plus_4 = ex_pc + 32'd4;  // pre-compute for forwarding & WB

    // ---- EX/MEM ----
    wire        mem_valid;
    wire        mem_allowin;
    wire [31:0] mem_alu_result;
    wire [31:0] mem_pc;
    wire [31:0] mem_pc_plus_4;
    wire [ 4:0] mem_rd;
    wire        mem_reg_write_en;
    wire [ 1:0] mem_wb_sel;
    wire        mem_mem_read_en;
    wire [ 1:0] mem_mem_size;
    wire        mem_mem_unsigned;
    wire [ 3:0] mem_store_wea;         // FIX-C: registered store WEA
    wire [31:0] mem_store_data;        // FIX-C: registered store data

    // ---- Slot 1 shadow MEM ----
    wire        mem_s1_valid;
    wire [31:0] mem_s1_pc;
    wire [31:0] mem_s1_inst;
    wire [ 4:0] mem_s1_rd;
    wire        mem_s1_reg_write_en;
    wire [ 1:0] mem_s1_wb_sel;

    // ---- MEM/WB ----
    wire        wb_valid;
    wire        wb_allowin;
    wire [31:0] wb_alu_result;
    wire [31:0] wb_pc_plus_4;
    wire [ 4:0] wb_rd;
    wire        wb_reg_write_en;
    wire [ 1:0] wb_wb_sel;
    wire        wb_is_load;
    wire [ 1:0] wb_mem_size;
    wire        wb_mem_unsigned;
    wire [ 1:0] wb_addr_low;
    wire [31:0] wb_load_rdata;  // registered cache/mmio output (captured in MEM/WB)

    // ---- Slot 1 shadow WB ----
    wire        wb_s1_valid;
    wire [31:0] wb_s1_pc;
    wire [31:0] wb_s1_inst;
    wire [ 4:0] wb_s1_rd;
    wire        wb_s1_reg_write_en;
    wire [ 1:0] wb_s1_wb_sel;

    // ---- WB ----
    wire [31:0] wb_load_data;
    wire [31:0] wb_write_data;

    // MEM-stage cacheable flag (registered from EX via EX/MEM reg)
    wire is_cacheable_mem;

    // ---- Handshake ----
    wire if_ready_go_w  = 1'b1;     // BRAM latency absorbed by pipeline
    // Non-cacheable store-load hazard: EX load + MEM store to same DRAM word (MMIO path)
    // DCache handles cacheable RAW, but MMIO path has no forwarding — stall 1 cycle.
    //
    // 250MHz: Conservative check using ONLY registered signals (no ALU dependency).
    // Removes ~is_cacheable and address comparison to break the critical path:
    //   ALU→is_cacheable→ex_ready_go→ex_allowin→id_allowin→irom_addr→IROM
    // False positives: EX has any load + MEM has MMIO store → extra 1-cycle stall (very rare).
    wire mmio_st_ld_hazard = ex_mem_read_en &
                             mem_valid & (|mem_store_wea) & ~is_cacheable_mem;
    wire ex_ready_go_w  = ~mmio_st_ld_hazard;
    wire mem_ready_go_w = cache_ready; // DCache controls MEM stage flow
    assign cache_flush = mem_branch_flush; // Abort wrong-path refill on branch misprediction
    assign cache_pipeline_stall = ~mem_allowin; // sync DCache EX→MEM with cpu pipeline

    // ---- Flush (250MHz: uses registered mem_branch_flush instead of combinational branch_flush) ----
    wire id_bp_redirect;            // NLP: ID-stage Tournament redirect
    wire id_flush = mem_branch_flush | id_bp_redirect;
    wire ex_flush = mem_branch_flush;   // 250MHz: flush EX on MEM mispredict only

    // ---- Register addresses from instruction (ID stage, from IF/ID reg) ----
    wire [4:0] id_rs1_addr = id_inst[19:15];
    wire [4:0] id_rs2_addr = id_inst[24:20];
    wire [4:0] id_rd_addr  = id_inst[11:7];
    wire [4:0] id_s1_rs1_addr = id_inst1[19:15];
    wire [4:0] id_s1_rs2_addr = id_inst1[24:20];
    wire [4:0] id_s1_rd_addr  = id_inst1[11:7];
    wire [31:0] id_s1_pc = id_pc + 32'd4;

    // ---- Cacheable判定 (EX stage, 1 LUT) ----
    // DRAM区域: 0x8010_0000 ~ 0x8013_FFFF → addr[20]=1, addr[21]=0, addr[19:18]=00
    assign is_cacheable = alu_addr[20] & ~alu_addr[21] & ~alu_addr[19] & ~alu_addr[18];

    // ---- DCache 端口 (EX stage) ----
    // Only cacheable (DRAM) accesses go through DCache; MMIO bypasses
    // Gate with ~mem_branch_flush to prevent wrong-path instructions from
    // triggering DCache requests (wrong-path enters EX one cycle after branch resolves).
    // NOTE: Do NOT gate with ~branch_flush — the EX-stage instruction that generates
    // branch_flush is the instruction that *detected* the misprediction (e.g., a load
    // with a false BTB hit). It is NOT wrong-path and its DCache request must proceed.
    assign cache_req   = ex_valid & ~mem_branch_flush & (ex_mem_read_en | ex_mem_write_en) & is_cacheable;
    assign cache_wr    = ex_mem_write_en;
    assign cache_addr  = alu_addr;
    assign cache_wea   = dram_wea;               // from mem_interface (EX stage)
    assign cache_wdata = store_data_shifted;      // from mem_interface (EX stage)

    // ---- MMIO 端口 ----
    assign mmio_addr    = alu_addr;               // EX stage: 读地址
    assign mmio_wr_addr = mem_alu_result;          // MEM stage: 写地址（已打拍）
    assign mmio_wea     = (mem_valid & ~is_cacheable_mem) ? mem_store_wea : 4'b0000;
    assign mmio_wdata   = mem_store_data;          // MEM stage: 写数据（已打拍）

    // MEM-stage load data: mux between cache and MMIO
    assign mem_load_data = is_cacheable_mem ? cache_rdata : mmio_rdata;

    // ================================================================
    //  Branch prediction wires
    // ================================================================

    // IF stage prediction outputs (L0: fast path)
    wire        bp_taken;
    wire [31:0] bp_target;
    wire [ 7:0] bp_ghr_snap;
    wire        bp_btb_hit;
    wire [ 1:0] bp_btb_type;    // NLP: entry type for ID verification
    wire [ 1:0] bp_btb_bht;
    wire [ 1:0] bp_pht_cnt;
    wire [ 1:0] bp_sel_cnt;

    // ID stage prediction (from IF/ID reg)
    wire        id_bp_taken;
    wire [31:0] id_bp_target;
    wire [ 7:0] id_bp_ghr_snap;
    wire        id_bp_btb_hit;
    wire [ 1:0] id_bp_btb_type; // NLP: entry type for ID verification
    wire [ 1:0] id_bp_btb_bht;
    wire [ 1:0] id_bp_pht_cnt;
    wire [ 1:0] id_bp_sel_cnt;

    // EX stage prediction (from ID/EX reg)
    wire        ex_bp_taken;
    wire [31:0] ex_bp_target;
    wire [ 7:0] ex_bp_ghr_snap;
    wire        ex_bp_btb_hit;
    wire [ 1:0] ex_bp_btb_bht;
    wire [ 1:0] ex_bp_pht_cnt;
    wire [ 1:0] ex_bp_sel_cnt;

    // ================================================================
    //  Module instantiations
    // ================================================================

    // ==================== Branch Predictor ====================

    branch_predictor u_bp (
        .clk             (clk),
        .rst_n           (rst_n),

        // IF prediction (L0: fast path)
        .if_pc           (pc),
        .bp_taken        (bp_taken),
        .bp_target       (bp_target),
        .bp_ghr_snap     (bp_ghr_snap),
        .bp_btb_hit      (bp_btb_hit),
        .bp_btb_type     (bp_btb_type),     // NLP
        .bp_btb_bht      (bp_btb_bht),
        .bp_pht_cnt      (bp_pht_cnt),
        .bp_sel_cnt      (bp_sel_cnt),

        // EX update
        // 250MHz: gate ex_valid with ~mem_branch_flush to prevent wrong-path
        // instructions (that entered EX before registered flush) from corrupting
        // predictor state (GHR, PHT, BTB, selector)
        .ex_valid        (ex_valid & ~mem_branch_flush),
        .ex_pc           (ex_pc),
        .ex_is_branch    (ex_is_branch),
        .ex_is_jal       (ex_is_jal),
        .ex_is_jalr      (ex_is_jalr),
        .ex_rd           (ex_rd),
        .ex_rs1_addr     (ex_rs1_addr),
        .ex_actual_taken (actual_taken),
        .ex_actual_target(actual_target),
        .ex_ghr_snap     (ex_bp_ghr_snap),
        .ex_btb_hit      (ex_bp_btb_hit),
        .ex_btb_bht      (ex_bp_btb_bht),
        .ex_pht_cnt      (ex_bp_pht_cnt),
        .ex_sel_cnt      (ex_bp_sel_cnt)
    );

    // ==================== Pre-IF ====================

    wire        if_allowin_w = id_allowin;   // for irom_addr mux
    wire        can_dual_issue = 1'b0;       // Phase 1: fetch two, issue slot0 only
    wire [31:0] seq_pc_step = can_dual_issue ? 32'd8 : 32'd4;

    // NLP: ID-stage Tournament verification (L1)
    // Compares L0 (Bimodal bht[1], used in IF) with L1 (Tournament, computed here)
    wire id_bimodal_taken  = (id_bp_btb_bht >= 2'd2);   // = bht[1]
    wire id_gshare_taken   = (id_bp_pht_cnt >= 2'd2);
    wire id_use_bimodal    = (id_bp_sel_cnt >= 2'd2);
    wire id_tournament_taken = id_use_bimodal ? id_bimodal_taken : id_gshare_taken;

    // NLP redirect: L0 and L1 disagree on BRANCH direction
    // Split into raw (fast, for IROM addr) and gated (safe, for flush control):
    //
    // id_bp_redirect_raw: condition-only, no stall gating → fast path for irom_addr.
    //   Stall no longer sits on the IROM address MUX; the instruction hold
    //   register below preserves the correct BRAM output across stalls.
    //
    // id_bp_redirect: adds id_ready_go & ex_allowin gating → controls id_flush
    //   Ensures the branch instruction actually transfers to EX before flushing IF/ID.
    wire id_bp_redirect_raw = id_valid & ~mem_branch_flush
                            & id_bp_btb_hit
                            & (id_bp_btb_type == 2'b10)    // TYPE_BRANCH
                            & (id_bp_btb_bht[1] != id_tournament_taken);

    assign id_bp_redirect = id_bp_redirect_raw & id_ready_go & ex_allowin;

    // Redirect target: if Tournament says taken → use BTB target;
    //                  if Tournament says not-taken → use PC+4
    wire [31:0] id_redirect_target = id_tournament_taken ? id_bp_target
                                                         : (id_pc + 32'd4);

    // 250MHz: irom_addr = flat 4-way priority MUX (stall branch removed)
    // Priority: flush > NLP redirect > L0 prediction > sequential
    //   - stall handling moved to irom_data_held register (see below)
    //   - removes allowin chain (cache_ready→mem→ex→id) from IROM critical path
    //   - redirect uses raw version (no id_ready_go/ex_allowin gating)
    //   - bp_taken/bp_target inlined (no next_pc intermediate)
    assign irom_addr = mem_branch_flush    ? mem_branch_target :  // MEM flush (highest, registered)
                       id_bp_redirect_raw  ? id_redirect_target : // NLP: ID redirect (raw, fast)
                       bp_taken            ? bp_target :          // L0 预测 taken
                                             pc_plus4;           // 顺序取指（pre-registered, no carry chain）

    // pc_plus4: mirrors irom_addr MUX priority, each branch adds +4 from its registered source
    // Invariant: when irom_addr selects pc_plus4 (default), pc_plus4 == pc + 4
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc_plus4 <= 32'h8000_0000;              // reset PC (0x7FFFFFFC) + 4
        else if (mem_branch_flush)
            pc_plus4 <= mem_branch_target + 32'd4;  // flush: registered source
        else if (!if_allowin_w)
            ;                                       // stall: hold
        else if (id_bp_redirect_raw)
            pc_plus4 <= id_redirect_target + 32'd4; // NLP redirect: IF/ID regs
        else if (bp_taken)
            pc_plus4 <= bp_target + 32'd4;          // L0 prediction: LUTRAM
        else
            pc_plus4 <= pc_plus4 + seq_pc_step;     // Phase 1 still resolves to +4
    end

    pc_reg u_pc_reg (
        .clk           (clk),
        .rst_n         (rst_n),
        .if_allowin    (id_allowin),    // simplified: if_valid=1, if_ready_go=1
        .if_valid      (if_valid),
        .branch_flush  (mem_branch_flush),   // 250MHz: registered flush from MEM
        .branch_target (mem_branch_target),  // 250MHz: registered target from MEM
        .next_pc       (irom_addr),
        .pc            (pc)
    );

    // ==================== IROM: 外部例化，通过 irom_addr/irom_data 端口 ====================

    assign irom_inst0 = irom_data[31:0];
    assign irom_inst1 = irom_data[63:32];

    // ==================== Instruction buffer ====================
    // Single issue leaves the fetched slot1 instruction for the next cycle.
    logic [31:0] inst_buf;
    logic        inst_buf_valid;
    wire         if_accept = if_valid & if_ready_go_w & id_allowin;

    // ==================== Instruction hold register ====================
    // When pipeline stalls (id_allowin=0), BRAM output may change (irom_addr
    // no longer holds pc). Capture the correct instruction on stall entry
    // so IF/ID can use it when the stall ends.
    logic [31:0] irom_inst0_held;
    logic [31:0] irom_inst1_held;
    logic        irom_held_valid;

    wire [31:0] if_inst0_live = inst_buf_valid ? inst_buf : irom_inst0;
    wire [31:0] if_inst1_live = irom_inst1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irom_held_valid <= 1'b0;
        else if (id_flush | id_allowin)           // flush or not stalling: clear
            irom_held_valid <= 1'b0;
        else if (!irom_held_valid)                // entering stall: mark
            irom_held_valid <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (!irom_held_valid && !id_allowin && !id_flush) begin
            irom_inst0_held <= if_inst0_live;
            irom_inst1_held <= if_inst1_live;
        end
    end

    wire [31:0] if_inst0_out = irom_held_valid ? irom_inst0_held : if_inst0_live;
    wire [31:0] if_inst1_out = irom_held_valid ? irom_inst1_held : if_inst1_live;
    wire        if_s1_valid  = can_dual_issue;
    wire        if_sequential_fetch = ~mem_branch_flush & ~id_bp_redirect_raw & ~bp_taken;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inst_buf_valid <= 1'b0;
            inst_buf       <= 32'd0;
        end else if (id_flush | bp_taken | id_bp_redirect_raw) begin
            inst_buf_valid <= 1'b0;
        end else if (if_accept) begin
            inst_buf_valid <= (pc != 32'h7FFF_FFFC) & ~can_dual_issue & if_sequential_fetch;
            inst_buf       <= if_inst1_out;
        end
    end

    // ==================== IF/ID ====================

    if_id_reg u_if_id_reg (
        .clk          (clk),
        .rst_n        (rst_n),
        .if_valid     (if_valid),
        .if_ready_go  (if_ready_go_w),
        .id_allowin   (id_allowin),
        .id_valid     (id_valid),
        .id_ready_go  (id_ready_go),
        .ex_allowin   (ex_allowin),
        .id_flush     (id_flush),
        .if_pc        (pc),
        .if_inst      (if_inst0_out),    // held, buffered, or live BRAM output
        .if_inst1     (if_inst1_out),
        .if_s1_valid  (if_s1_valid),
        .id_pc        (id_pc),
        .id_inst      (id_inst),         // registered instruction for ID
        .id_inst1     (id_inst1),
        .id_s1_valid  (id_s1_valid),
        // Branch prediction passthrough
        .if_bp_taken    (bp_taken),
        .if_bp_target   (bp_target),
        .if_bp_ghr_snap (bp_ghr_snap),
        .if_bp_btb_hit  (bp_btb_hit),
        .if_bp_btb_type (bp_btb_type),     // NLP: type for ID verification
        .if_bp_btb_bht  (bp_btb_bht),
        .if_bp_pht_cnt  (bp_pht_cnt),
        .if_bp_sel_cnt  (bp_sel_cnt),
        .id_bp_taken    (id_bp_taken),
        .id_bp_target   (id_bp_target),
        .id_bp_ghr_snap (id_bp_ghr_snap),
        .id_bp_btb_hit  (id_bp_btb_hit),
        .id_bp_btb_type (id_bp_btb_type),  // NLP: type for ID verification
        .id_bp_btb_bht  (id_bp_btb_bht),
        .id_bp_pht_cnt  (id_bp_pht_cnt),
        .id_bp_sel_cnt  (id_bp_sel_cnt)
    );

    decoder u_decoder (
        .inst           (id_inst),            // from IF/ID register
        .alu_op         (dec_alu_op),
        .alu_src1_sel   (dec_alu_src1_sel),
        .alu_src2_sel   (dec_alu_src2_sel),
        .reg_write_en   (dec_reg_write_en),
        .wb_sel         (dec_wb_sel),
        .mem_read_en    (dec_mem_read_en),
        .mem_write_en   (dec_mem_write_en),
        .mem_size       (dec_mem_size),
        .mem_unsigned   (dec_mem_unsigned),
        .is_branch      (dec_is_branch),
        .branch_cond    (dec_branch_cond),
        .is_jal         (dec_is_jal),
        .is_jalr        (dec_is_jalr),
        .imm_type       (dec_imm_type)
    );

    decoder u_decoder_s1 (
        .inst           (id_inst1),
        .alu_op         (dec1_alu_op),
        .alu_src1_sel   (dec1_alu_src1_sel),
        .alu_src2_sel   (dec1_alu_src2_sel),
        .reg_write_en   (dec1_reg_write_en),
        .wb_sel         (dec1_wb_sel),
        .mem_read_en    (dec1_mem_read_en),
        .mem_write_en   (dec1_mem_write_en),
        .mem_size       (dec1_mem_size),
        .mem_unsigned   (dec1_mem_unsigned),
        .is_branch      (dec1_is_branch),
        .branch_cond    (dec1_branch_cond),
        .is_jal         (dec1_is_jal),
        .is_jalr        (dec1_is_jalr),
        .imm_type       (dec1_imm_type)
    );

    imm_gen u_imm_gen (
        .inst     (id_inst),                   // from IF/ID register
        .imm_type (dec_imm_type),
        .imm      (id_imm)
    );

    regfile u_regfile (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (id_rs1_addr),
        .rs2_addr (id_rs2_addr),
        .rs1_data (rf_rs1_data),
        .rs2_data (rf_rs2_data),
        .rd_addr  (wb_rd),
        .rd_data  (wb_write_data),
        .rd_wen   (wb_reg_write_en),
        .rd_valid (wb_valid)
    );

    forwarding u_forwarding (
        .id_rs1_addr    (id_rs1_addr),
        .id_rs2_addr    (id_rs2_addr),
        .rf_rs1_data    (rf_rs1_data),
        .rf_rs2_data    (rf_rs2_data),
        .ex_valid       (ex_valid),
        .ex_reg_write   (ex_reg_write_en),
        .ex_mem_read    (ex_mem_read_en),
        .ex_rd          (ex_rd),
        .ex_alu_result  (alu_result),
        .ex_pc_plus_4   (ex_pc_plus_4),
        .ex_wb_sel      (ex_wb_sel),
        .mem_valid      (mem_valid),
        .mem_reg_write  (mem_reg_write_en),
        .mem_is_load    (mem_mem_read_en),
        .mem_rd         (mem_rd),
        .mem_alu_result (mem_alu_result),
        .mem_pc_plus_4  (mem_pc_plus_4),
        .mem_wb_sel     (mem_wb_sel),
        .wb_valid       (wb_valid),
        .wb_reg_write   (wb_reg_write_en),
        .wb_rd          (wb_rd),
        .wb_write_data  (wb_write_data),
        .id_rs1_data    (fwd_rs1_data),
        .id_rs2_data    (fwd_rs2_data),
        .id_ready_go    (id_ready_go)
    );

    // ALU operand selection (in ID stage to reduce EX critical path)
    alu_src_mux u_alu_src_mux (
        .rs1_data      (fwd_rs1_data),
        .rs2_data      (fwd_rs2_data),
        .pc            (id_pc),
        .imm           (id_imm),
        .alu_src1_sel  (dec_alu_src1_sel),
        .alu_src2_sel  (dec_alu_src2_sel),
        .alu_src1      (id_alu_src1),
        .alu_src2      (id_alu_src2)
    );

    // ==================== ID/EX ====================

    id_ex_reg u_id_ex_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .id_valid         (id_valid),
        .id_ready_go      (id_ready_go),
        .ex_allowin       (ex_allowin),
        .ex_valid         (ex_valid),
        .ex_ready_go      (ex_ready_go_w),
        .mem_allowin      (mem_allowin),
        .ex_flush         (ex_flush),
        .id_pc            (id_pc),
        .id_alu_src1      (id_alu_src1),
        .id_alu_src2      (id_alu_src2),
        .id_rs1_data      (fwd_rs1_data),
        .id_rs2_data      (fwd_rs2_data),
        .id_rd            (id_rd_addr),
        .id_rs1_addr      (id_rs1_addr),
        .id_rs2_addr      (id_rs2_addr),
        .id_alu_op        (dec_alu_op),
        .id_reg_write_en  (dec_reg_write_en),
        .id_wb_sel        (dec_wb_sel),
        .id_mem_read_en   (dec_mem_read_en),
        .id_mem_write_en  (dec_mem_write_en),
        .id_mem_size      (dec_mem_size),
        .id_mem_unsigned  (dec_mem_unsigned),
        .id_is_branch     (dec_is_branch),
        .id_branch_cond   (dec_branch_cond),
        .id_is_jal        (dec_is_jal),
        .id_is_jalr       (dec_is_jalr),
        // Branch prediction passthrough (NLP: corrected by Tournament in ID)
        // When ID redirect fires, override L0's prediction with Tournament's result
        // so EX stage sees the corrected prediction for misprediction detection
        .id_bp_taken      (id_bp_redirect ? id_tournament_taken : id_bp_taken),
        .id_bp_target     (id_bp_redirect ? id_redirect_target  : id_bp_target),
        .id_bp_ghr_snap   (id_bp_ghr_snap),
        .id_bp_btb_hit    (id_bp_btb_hit),
        .id_bp_btb_bht    (id_bp_btb_bht),
        .id_bp_pht_cnt    (id_bp_pht_cnt),
        .id_bp_sel_cnt    (id_bp_sel_cnt),
        .ex_pc            (ex_pc),
        .ex_alu_src1      (ex_alu_src1),
        .ex_alu_src2      (ex_alu_src2),
        .ex_rs1_data      (ex_rs1_data),
        .ex_rs2_data      (ex_rs2_data),
        .ex_rd            (ex_rd),
        .ex_rs1_addr      (ex_rs1_addr),
        .ex_rs2_addr      (ex_rs2_addr),
        .ex_alu_op        (ex_alu_op),
        .ex_reg_write_en  (ex_reg_write_en),
        .ex_wb_sel        (ex_wb_sel),
        .ex_mem_read_en   (ex_mem_read_en),
        .ex_mem_write_en  (ex_mem_write_en),
        .ex_mem_size      (ex_mem_size),
        .ex_mem_unsigned  (ex_mem_unsigned),
        .ex_is_branch     (ex_is_branch),
        .ex_branch_cond   (ex_branch_cond),
        .ex_is_jal        (ex_is_jal),
        .ex_is_jalr       (ex_is_jalr),
        // Branch prediction out (NLP: removed btb_way)
        .ex_bp_taken      (ex_bp_taken),
        .ex_bp_target     (ex_bp_target),
        .ex_bp_ghr_snap   (ex_bp_ghr_snap),
        .ex_bp_btb_hit    (ex_bp_btb_hit),
        .ex_bp_btb_bht    (ex_bp_btb_bht),
        .ex_bp_pht_cnt    (ex_bp_pht_cnt),
        .ex_bp_sel_cnt    (ex_bp_sel_cnt)
    );

    id_ex_reg_s1 u_id_ex_reg_s1 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .id_s1_valid         (id_s1_valid),
        .id_ready_go         (id_ready_go),
        .ex_allowin          (ex_allowin),
        .ex_flush            (ex_flush),
        .id_pc               (id_s1_pc),
        .id_inst             (id_inst1),
        .id_rd               (id_s1_rd_addr),
        .id_rs1_addr         (id_s1_rs1_addr),
        .id_rs2_addr         (id_s1_rs2_addr),
        .id_alu_op           (dec1_alu_op),
        .id_reg_write_en     (dec1_reg_write_en),
        .id_wb_sel           (dec1_wb_sel),
        .id_mem_read_en      (dec1_mem_read_en),
        .id_mem_write_en     (dec1_mem_write_en),
        .id_mem_size         (dec1_mem_size),
        .id_mem_unsigned     (dec1_mem_unsigned),
        .id_is_branch        (dec1_is_branch),
        .id_branch_cond      (dec1_branch_cond),
        .id_is_jal           (dec1_is_jal),
        .id_is_jalr          (dec1_is_jalr),
        .ex_s1_valid         (ex_s1_valid),
        .ex_s1_pc            (ex_s1_pc),
        .ex_s1_inst          (ex_s1_inst),
        .ex_s1_rd            (ex_s1_rd),
        .ex_s1_rs1_addr      (ex_s1_rs1_addr),
        .ex_s1_rs2_addr      (ex_s1_rs2_addr),
        .ex_s1_alu_op        (ex_s1_alu_op),
        .ex_s1_reg_write_en  (ex_s1_reg_write_en),
        .ex_s1_wb_sel        (ex_s1_wb_sel),
        .ex_s1_mem_read_en   (ex_s1_mem_read_en),
        .ex_s1_mem_write_en  (ex_s1_mem_write_en),
        .ex_s1_mem_size      (ex_s1_mem_size),
        .ex_s1_mem_unsigned  (ex_s1_mem_unsigned),
        .ex_s1_is_branch     (ex_s1_is_branch),
        .ex_s1_branch_cond   (ex_s1_branch_cond),
        .ex_s1_is_jal        (ex_s1_is_jal),
        .ex_s1_is_jalr       (ex_s1_is_jalr)
    );

    // ==================== EX stage ====================
    // ALU operands come directly from ID/EX_reg (pre-selected in ID)

    alu u_alu (
        .alu_op     (ex_alu_op),
        .alu_src1   (ex_alu_src1),
        .alu_src2   (ex_alu_src2),
        .alu_result (alu_result),
        .alu_sum    (alu_sum),
        .alu_addr   (alu_addr)
    );

    branch_unit u_branch_unit (
        .rs1_data         (ex_rs1_data),
        .rs2_data         (ex_rs2_data),
        .alu_addr         (alu_addr),       // pure adder output (bypasses negate+MUX, saves ~0.9ns)
        .ex_pc            (ex_pc),
        .is_branch        (ex_is_branch),
        .branch_cond      (ex_branch_cond),
        .is_jal           (ex_is_jal),
        .is_jalr          (ex_is_jalr),
        .ex_valid         (ex_valid),
        .predicted_taken  (ex_bp_taken),
        .predicted_target (ex_bp_target),
        .branch_flush     (branch_flush),
        .branch_target    (branch_target),
        .actual_taken     (actual_taken),
        .actual_target    (actual_target)
    );

    // Store interface (EX stage → DCache)
    mem_interface u_mem_interface (
        // Store side (EX stage)
        .store_valid     (ex_valid),
        .store_en        (ex_mem_write_en),
        .store_addr_low  (alu_addr[1:0]),
        .store_mem_size  (ex_mem_size),
        .store_data_in   (ex_rs2_data),
        .store_wea       (dram_wea),
        .store_data_out  (store_data_shifted),
        // Load side (WB stage)
        .load_addr_low   (wb_addr_low),
        .load_mem_size   (wb_mem_size),
        .load_unsigned   (wb_mem_unsigned),
        .load_dram_dout  (wb_load_rdata),   // from MEM/WB register (cache or mmio)
        .load_data_out   (wb_load_data)
    );

    // ==================== EX/MEM ====================

    ex_mem_reg u_ex_mem_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .ex_valid         (ex_valid),
        .ex_ready_go      (ex_ready_go_w),
        .mem_allowin      (mem_allowin),
        .mem_valid        (mem_valid),
        .mem_ready_go     (mem_ready_go_w),
        .wb_allowin       (wb_allowin),
        // 250MHz: register branch_flush into MEM stage
        // Gate with mem_allowin: don't propagate flush while pipeline is stalled
        // (DCache refill). This ensures the flush-generating instruction advances
        // to MEM first, rather than being killed by its own registered flush.
        .ex_branch_flush  (branch_flush & ~mem_branch_flush & mem_allowin),
        .ex_branch_target (branch_target),
        .mem_branch_flush (mem_branch_flush),
        .mem_branch_target(mem_branch_target),
        .ex_alu_result    (alu_result),
        .ex_pc            (ex_pc),
        .ex_pc_plus_4     (ex_pc_plus_4),
        .ex_rd            (ex_rd),
        .ex_reg_write_en  (ex_reg_write_en),
        .ex_wb_sel        (ex_wb_sel),
        .ex_mem_read_en   (ex_mem_read_en),
        .ex_mem_size      (ex_mem_size),
        .ex_mem_unsigned  (ex_mem_unsigned),
        .ex_store_wea     (dram_wea),
        .ex_store_data    (store_data_shifted),
        // DCache: pass is_cacheable to MEM
        .ex_is_cacheable  (is_cacheable),
        .mem_alu_result   (mem_alu_result),
        .mem_pc           (mem_pc),
        .mem_pc_plus_4    (mem_pc_plus_4),
        .mem_rd           (mem_rd),
        .mem_reg_write_en (mem_reg_write_en),
        .mem_wb_sel       (mem_wb_sel),
        .mem_mem_read_en  (mem_mem_read_en),
        .mem_mem_size     (mem_mem_size),
        .mem_mem_unsigned (mem_mem_unsigned),
        .mem_store_wea    (mem_store_wea),
        .mem_store_data   (mem_store_data),
        .mem_is_cacheable (is_cacheable_mem)
    );

    ex_mem_reg_s1 u_ex_mem_reg_s1 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .ex_s1_valid         (ex_s1_valid),
        .ex_ready_go         (ex_ready_go_w),
        .mem_allowin         (mem_allowin),
        .mem_branch_flush    (mem_branch_flush),
        .ex_s1_pc            (ex_s1_pc),
        .ex_s1_inst          (ex_s1_inst),
        .ex_s1_rd            (ex_s1_rd),
        .ex_s1_reg_write_en  (ex_s1_reg_write_en),
        .ex_s1_wb_sel        (ex_s1_wb_sel),
        .mem_s1_valid        (mem_s1_valid),
        .mem_s1_pc           (mem_s1_pc),
        .mem_s1_inst         (mem_s1_inst),
        .mem_s1_rd           (mem_s1_rd),
        .mem_s1_reg_write_en (mem_s1_reg_write_en),
        .mem_s1_wb_sel       (mem_s1_wb_sel)
    );

    // ==================== MEM/WB ====================

    mem_wb_reg u_mem_wb_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .mem_valid        (mem_valid),
        .mem_ready_go     (mem_ready_go_w),
        .wb_allowin       (wb_allowin),
        .wb_valid         (wb_valid),
        .mem_alu_result   (mem_alu_result),
        .mem_pc_plus_4    (mem_pc_plus_4),
        .mem_rd           (mem_rd),
        .mem_reg_write_en (mem_reg_write_en),
        .mem_wb_sel       (mem_wb_sel),
        .mem_mem_read_en  (mem_mem_read_en),
        .mem_mem_size     (mem_mem_size),
        .mem_mem_unsigned (mem_mem_unsigned),
        .mem_addr_low     (mem_alu_result[1:0]),
        .wb_alu_result    (wb_alu_result),
        .wb_pc_plus_4     (wb_pc_plus_4),
        .wb_rd            (wb_rd),
        .wb_reg_write_en  (wb_reg_write_en),
        .wb_wb_sel        (wb_wb_sel),
        .wb_is_load       (wb_is_load),
        .wb_mem_size      (wb_mem_size),
        .wb_mem_unsigned  (wb_mem_unsigned),
        .wb_addr_low      (wb_addr_low),
        .mem_load_rdata   (mem_load_data),   // from DCache (cacheable) or MMIO
        .wb_load_rdata    (wb_load_rdata)    // registered for WB stage
    );

    mem_wb_reg_s1 u_mem_wb_reg_s1 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .mem_s1_valid        (mem_s1_valid),
        .mem_ready_go        (mem_ready_go_w),
        .wb_allowin          (wb_allowin),
        .mem_s1_pc           (mem_s1_pc),
        .mem_s1_inst         (mem_s1_inst),
        .mem_s1_rd           (mem_s1_rd),
        .mem_s1_reg_write_en (mem_s1_reg_write_en),
        .mem_s1_wb_sel       (mem_s1_wb_sel),
        .wb_s1_valid         (wb_s1_valid),
        .wb_s1_pc            (wb_s1_pc),
        .wb_s1_inst          (wb_s1_inst),
        .wb_s1_rd            (wb_s1_rd),
        .wb_s1_reg_write_en  (wb_s1_reg_write_en),
        .wb_s1_wb_sel        (wb_s1_wb_sel)
    );

    // ==================== WB stage ====================

    wb_mux u_wb_mux (
        .wb_alu_result (wb_alu_result),
        .wb_load_data  (wb_load_data),
        .wb_pc_plus_4  (wb_pc_plus_4),
        .wb_sel        (wb_wb_sel),
        .wb_write_data (wb_write_data)
    );

endmodule
