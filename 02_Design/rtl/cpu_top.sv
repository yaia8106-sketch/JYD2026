// ============================================================
// Module: cpu_top
// Description: RV32I 5-stage pipeline processor top-level
// Rule: WIRING ONLY — no logic, no assign expressions with operators
// IROM/DRAM: 外部例化，通过端口访问
// Branch Prediction: Tournament (BTB+GShare+Selector+RAS)
// ============================================================

module cpu_top (
    input  logic        clk,
    input  logic        rst_n,

    // IROM 接口 (IF stage)
    output logic [31:0] irom_addr,       // = next_pc（预取，IF 阶段）
    input  logic [31:0] irom_data,       // 指令（BRAM 1拍 Clk-to-Q，IF 阶段有效）

    // Peripheral bus
    //   Read path: EX stage (combinational)
    //   Write path: MEM stage (registered, FIX-C)
    output logic [31:0] perip_addr,      // EX stage: alu_addr (DRAM read addr)
    output logic [31:0] perip_addr_sum,  // 兼容保留 (= perip_addr)
    output logic [31:0] perip_wr_addr,   // MEM stage: store address (DRAM write addr)
    output logic [3:0]  perip_wea,       // MEM stage: store WEA (registered)
    output logic [31:0] perip_wdata,     // MEM stage: store data (registered)
    input  logic [31:0] perip_rdata      // MEM stage: read data
);

    // ================================================================
    //  Internal wires
    // ================================================================

    // ---- PC & IF ----
    wire [31:0] pc;
    wire [31:0] next_pc;
    wire        if_valid;

    // ---- IF/ID ----
    wire        id_valid;
    wire        id_allowin;
    wire        id_ready_go;
    wire [31:0] id_pc;
    wire [31:0] id_inst;           // registered instruction from IF/ID

    // ---- IROM ----
    wire [31:0] irom_dout;         // instruction from BRAM output register

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

    // ---- ALU ----
    wire [31:0] alu_result;
    wire [31:0] alu_sum;               // ALU 加法器直出（跳过 output MUX）
    wire [31:0] alu_addr;              // FIX-A: 独立地址加法器（不依赖 alu_op）

    // ---- Branch ----
    wire        branch_flush;
    wire [31:0] branch_target;
    wire        actual_taken;          // for predictor update
    wire [31:0] actual_target;         // for predictor update

    // ---- Store interface (EX stage) ----
    wire [31:0] store_data_shifted;

    // ---- DRAM ----
    wire [ 3:0] dram_wea;
    wire [31:0] dram_dout;             // = perip_rdata (from bridge, MEM stage)

    // ---- EX/MEM ----
    wire        mem_valid;
    wire        mem_allowin;
    wire [31:0] mem_alu_result;
    wire [31:0] mem_pc;
    wire [ 4:0] mem_rd;
    wire        mem_reg_write_en;
    wire [ 1:0] mem_wb_sel;
    wire        mem_mem_read_en;
    wire [ 1:0] mem_mem_size;
    wire        mem_mem_unsigned;
    wire [ 3:0] mem_store_wea;         // FIX-C: registered store WEA
    wire [31:0] mem_store_data;        // FIX-C: registered store data

    // ---- MEM/WB ----
    wire        wb_valid;
    wire        wb_allowin;
    wire [31:0] wb_alu_result;
    wire [31:0] wb_pc;
    wire [ 4:0] wb_rd;
    wire        wb_reg_write_en;
    wire [ 1:0] wb_wb_sel;
    wire        wb_is_load;
    wire [ 1:0] wb_mem_size;
    wire        wb_mem_unsigned;
    wire [ 1:0] wb_addr_low;
    wire [31:0] wb_dram_dout;   // registered BRAM output (1-cycle BRAM, captured in MEM/WB)

    // ---- WB ----
    wire [31:0] wb_load_data;
    wire [31:0] wb_write_data;

    // ---- Handshake constants ----
    wire if_ready_go_w  = 1'b1;     // BRAM latency absorbed by pipeline

    // FIX-C: Store-load hazard detection
    //   MEM 有 store + EX 有 load + DRAM word 地址相同 → stall 1 拍
    wire store_load_hazard = (|mem_store_wea)
                           & ex_valid & ex_mem_read_en
                           & (mem_alu_result[17:2] == alu_addr[17:2]);
    wire ex_ready_go_w  = ~store_load_hazard;
    wire mem_ready_go_w = 1'b1;     // BRAM latency absorbed by pipeline

    // ---- Flush (updated below after id_bp_redirect is computed) ----
    wire id_bp_redirect;            // NLP: ID-stage Tournament redirect
    wire id_flush = branch_flush | id_bp_redirect;
    wire ex_flush = branch_flush;

    // ---- Register addresses from instruction (ID stage, from IF/ID reg) ----
    wire [4:0] id_rs1_addr = id_inst[19:15];
    wire [4:0] id_rs2_addr = id_inst[24:20];
    wire [4:0] id_rd_addr  = id_inst[11:7];

    // ---- Port assignments ----
    // FIX-C: 读写分离——读(EX) + 写(MEM)
    assign perip_addr     = alu_addr;             // EX stage: 读地址
    assign perip_addr_sum = alu_addr;             // 兼容保留
    assign perip_wr_addr  = mem_alu_result;       // MEM stage: 写地址（已打拍）
    assign perip_wea      = mem_valid ? mem_store_wea : 4'b0000;  // 门控：MEM 无效时禁写
    assign perip_wdata    = mem_store_data;       // MEM stage: 写数据（已打拍）
    assign dram_dout   = perip_rdata;       // bridge 读数据 (MEM stage)

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
        .ex_valid        (ex_valid),
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

    next_pc_mux u_next_pc_mux (
        .pc       (pc),
        .bp_taken (bp_taken),
        .bp_target(bp_target),
        .next_pc  (next_pc)
    );

    // NLP: ID-stage Tournament verification (L1)
    // Compares L0 (Bimodal bht[1], used in IF) with L1 (Tournament, computed here)
    wire id_bimodal_taken  = (id_bp_btb_bht >= 2'd2);   // = bht[1]
    wire id_gshare_taken   = (id_bp_pht_cnt >= 2'd2);
    wire id_use_bimodal    = (id_bp_sel_cnt >= 2'd2);
    wire id_tournament_taken = id_use_bimodal ? id_bimodal_taken : id_gshare_taken;

    // NLP redirect: L0 and L1 disagree on BRANCH direction
    // Only triggers for BRANCH type with BTB hit
    assign id_bp_redirect = id_valid & ~branch_flush
                          & id_bp_btb_hit
                          & (id_bp_btb_type == 2'b10)    // TYPE_BRANCH
                          & (id_bp_btb_bht[1] != id_tournament_taken);

    // Redirect target: if Tournament says taken → use BTB target;
    //                  if Tournament says not-taken → use PC+4
    wire [31:0] id_redirect_target = id_tournament_taken ? id_bp_target
                                                         : (id_pc + 32'd4);

    assign irom_addr = branch_flush   ? branch_target :     // EX flush (highest priority)
                       id_bp_redirect ? id_redirect_target : // NLP: ID redirect
                       !if_allowin_w  ? pc :                 // 停顿：保持当前地址
                                        next_pc;             // 正常：预取下一条（含L0预测）

    pc_reg u_pc_reg (
        .clk           (clk),
        .rst_n         (rst_n),
        .if_allowin    (id_allowin),    // simplified: if_valid=1, if_ready_go=1
        .if_valid      (if_valid),
        .branch_flush  (branch_flush),
        .branch_target (branch_target),
        .next_pc       (irom_addr),
        .pc            (pc)
    );

    // ==================== IROM: 外部例化，通过 irom_addr/irom_data 端口 ====================

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
        .if_inst      (irom_data),       // BRAM output captured in IF stage
        .id_pc        (id_pc),
        .id_inst      (id_inst),         // registered instruction for ID
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
        .ex_pc          (ex_pc),
        .ex_wb_sel      (ex_wb_sel),
        .mem_valid      (mem_valid),
        .mem_reg_write  (mem_reg_write_en),
        .mem_is_load    (mem_mem_read_en),
        .mem_rd         (mem_rd),
        .mem_alu_result (mem_alu_result),
        .mem_pc         (mem_pc),
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
        .alu_result       (alu_result),
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

    // Store interface (EX stage → DRAM)
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
        .load_dram_dout  (wb_dram_dout),    // from MEM/WB register (1-cycle BRAM)
        .load_data_out   (wb_load_data)
    );

    // ==================== DRAM: 外部例化，通过 perip 端口 ====================

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
        .ex_alu_result    (alu_result),
        .ex_pc            (ex_pc),
        .ex_rd            (ex_rd),
        .ex_reg_write_en  (ex_reg_write_en),
        .ex_wb_sel        (ex_wb_sel),
        .ex_mem_read_en   (ex_mem_read_en),
        .ex_mem_size      (ex_mem_size),
        .ex_mem_unsigned  (ex_mem_unsigned),
        .ex_store_wea     (dram_wea),            // FIX-C: latch WEA
        .ex_store_data    (store_data_shifted),   // FIX-C: latch shifted data
        .mem_alu_result   (mem_alu_result),
        .mem_pc           (mem_pc),
        .mem_rd           (mem_rd),
        .mem_reg_write_en (mem_reg_write_en),
        .mem_wb_sel       (mem_wb_sel),
        .mem_mem_read_en  (mem_mem_read_en),
        .mem_mem_size     (mem_mem_size),
        .mem_mem_unsigned (mem_mem_unsigned),
        .mem_store_wea    (mem_store_wea),        // FIX-C: to perip_wea
        .mem_store_data   (mem_store_data)        // FIX-C: to perip_wdata
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
        .mem_pc           (mem_pc),
        .mem_rd           (mem_rd),
        .mem_reg_write_en (mem_reg_write_en),
        .mem_wb_sel       (mem_wb_sel),
        .mem_mem_read_en  (mem_mem_read_en),
        .mem_mem_size     (mem_mem_size),
        .mem_mem_unsigned (mem_mem_unsigned),
        .mem_addr_low     (mem_alu_result[1:0]),
        .wb_alu_result    (wb_alu_result),
        .wb_pc            (wb_pc),
        .wb_rd            (wb_rd),
        .wb_reg_write_en  (wb_reg_write_en),
        .wb_wb_sel        (wb_wb_sel),
        .wb_is_load       (wb_is_load),
        .wb_mem_size      (wb_mem_size),
        .wb_mem_unsigned  (wb_mem_unsigned),
        .wb_addr_low      (wb_addr_low),
        .mem_dram_dout    (dram_dout),      // BRAM output (MEM stage, 1-cycle latency)
        .wb_dram_dout     (wb_dram_dout)    // registered for WB stage
    );

    // ==================== WB stage ====================

    wb_mux u_wb_mux (
        .wb_alu_result (wb_alu_result),
        .wb_load_data  (wb_load_data),
        .wb_pc         (wb_pc),
        .wb_sel        (wb_wb_sel),
        .wb_write_data (wb_write_data)
    );

endmodule
