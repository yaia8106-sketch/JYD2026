// ============================================================
// Module: cpu_top
// Description: RV32I 5-stage pipeline skeleton and module interconnect
// Rule: Keep behavior in stage/helper modules; cpu_top owns wiring and small glue.
// IROM: 外部例化，通过端口访问
// DRAM: 通过 DCache 访问（student_top 中例化）
// Branch Prediction: Tournament (BTB+GShare+Selector+RAS)
// ============================================================

module cpu_top (
    input  logic        clk,
    input  logic        rst_n,

    // IROM 接口 (IF stage)
    output logic [11:0] irom_even_addr,  // even bank address, pre-budgeted before source MUX
    output logic [11:0] irom_odd_addr,   // odd bank address, pre-budgeted before source MUX
    output logic        irom_fetch_odd,  // selected fetch PC[2], delayed in student_top for data rotate
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
    wire [31:0] irom_addr;        // full next PC, internal only; BRAMs use budgeted bank addresses
    // next_pc eliminated: inlined into irom_addr for 1 fewer LUT level on PC→IROM path
    wire        if_valid;

    // 250MHz: Pre-computed PC+4 register — eliminates carry chain from irom_addr default path
    // Each branch computes +4 independently from its registered source (no irom_addr feedback)
    logic [31:0] pc_plus4;
    logic [31:0] pc_plus8;
    logic [31:0] pc_plus12;

    // ---- IF/ID ----
    wire        id_valid;
    (* max_fanout = 16 *) wire        id_allowin;
    wire        id_ready_go;
    wire [31:0] id_pc;
    wire [31:0] id_inst;           // registered instruction from IF/ID
    wire [31:0] id_inst1;          // registered slot1 candidate instruction
    wire        id_s1_valid;       // registered slot1 issue valid

    // ---- IROM ----
    wire [31:0] irom_inst0;        // Phase 0: low 32-bit instruction from 64-bit IROM data
    wire [31:0] irom_inst1;        // Phase 1: high 32-bit instruction from 64-bit IROM data

    // ---- Instruction buffer ----
    wire [31:0] inst_buf;
    wire [31:0] inst_buf_pc;
    wire        inst_buf_valid;
    wire        skip_inst0_valid;
    wire        if_skip_inst0 = skip_inst0_valid;
    wire        if_buf_before_window;
    // Keep inst_buf_before_window out of the BP lookup path.  Buffered-slot
    // BP metadata is precomputed and stored beside inst_buf below.
    wire [31:0] bp_pc_live = pc;

    // ---- Instruction hold register ----
    wire        irom_held_valid;

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
    wire        dec_is_csr;
    wire        dec_csr_uses_rs1;
    wire        dec_csr_uses_imm;
    wire        dec_is_ecall;
    wire        dec_is_mret;
    wire        dec_is_muldiv;
    wire [ 2:0] dec_imm_type;

    // ---- Slot 1 decoder outputs ----
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
    wire        dec1_is_csr;
    wire        dec1_csr_uses_rs1;
    wire        dec1_csr_uses_imm;
    wire        dec1_is_ecall;
    wire        dec1_is_mret;
    wire        dec1_is_muldiv;
    wire [ 2:0] dec1_imm_type;

    // ---- Immediate ----
    wire [31:0] id_imm;
    wire [31:0] id_s1_imm;

    // ---- Regfile ----
    wire [31:0] rf_rs1_data;
    wire [31:0] rf_rs2_data;
    wire [31:0] rf_s1_rs1_data;
    wire [31:0] rf_s1_rs2_data;

    // ---- Forwarding ----
    wire [31:0] fwd_rs1_data;
    wire [31:0] fwd_rs2_data;
    wire [31:0] fwd_branch_rs1_data;
    wire [31:0] fwd_branch_rs2_data;
    wire [31:0] fwd_rs1_jalr_data;
    wire [31:0] fwd_s1_rs1_data;
    wire [31:0] fwd_s1_rs2_data;
    wire        fwd_rs1_wb_repair;
    wire        fwd_rs2_wb_repair;

    // ---- ALU src MUX (in ID stage) ----
    wire [31:0] id_alu_src1;
    wire [31:0] id_alu_src2;
    wire [31:0] id_s1_alu_src1;
    wire [31:0] id_s1_alu_src2;

    // ---- ID/EX ----
    wire        ex_valid;
    wire        ex_allowin;
    wire [31:0] ex_pc;
    wire [31:0] ex_alu_src1, ex_alu_src2;   // pre-selected in ID
    wire [31:0] ex_rs1_data, ex_rs2_data;   // raw, for branch/store
    wire        ex_rs1_wb_repair;
    wire        ex_rs2_wb_repair;
    wire [31:0] ex_branch_target_pre;        // ID-precomputed taken target
    wire [31:0] ex_fallthrough_pc;           // ID-precomputed PC+4
    wire [ 4:0] ex_rd, ex_rs1_addr, ex_rs2_addr;
    wire        ex_alu_src1_is_rs1, ex_alu_src2_is_rs2;
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
    wire        ex_is_csr;
    wire        ex_csr_uses_imm;
    wire [ 2:0] ex_csr_cmd;
    wire [11:0] ex_csr_addr;
    wire        ex_is_ecall;
    wire        ex_is_mret;
    wire        ex_is_muldiv;
    wire [ 2:0] ex_muldiv_op;

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
    wire [31:0] ex_s1_alu_src1, ex_s1_alu_src2;
    wire [31:0] ex_s1_rs1_data, ex_s1_rs2_data;

    // ---- ALU ----
    wire [31:0] alu_result;
    wire [31:0] alu_sum;               // ALU 加法器直出（跳过 output MUX）
    wire [31:0] alu_addr;              // FIX-A: 独立地址加法器（不依赖 alu_op）
    wire [31:0] alu_forward_result;     // unrepaired copy for ID forwarding only
    wire [31:0] alu_forward_sum;
    wire [31:0] alu_forward_addr;
    wire [31:0] alu_s1_result;
    wire [31:0] alu_s1_sum;
    wire [31:0] alu_s1_addr;
    wire [31:0] ex_alu_src1_repair;
    wire [31:0] ex_alu_src2_repair;
    wire        ex_result_late;

    // ---- Branch ----
    wire        branch_flush;          // EX stage combinational (for predictor update)
    wire [31:0] branch_target;         // EX stage combinational
    wire        actual_taken;          // for predictor update
    wire [31:0] actual_target;         // for predictor update
    wire        ex_branch_taken_pre;   // ID-precomputed branch compare result
    wire        ex_branch_registered_flush;
    wire        ex_s1_branch_redirect; // Slot1 branch delayed frontend redirect
    wire [31:0] ex_s1_branch_target;
    wire        ex_redirect_fire;
    wire        ex_system_inst;
    wire        ex_system_redirect;
    wire [31:0] ex_system_target;
    wire        ex_fast_redirect;
    wire [31:0] ex_fast_redirect_target;
    wire        ex_registered_branch_flush;
    wire [31:0] ex_registered_branch_target;

    assign ex_branch_registered_flush = branch_flush & ex_redirect_fire & ~ex_system_inst;

    // ---- Registered branch flush (MEM stage, for 250MHz timing) ----
    wire        mem_branch_flush;      // branch_flush delayed 1 cycle (from EX/MEM reg)
    wire [31:0] mem_branch_target;     // branch_target delayed 1 cycle (from EX/MEM reg)
    wire        mem_branch_replay;
    wire        frontend_branch_flush;
    wire [31:0] frontend_branch_target;

    // ---- Store interface (EX stage) ----
    wire [31:0] store_data_shifted;
    wire [31:0] s1_store_data_shifted;

    // ---- Memory interface ----
    wire [ 3:0] dram_wea;
    wire [ 3:0] dram_wea_s1;
    wire [31:0] mem_load_data;         // MEM stage: from cache (cacheable) or mmio (uncacheable)
    wire        mem_load_ready;        // ready S0_MEM load can repair S0 ALU in EX
    wire        is_cacheable;          // EX stage: addr in DRAM range
    wire        is_cacheable_s1;       // EX stage: Slot1 addr in DRAM range

    // ---- EX pre-computed ----
    wire [31:0] ex_pc_plus_4;
    wire [31:0] ex_s1_pc_plus_4;

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
    wire [31:0] mem_s1_alu_result;
    wire [31:0] mem_s1_pc_plus_4;
    wire [ 4:0] mem_s1_rd;
    wire        mem_s1_reg_write_en;
    wire [ 1:0] mem_s1_wb_sel;
    wire        mem_s1_mem_read_en;
    wire        mem_s1_mem_write_en;
    wire [ 1:0] mem_s1_mem_size;
    wire        mem_s1_mem_unsigned;
    wire [ 3:0] mem_s1_store_wea;
    wire [31:0] mem_s1_store_data;
    wire        mem_s1_is_cacheable;

    // ---- MEM/WB ----
    wire        wb_valid;
    wire        wb_allowin;
    wire [31:0] wb_alu_result;
    wire [31:0] wb_pc_plus_4;
    (* max_fanout = 8 *) wire [ 4:0] wb_rd;
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
    wire [31:0] wb_s1_alu_result;
    wire [31:0] wb_s1_pc_plus_4;
    (* max_fanout = 8 *) wire [ 4:0] wb_s1_rd;
    wire        wb_s1_reg_write_en;
    wire [ 1:0] wb_s1_wb_sel;
    wire        wb_s1_is_load;
    wire [ 1:0] wb_s1_mem_size;
    wire        wb_s1_mem_unsigned;
    wire [ 1:0] wb_s1_addr_low;
    wire [31:0] wb_s1_load_rdata;

    // ---- WB ----
    wire [31:0] wb_load_data;
    wire [31:0] wb_write_data;
    wire [31:0] wb_s1_load_data;
    wire [31:0] wb_s1_write_data;

    // ---- Minimal M-mode CSR / Trap ----
    wire [31:0] ex_csr_rdata;
    wire [31:0] ex_forward_result;
    wire [31:0] ex_pipe_alu_result;

    // ---- RV32M multi-cycle unit ----
    wire        muldiv_busy;
    wire        muldiv_done;
    wire [31:0] muldiv_result;
    wire        ex_muldiv_req = ex_valid & ex_is_muldiv & ~mem_branch_flush;
    wire        muldiv_consume = ex_valid & ex_is_muldiv & muldiv_done
                               & mem_allowin & ~mem_branch_flush;
    wire        muldiv_flush = frontend_branch_flush | mem_branch_flush;

    // ---- Dual-issue performance counter ----
    wire [31:0] dual_issue_count;

    // MEM-stage cacheable flag (registered from EX via EX/MEM reg)
    wire is_cacheable_mem;

    // ---- Handshake ----
    wire if_ready_go_w  = 1'b1;     // BRAM latency absorbed by pipeline
    wire mmio_st_ld_hazard;
    wire ex_muldiv_ready = mem_branch_flush | ~ex_muldiv_req | muldiv_done;
    wire ex_ready_go_w  = ~mmio_st_ld_hazard & ex_muldiv_ready;
    wire mem_ready_go_w = cache_ready; // DCache controls MEM stage flow

    // ---- Flush / redirect ----
    wire id_bp_redirect;            // NLP: ID-stage Tournament redirect

    wire id_flush = frontend_branch_flush | id_bp_redirect;
    wire ex_flush = frontend_branch_flush;

    // ---- Register addresses from instruction (ID stage, from IF/ID reg) ----
    wire [4:0] id_rs1_addr;
    wire [4:0] id_rs2_addr;
    wire [4:0] id_rd_addr;
    wire [4:0] id_s1_rs1_addr;
    wire [4:0] id_s1_rs2_addr;
    wire [4:0] id_s1_rd_addr;
    wire [31:0] id_pc_plus_4;
    wire [31:0] id_s1_pc;
    wire [ 2:0] id_csr_cmd;
    wire [11:0] id_csr_addr;
    wire [31:0] id_branch_target_pre;
    wire        id_rs1_used;
    wire        id_rs2_used;
    wire        id_s1_rs1_used;
    wire        id_s1_rs2_used;
    wire        id_s0_alu_only;
    wire        id_branch_taken_pre;
    wire        id_tournament_taken;
    wire        id_bp_redirect_raw;
    wire        id_s1_squash_raw;
    wire [31:0] id_redirect_target;

    memory_access_unit u_memory_access_unit (
        .ex_valid            (ex_valid),
        .ex_mem_read_en      (ex_mem_read_en),
        .ex_mem_write_en     (ex_mem_write_en),
        .ex_alu_addr         (alu_addr),
        .ex_store_wea        (dram_wea),
        .ex_store_data       (store_data_shifted),
        .ex_s1_valid         (ex_s1_valid),
        .ex_s1_mem_read_en   (ex_s1_mem_read_en),
        .ex_s1_mem_write_en  (ex_s1_mem_write_en),
        .ex_s1_alu_addr      (alu_s1_addr),
        .ex_s1_store_wea     (dram_wea_s1),
        .ex_s1_store_data    (s1_store_data_shifted),
        .mem_valid           (mem_valid),
        .mem_alu_result      (mem_alu_result),
        .mem_mem_read_en     (mem_mem_read_en),
        .mem_store_wea       (mem_store_wea),
        .mem_store_data      (mem_store_data),
        .mem_is_cacheable    (is_cacheable_mem),
        .mem_s1_valid        (mem_s1_valid),
        .mem_s1_alu_result   (mem_s1_alu_result),
        .mem_s1_mem_read_en  (mem_s1_mem_read_en),
        .mem_s1_mem_write_en (mem_s1_mem_write_en),
        .mem_s1_store_wea    (mem_s1_store_wea),
        .mem_s1_store_data   (mem_s1_store_data),
        .mem_s1_is_cacheable (mem_s1_is_cacheable),
        .mem_ready_go        (mem_ready_go_w),
        .mem_allowin         (mem_allowin),
        .mem_branch_flush    (mem_branch_flush),
        .cache_rdata         (cache_rdata),
        .mmio_rdata          (mmio_rdata),
        .dual_issue_count    (dual_issue_count),
        .is_cacheable        (is_cacheable),
        .is_cacheable_s1     (is_cacheable_s1),
        .mmio_st_ld_hazard   (mmio_st_ld_hazard),
        .cache_req           (cache_req),
        .cache_wr            (cache_wr),
        .cache_addr          (cache_addr),
        .cache_wea           (cache_wea),
        .cache_wdata         (cache_wdata),
        .cache_flush         (cache_flush),
        .cache_pipeline_stall(cache_pipeline_stall),
        .mmio_addr           (mmio_addr),
        .mmio_wr_addr        (mmio_wr_addr),
        .mmio_wea            (mmio_wea),
        .mmio_wdata          (mmio_wdata),
        .mem_load_data       (mem_load_data),
        .mem_load_ready      (mem_load_ready)
    );

    redirect_ctrl u_redirect_ctrl (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .ex_ready_go                 (ex_ready_go_w),
        .mem_allowin                 (mem_allowin),
        .mem_branch_flush            (mem_branch_flush),
        .mem_branch_target           (mem_branch_target),
        .ex_system_redirect          (ex_system_redirect),
        .ex_system_target            (ex_system_target),
        .ex_redirect_fire            (ex_redirect_fire),
        .ex_fast_redirect            (ex_fast_redirect),
        .ex_fast_redirect_target     (ex_fast_redirect_target),
        .mem_branch_replay           (mem_branch_replay),
        .frontend_branch_flush       (frontend_branch_flush),
        .frontend_branch_target      (frontend_branch_target)
    );

    // ================================================================
    //  Branch prediction wires
    // ================================================================

    // IF stage prediction outputs (L0: fast path)
    wire        bp_taken;
    wire [31:0] bp_target;
    wire [11:0] bp_target_even_addr;
    wire [11:0] bp_target_odd_addr;
    wire        bp_target_fetch_odd;
    wire [11:0] bp_target_plus4_even_addr;
    wire [11:0] bp_target_plus4_odd_addr;
    wire        bp_target_plus4_fetch_odd;
    wire [11:0] bp_target_plus8_even_addr;
    wire [11:0] bp_target_plus8_odd_addr;
    wire        bp_target_plus8_fetch_odd;
    wire [11:0] bp_target_plus12_even_addr;
    wire [11:0] bp_target_plus12_odd_addr;
    wire        bp_target_plus12_fetch_odd;
    wire [ 7:0] bp_ghr_snap;
    wire        bp_btb_hit;
    wire [ 1:0] bp_btb_type;    // NLP: entry type for ID verification
    wire [ 1:0] bp_btb_bht;
    wire [ 1:0] bp_pht_cnt;
    wire [ 1:0] bp_sel_cnt;

    // Skip-inst0 lookahead prediction (for next-cycle buffered slot1 fetch)
    wire        la_bp_taken;
    wire [31:0] la_bp_target;
    wire [11:0] la_bp_even_addr;
    wire [11:0] la_bp_odd_addr;
    wire        la_bp_fetch_odd;
    wire [ 7:0] la_bp_ghr_snap;
    wire        la_bp_btb_hit;
    wire [ 1:0] la_bp_btb_type;
    wire [ 1:0] la_bp_btb_bht;
    wire [ 1:0] la_bp_pht_cnt;
    wire [ 1:0] la_bp_sel_cnt;

    // Buffered-slot prediction for inst_buf_pc = if_pc_out + 4.
    wire [31:0] buf_bp_pc;
    wire        buf_bp_taken;
    wire [31:0] buf_bp_target;
    wire [11:0] buf_bp_even_addr;
    wire [11:0] buf_bp_odd_addr;
    wire        buf_bp_fetch_odd;
    wire [ 7:0] buf_bp_ghr_snap;
    wire        buf_bp_btb_hit;
    wire [ 1:0] buf_bp_btb_type;
    wire [ 1:0] buf_bp_btb_bht;
    wire [ 1:0] buf_bp_pht_cnt;
    wire [ 1:0] buf_bp_sel_cnt;

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

    id_stage_derive u_id_stage_derive (
        .id_valid          (id_valid),
        .id_ready_go       (id_ready_go),
        .ex_allowin        (ex_allowin),
        .mem_branch_flush  (mem_branch_flush),
        .id_pc             (id_pc),
        .id_inst           (id_inst),
        .id_inst1          (id_inst1),
        .id_imm            (id_imm),
        .dec_alu_src1_sel  (dec_alu_src1_sel),
        .dec_alu_src2_sel  (dec_alu_src2_sel),
        .dec_reg_write_en  (dec_reg_write_en),
        .dec_wb_sel        (dec_wb_sel),
        .dec_mem_read_en   (dec_mem_read_en),
        .dec_mem_write_en  (dec_mem_write_en),
        .dec_is_branch     (dec_is_branch),
        .dec_branch_cond   (dec_branch_cond),
        .dec_is_jal        (dec_is_jal),
        .dec_is_jalr       (dec_is_jalr),
        .dec_is_csr        (dec_is_csr),
        .dec_csr_uses_rs1  (dec_csr_uses_rs1),
        .dec_is_muldiv     (dec_is_muldiv),
        .dec1_alu_src1_sel (dec1_alu_src1_sel),
        .dec1_alu_src2_sel (dec1_alu_src2_sel),
        .dec1_mem_write_en (dec1_mem_write_en),
        .dec1_is_branch    (dec1_is_branch),
        .dec1_csr_uses_rs1 (dec1_csr_uses_rs1),
        .fwd_rs1_data      (fwd_rs1_data),
        .fwd_rs2_data      (fwd_rs2_data),
        .fwd_branch_rs1_data(fwd_branch_rs1_data),
        .fwd_branch_rs2_data(fwd_branch_rs2_data),
        .fwd_rs1_jalr_data (fwd_rs1_jalr_data),
        .id_bp_btb_hit     (id_bp_btb_hit),
        .id_bp_btb_type    (id_bp_btb_type),
        .id_bp_btb_bht     (id_bp_btb_bht),
        .id_bp_pht_cnt     (id_bp_pht_cnt),
        .id_bp_sel_cnt     (id_bp_sel_cnt),
        .id_bp_target      (id_bp_target),
        .id_rs1_addr       (id_rs1_addr),
        .id_rs2_addr       (id_rs2_addr),
        .id_rd_addr        (id_rd_addr),
        .id_s1_rs1_addr    (id_s1_rs1_addr),
        .id_s1_rs2_addr    (id_s1_rs2_addr),
        .id_s1_rd_addr     (id_s1_rd_addr),
        .id_pc_plus_4      (id_pc_plus_4),
        .id_s1_pc          (id_s1_pc),
        .id_csr_cmd        (id_csr_cmd),
        .id_csr_addr       (id_csr_addr),
        .id_branch_target_pre(id_branch_target_pre),
        .id_rs1_used       (id_rs1_used),
        .id_rs2_used       (id_rs2_used),
        .id_s1_rs1_used    (id_s1_rs1_used),
        .id_s1_rs2_used    (id_s1_rs2_used),
        .id_s0_alu_only    (id_s0_alu_only),
        .id_branch_taken_pre(id_branch_taken_pre),
        .id_tournament_taken(id_tournament_taken),
        .id_bp_redirect_raw(id_bp_redirect_raw),
        .id_bp_redirect    (id_bp_redirect),
        .id_s1_squash_raw  (id_s1_squash_raw),
        .id_redirect_target(id_redirect_target)
    );

    // ==================== Branch Predictor ====================

    branch_predictor u_bp (
        .clk             (clk),
        .rst_n           (rst_n),

        // IF prediction (L0: fast path)
        .if_pc           (bp_pc_live),
        .bp_taken        (bp_taken),
        .bp_target       (bp_target),
        .bp_even_addr    (bp_target_even_addr),
        .bp_odd_addr     (bp_target_odd_addr),
        .bp_fetch_odd    (bp_target_fetch_odd),
        .bp_plus4_even_addr (bp_target_plus4_even_addr),
        .bp_plus4_odd_addr  (bp_target_plus4_odd_addr),
        .bp_plus4_fetch_odd (bp_target_plus4_fetch_odd),
        .bp_plus8_even_addr (bp_target_plus8_even_addr),
        .bp_plus8_odd_addr  (bp_target_plus8_odd_addr),
        .bp_plus8_fetch_odd (bp_target_plus8_fetch_odd),
        .bp_plus12_even_addr(bp_target_plus12_even_addr),
        .bp_plus12_odd_addr (bp_target_plus12_odd_addr),
        .bp_plus12_fetch_odd(bp_target_plus12_fetch_odd),
        .bp_ghr_snap     (bp_ghr_snap),
        .bp_btb_hit      (bp_btb_hit),
        .bp_btb_type     (bp_btb_type),     // NLP
        .bp_btb_bht      (bp_btb_bht),
        .bp_pht_cnt      (bp_pht_cnt),
        .bp_sel_cnt      (bp_sel_cnt),

        // Lookahead prediction for possible next-cycle skip_inst0 fetch.
        // When current PC P was predicted single but actually dual-issues,
        // next cycle issues P+8 from irom_inst1, so query P+8 now.
        .la_pc           (pc_plus8),
        .la_bp_taken     (la_bp_taken),
        .la_bp_target    (la_bp_target),
        .la_bp_even_addr (la_bp_even_addr),
        .la_bp_odd_addr  (la_bp_odd_addr),
        .la_bp_fetch_odd (la_bp_fetch_odd),
        .la_bp_ghr_snap  (la_bp_ghr_snap),
        .la_bp_btb_hit   (la_bp_btb_hit),
        .la_bp_btb_type  (la_bp_btb_type),
        .la_bp_btb_bht   (la_bp_btb_bht),
        .la_bp_pht_cnt   (la_bp_pht_cnt),
        .la_bp_sel_cnt   (la_bp_sel_cnt),

        // Prediction for the instruction that may be stored in inst_buf.
        .buf_pc           (buf_bp_pc),
        .buf_bp_taken     (buf_bp_taken),
        .buf_bp_target    (buf_bp_target),
        .buf_bp_even_addr (buf_bp_even_addr),
        .buf_bp_odd_addr  (buf_bp_odd_addr),
        .buf_bp_fetch_odd (buf_bp_fetch_odd),
        .buf_bp_ghr_snap  (buf_bp_ghr_snap),
        .buf_bp_btb_hit   (buf_bp_btb_hit),
        .buf_bp_btb_type  (buf_bp_btb_type),
        .buf_bp_btb_bht   (buf_bp_btb_bht),
        .buf_bp_pht_cnt   (buf_bp_pht_cnt),
        .buf_bp_sel_cnt   (buf_bp_sel_cnt),

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

    (* max_fanout = 16 *) wire        if_allowin_w = id_allowin;   // for irom_addr mux
    wire        can_dual_issue;
    wire        can_dual_fetch;
    wire        raw_pair_raw;
    wire        raw_inst1_is_alu_type;
    wire        raw_inst0_is_jump;
    logic       predict_dual;

    wire [31:0] if_inst0_out;
    wire [31:0] if_inst1_out;
    wire [31:0] if_pc_out;
    wire        if_bp_taken_out;
    wire [31:0] if_bp_target_out;
    wire [ 7:0] if_bp_ghr_snap_out;
    wire        if_bp_btb_hit_out;
    wire [ 1:0] if_bp_btb_type_out;
    wire [ 1:0] if_bp_btb_bht_out;
    wire [ 1:0] if_bp_pht_cnt_out;
    wire [ 1:0] if_bp_sel_cnt_out;
    wire        if_skip_out;
    wire        if_s1_valid;
    wire        if_sequential_fetch;
    wire        inst_buf_valid_next;
    wire        bp_taken_for_if;
    wire [31:0] bp_target_for_if;
    wire [11:0] bp_even_addr;
    wire [11:0] bp_odd_addr;
    wire        bp_fetch_odd;
    wire [11:0] bp_plus4_even_addr;
    wire [11:0] bp_plus4_odd_addr;
    wire        bp_plus4_fetch_odd;
    wire [11:0] bp_plus8_even_addr;
    wire [11:0] bp_plus8_odd_addr;
    wire        bp_plus8_fetch_odd;
    wire [11:0] bp_plus12_even_addr;
    wire [11:0] bp_plus12_odd_addr;
    wire        bp_plus12_fetch_odd;

    assign irom_inst0 = irom_data[31:0];
    assign irom_inst1 = irom_data[63:32];

    dual_issue_decider u_dual_issue_decider (
        .clk                 (clk),
        .rst_n               (rst_n),
        .if_valid            (if_valid),
        .id_flush            (id_flush),
        .id_allowin          (id_allowin),
        .irom_held_valid     (irom_held_valid),
        .if_skip_inst0       (if_skip_inst0),
        .if_skip_out         (if_skip_out),
        .if_buf_before_window(if_buf_before_window),
        .if_sequential_fetch (if_sequential_fetch),
        .pc                  (pc),
        .inst_buf            (inst_buf),
        .inst_buf_pc         (inst_buf_pc),
        .if_pc_out           (if_pc_out),
        .irom_inst0          (irom_inst0),
        .irom_inst1          (irom_inst1),
        .can_dual_fetch      (can_dual_fetch),
        .can_dual_issue      (can_dual_issue),
        .inst_buf_valid_next (inst_buf_valid_next),
        .raw_pair_raw        (raw_pair_raw),
        .raw_inst1_is_alu_type(raw_inst1_is_alu_type),
        .raw_inst0_is_jump   (raw_inst0_is_jump)
    );

    if_stage_buffer u_if_stage_buffer (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .if_valid                    (if_valid),
        .if_ready_go                 (if_ready_go_w),
        .id_allowin                  (id_allowin),
        .id_flush                    (id_flush),
        .frontend_branch_flush       (frontend_branch_flush),
        .id_bp_redirect_raw          (id_bp_redirect_raw),
        .can_dual_issue              (can_dual_issue),
        .inst_buf_valid_next         (inst_buf_valid_next),
        .pc                          (pc),
        .pc_plus4                    (pc_plus4),
        .irom_inst0                  (irom_inst0),
        .irom_inst1                  (irom_inst1),
        .bp_taken                    (bp_taken),
        .bp_target                   (bp_target),
        .bp_ghr_snap                 (bp_ghr_snap),
        .bp_btb_hit                  (bp_btb_hit),
        .bp_btb_type                 (bp_btb_type),
        .bp_btb_bht                  (bp_btb_bht),
        .bp_pht_cnt                  (bp_pht_cnt),
        .bp_sel_cnt                  (bp_sel_cnt),
        .bp_target_even_addr         (bp_target_even_addr),
        .bp_target_odd_addr          (bp_target_odd_addr),
        .bp_target_fetch_odd         (bp_target_fetch_odd),
        .bp_target_plus4_even_addr   (bp_target_plus4_even_addr),
        .bp_target_plus4_odd_addr    (bp_target_plus4_odd_addr),
        .bp_target_plus4_fetch_odd   (bp_target_plus4_fetch_odd),
        .bp_target_plus8_even_addr   (bp_target_plus8_even_addr),
        .bp_target_plus8_odd_addr    (bp_target_plus8_odd_addr),
        .bp_target_plus8_fetch_odd   (bp_target_plus8_fetch_odd),
        .bp_target_plus12_even_addr  (bp_target_plus12_even_addr),
        .bp_target_plus12_odd_addr   (bp_target_plus12_odd_addr),
        .bp_target_plus12_fetch_odd  (bp_target_plus12_fetch_odd),
        .la_bp_taken                 (la_bp_taken),
        .la_bp_target                (la_bp_target),
        .la_bp_ghr_snap              (la_bp_ghr_snap),
        .la_bp_btb_hit               (la_bp_btb_hit),
        .la_bp_btb_type              (la_bp_btb_type),
        .la_bp_btb_bht               (la_bp_btb_bht),
        .la_bp_pht_cnt               (la_bp_pht_cnt),
        .la_bp_sel_cnt               (la_bp_sel_cnt),
        .la_bp_even_addr             (la_bp_even_addr),
        .la_bp_odd_addr              (la_bp_odd_addr),
        .la_bp_fetch_odd             (la_bp_fetch_odd),
        .buf_bp_taken                (buf_bp_taken),
        .buf_bp_target               (buf_bp_target),
        .buf_bp_ghr_snap             (buf_bp_ghr_snap),
        .buf_bp_btb_hit              (buf_bp_btb_hit),
        .buf_bp_btb_type             (buf_bp_btb_type),
        .buf_bp_btb_bht              (buf_bp_btb_bht),
        .buf_bp_pht_cnt              (buf_bp_pht_cnt),
        .buf_bp_sel_cnt              (buf_bp_sel_cnt),
        .buf_bp_even_addr            (buf_bp_even_addr),
        .buf_bp_odd_addr             (buf_bp_odd_addr),
        .buf_bp_fetch_odd            (buf_bp_fetch_odd),
        .inst_buf                    (inst_buf),
        .inst_buf_pc                 (inst_buf_pc),
        .inst_buf_valid              (inst_buf_valid),
        .if_skip_inst0               (skip_inst0_valid),
        .if_buf_before_window        (if_buf_before_window),
        .irom_held_valid             (irom_held_valid),
        .predict_dual                (predict_dual),
        .if_inst0_out                (if_inst0_out),
        .if_inst1_out                (if_inst1_out),
        .if_pc_out                   (if_pc_out),
        .if_bp_taken_out             (if_bp_taken_out),
        .if_bp_target_out            (if_bp_target_out),
        .if_bp_ghr_snap_out          (if_bp_ghr_snap_out),
        .if_bp_btb_hit_out           (if_bp_btb_hit_out),
        .if_bp_btb_type_out          (if_bp_btb_type_out),
        .if_bp_btb_bht_out           (if_bp_btb_bht_out),
        .if_bp_pht_cnt_out           (if_bp_pht_cnt_out),
        .if_bp_sel_cnt_out           (if_bp_sel_cnt_out),
        .if_skip_out                 (if_skip_out),
        .if_s1_valid                 (if_s1_valid),
        .if_sequential_fetch         (if_sequential_fetch),
        .buf_bp_pc                   (buf_bp_pc),
        .bp_taken_for_if             (bp_taken_for_if),
        .bp_target_for_if            (bp_target_for_if),
        .bp_even_addr                (bp_even_addr),
        .bp_odd_addr                 (bp_odd_addr),
        .bp_fetch_odd                (bp_fetch_odd),
        .bp_plus4_even_addr          (bp_plus4_even_addr),
        .bp_plus4_odd_addr           (bp_plus4_odd_addr),
        .bp_plus4_fetch_odd          (bp_plus4_fetch_odd),
        .bp_plus8_even_addr          (bp_plus8_even_addr),
        .bp_plus8_odd_addr           (bp_plus8_odd_addr),
        .bp_plus8_fetch_odd          (bp_plus8_fetch_odd),
        .bp_plus12_even_addr         (bp_plus12_even_addr),
        .bp_plus12_odd_addr          (bp_plus12_odd_addr),
        .bp_plus12_fetch_odd         (bp_plus12_fetch_odd)
    );

    irom_addr_ctrl u_irom_addr_ctrl (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .if_allowin                (if_allowin_w),
        .predict_dual              (predict_dual),
        .if_buf_before_window      (if_buf_before_window),
        .mem_branch_replay         (mem_branch_replay),
        .mem_branch_target         (mem_branch_target),
        .ex_fast_redirect          (ex_fast_redirect),
        .ex_fast_redirect_target   (ex_fast_redirect_target),
        .ex_branch_redirect        (ex_branch_registered_flush),
        .ex_branch_registered_to_target(actual_taken),
        .ex_branch_target_pre      (ex_branch_target_pre),
        .ex_fallthrough_pc         (ex_fallthrough_pc),
        .ex_system_redirect        (ex_system_redirect),
        .ex_system_target          (ex_system_target),
        .ex_s1_branch_target       (ex_s1_branch_target),
        .id_bp_redirect_raw        (id_bp_redirect_raw),
        .id_redirect_target        (id_redirect_target),
        .bp_taken_for_if           (bp_taken_for_if),
        .bp_target_for_if          (bp_target_for_if),
        .bp_even_addr              (bp_even_addr),
        .bp_odd_addr               (bp_odd_addr),
        .bp_fetch_odd              (bp_fetch_odd),
        .bp_plus4_even_addr        (bp_plus4_even_addr),
        .bp_plus4_odd_addr         (bp_plus4_odd_addr),
        .bp_plus4_fetch_odd        (bp_plus4_fetch_odd),
        .bp_plus8_even_addr        (bp_plus8_even_addr),
        .bp_plus8_odd_addr         (bp_plus8_odd_addr),
        .bp_plus8_fetch_odd        (bp_plus8_fetch_odd),
        .bp_plus12_even_addr       (bp_plus12_even_addr),
        .bp_plus12_odd_addr        (bp_plus12_odd_addr),
        .bp_plus12_fetch_odd       (bp_plus12_fetch_odd),
        .pc_plus4                  (pc_plus4),
        .pc_plus8                  (pc_plus8),
        .pc_plus12                 (pc_plus12),
        .irom_addr                 (irom_addr),
        .irom_even_addr            (irom_even_addr),
        .irom_odd_addr             (irom_odd_addr),
        .irom_fetch_odd            (irom_fetch_odd)
    );

    pc_reg u_pc_reg (
        .clk           (clk),
        .rst_n         (rst_n),
        .if_allowin    (id_allowin),
        .if_valid      (if_valid),
        .branch_flush  (frontend_branch_flush),
        .branch_target (frontend_branch_target),
        .next_pc       (irom_addr),
        .pc            (pc)
    );

    dual_issue_counter u_dual_issue_counter (
        .clk             (clk),
        .rst_n           (rst_n),
        .wb_s1_valid     (wb_s1_valid),
        .dual_issue_count(dual_issue_count)
    );

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
        .if_pc        (if_pc_out),
        .if_inst      (if_inst0_out),    // held, buffered, or live BRAM output
        .if_inst1     (if_inst1_out),
        .if_s1_valid  (if_s1_valid),
        .id_pc        (id_pc),
        .id_inst      (id_inst),         // registered instruction for ID
        .id_inst1     (id_inst1),
        .id_s1_valid  (id_s1_valid),
        // Branch prediction passthrough
        .if_bp_taken    (if_bp_taken_out),
        .if_bp_target   (if_bp_target_out),
        .if_bp_ghr_snap (if_bp_ghr_snap_out),
        .if_bp_btb_hit  (if_bp_btb_hit_out),
        .if_bp_btb_type (if_bp_btb_type_out),     // NLP: type for ID verification
        .if_bp_btb_bht  (if_bp_btb_bht_out),
        .if_bp_pht_cnt  (if_bp_pht_cnt_out),
        .if_bp_sel_cnt  (if_bp_sel_cnt_out),
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
        .is_csr         (dec_is_csr),
        .csr_uses_rs1   (dec_csr_uses_rs1),
        .csr_uses_imm   (dec_csr_uses_imm),
        .is_ecall       (dec_is_ecall),
        .is_mret        (dec_is_mret),
        .is_muldiv      (dec_is_muldiv),
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
        .is_csr         (dec1_is_csr),
        .csr_uses_rs1   (dec1_csr_uses_rs1),
        .csr_uses_imm   (dec1_csr_uses_imm),
        .is_ecall       (dec1_is_ecall),
        .is_mret        (dec1_is_mret),
        .is_muldiv      (dec1_is_muldiv),
        .imm_type       (dec1_imm_type)
    );

    imm_gen u_imm_gen (
        .inst     (id_inst),                   // from IF/ID register
        .imm_type (dec_imm_type),
        .imm      (id_imm)
    );

    imm_gen u_imm_gen_s1 (
        .inst     (id_inst1),
        .imm_type (dec1_imm_type),
        .imm      (id_s1_imm)
    );

    regfile u_regfile (
        .clk          (clk),
        .rst_n        (rst_n),
        .rs1_addr     (id_rs1_addr),
        .rs2_addr     (id_rs2_addr),
        .rs1_data     (rf_rs1_data),
        .rs2_data     (rf_rs2_data),
        .rs1_addr_s1  (id_s1_rs1_addr),
        .rs2_addr_s1  (id_s1_rs2_addr),
        .rs1_data_s1  (rf_s1_rs1_data),
        .rs2_data_s1  (rf_s1_rs2_data),
        .rd_addr      (wb_rd),
        .rd_data      (wb_write_data),
        .rd_wen       (wb_reg_write_en),
        .rd_valid     (wb_valid),
        .rd_addr_s1   (wb_s1_rd),
        .rd_data_s1   (wb_s1_write_data),
        .rd_wen_s1    (wb_s1_reg_write_en),
        .rd_valid_s1  (wb_s1_valid)
    );

    forwarding u_forwarding (
        .id_rs1_addr    (id_rs1_addr),
        .id_rs2_addr    (id_rs2_addr),
        .id_rs1_used    (id_rs1_used),
        .id_rs2_used    (id_rs2_used),
        .id_s0_alu_only (id_s0_alu_only),
        .id_s0_jalr     (dec_is_jalr),
        .id_s0_branch   (dec_is_branch),
        .rf_rs1_data    (rf_rs1_data),
        .rf_rs2_data    (rf_rs2_data),
        .id_s1_valid    (id_s1_valid & ~id_s1_squash_raw),
        .id_s1_rs1_addr (id_s1_rs1_addr),
        .id_s1_rs2_addr (id_s1_rs2_addr),
        .id_s1_rs1_used (id_s1_rs1_used),
        .id_s1_rs2_used (id_s1_rs2_used),
        .rf_s1_rs1_data (rf_s1_rs1_data),
        .rf_s1_rs2_data (rf_s1_rs2_data),
        .ex_valid       (ex_valid),
        .ex_reg_write   (ex_reg_write_en & (~ex_is_muldiv | muldiv_done)),
        .ex_mem_read    (ex_mem_read_en),
        .ex_rd          (ex_rd),
        .ex_alu_result  (ex_forward_result),
        .ex_pc_plus_4   (ex_pc_plus_4),
        .ex_wb_sel      (ex_wb_sel),
        .ex_wb_repair   (ex_result_late),
        .ex_s1_valid       (ex_s1_valid),
        .ex_s1_reg_write   (ex_s1_reg_write_en),
        .ex_s1_mem_read    (ex_s1_mem_read_en),
        .ex_s1_rd          (ex_s1_rd),
        .ex_s1_alu_result  (alu_s1_result),
        .ex_s1_pc_plus_4   (ex_s1_pc_plus_4),
        .ex_s1_wb_sel      (ex_s1_wb_sel),
        .mem_valid      (mem_valid),
        .mem_reg_write  (mem_reg_write_en),
        .mem_is_load    (mem_mem_read_en),
        .mem_rd         (mem_rd),
        .mem_alu_result (mem_alu_result),
        .mem_pc_plus_4  (mem_pc_plus_4),
        .mem_load_ready (mem_load_ready),
        .mem_wb_sel     (mem_wb_sel),
        .mem_s1_valid       (mem_s1_valid),
        .mem_s1_reg_write   (mem_s1_reg_write_en),
        .mem_s1_is_load     (mem_s1_mem_read_en),
        .mem_s1_rd          (mem_s1_rd),
        .mem_s1_alu_result  (mem_s1_alu_result),
        .mem_s1_pc_plus_4   (mem_s1_pc_plus_4),
        .mem_s1_wb_sel      (mem_s1_wb_sel),
        .wb_valid       (wb_valid),
        .wb_reg_write   (wb_reg_write_en),
        .wb_rd          (wb_rd),
        .wb_write_data  (wb_write_data),
        .wb_s1_valid       (wb_s1_valid),
        .wb_s1_reg_write   (wb_s1_reg_write_en),
        .wb_s1_rd          (wb_s1_rd),
        .wb_s1_write_data  (wb_s1_write_data),
        .id_rs1_data    (fwd_rs1_data),
        .id_rs2_data    (fwd_rs2_data),
        .id_branch_rs1_data(fwd_branch_rs1_data),
        .id_branch_rs2_data(fwd_branch_rs2_data),
        .id_rs1_jalr_data(fwd_rs1_jalr_data),
        .id_s1_rs1_data (fwd_s1_rs1_data),
        .id_s1_rs2_data (fwd_s1_rs2_data),
        .id_rs1_wb_repair(fwd_rs1_wb_repair),
        .id_rs2_wb_repair(fwd_rs2_wb_repair),
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

    alu_src_mux u_alu_src_mux_s1 (
        .rs1_data      (fwd_s1_rs1_data),
        .rs2_data      (fwd_s1_rs2_data),
        .pc            (id_s1_pc),
        .imm           (id_s1_imm),
        .alu_src1_sel  (dec1_alu_src1_sel),
        .alu_src2_sel  (dec1_alu_src2_sel),
        .alu_src1      (id_s1_alu_src1),
        .alu_src2      (id_s1_alu_src2)
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
        .id_rs1_wb_repair (fwd_rs1_wb_repair),
        .id_rs2_wb_repair (fwd_rs2_wb_repair),
        .id_branch_target (id_branch_target_pre),
        .id_fallthrough_pc(id_pc_plus_4),
        .id_rd            (id_rd_addr),
        .id_rs1_addr      (id_rs1_addr),
        .id_rs2_addr      (id_rs2_addr),
        .id_alu_src1_is_rs1(dec_alu_src1_sel == 2'b00),
        .id_alu_src2_is_rs2(~dec_alu_src2_sel),
        .id_alu_op        (dec_alu_op),
        .id_reg_write_en  (dec_reg_write_en),
        .id_wb_sel        (dec_wb_sel),
        .id_mem_read_en   (dec_mem_read_en),
        .id_mem_write_en  (dec_mem_write_en),
        .id_mem_size      (dec_mem_size),
        .id_mem_unsigned  (dec_mem_unsigned),
        .id_is_branch     (dec_is_branch),
        .id_branch_cond   (dec_branch_cond),
        .id_branch_taken  (id_branch_taken_pre),
        .id_is_jal        (dec_is_jal),
        .id_is_jalr       (dec_is_jalr),
        .id_is_csr        (dec_is_csr),
        .id_csr_uses_imm  (dec_csr_uses_imm),
        .id_csr_cmd       (id_csr_cmd),
        .id_csr_addr      (id_csr_addr),
        .id_is_ecall      (dec_is_ecall),
        .id_is_mret       (dec_is_mret),
        .id_is_muldiv     (dec_is_muldiv),
        .id_muldiv_op     (id_inst[14:12]),
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
        .ex_rs1_wb_repair (ex_rs1_wb_repair),
        .ex_rs2_wb_repair (ex_rs2_wb_repair),
        .ex_branch_target (ex_branch_target_pre),
        .ex_fallthrough_pc(ex_fallthrough_pc),
        .ex_rd            (ex_rd),
        .ex_rs1_addr      (ex_rs1_addr),
        .ex_rs2_addr      (ex_rs2_addr),
        .ex_alu_src1_is_rs1(ex_alu_src1_is_rs1),
        .ex_alu_src2_is_rs2(ex_alu_src2_is_rs2),
        .ex_alu_op        (ex_alu_op),
        .ex_reg_write_en  (ex_reg_write_en),
        .ex_wb_sel        (ex_wb_sel),
        .ex_mem_read_en   (ex_mem_read_en),
        .ex_mem_write_en  (ex_mem_write_en),
        .ex_mem_size      (ex_mem_size),
        .ex_mem_unsigned  (ex_mem_unsigned),
        .ex_is_branch     (ex_is_branch),
        .ex_branch_cond   (ex_branch_cond),
        .ex_branch_taken  (ex_branch_taken_pre),
        .ex_is_jal        (ex_is_jal),
        .ex_is_jalr       (ex_is_jalr),
        .ex_is_csr        (ex_is_csr),
        .ex_csr_uses_imm  (ex_csr_uses_imm),
        .ex_csr_cmd       (ex_csr_cmd),
        .ex_csr_addr      (ex_csr_addr),
        .ex_is_ecall      (ex_is_ecall),
        .ex_is_mret       (ex_is_mret),
        .ex_is_muldiv     (ex_is_muldiv),
        .ex_muldiv_op     (ex_muldiv_op),
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
        .id_s1_valid         (id_s1_valid & ~id_s1_squash_raw),
        .id_ready_go         (id_ready_go),
        .ex_allowin          (ex_allowin),
        .ex_flush            (ex_flush),
        .id_pc               (id_s1_pc),
        .id_inst             (id_inst1),
        .id_alu_src1         (id_s1_alu_src1),
        .id_alu_src2         (id_s1_alu_src2),
        .id_rs1_data         (fwd_s1_rs1_data),
        .id_rs2_data         (fwd_s1_rs2_data),
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
        .ex_s1_alu_src1      (ex_s1_alu_src1),
        .ex_s1_alu_src2      (ex_s1_alu_src2),
        .ex_s1_rs1_data      (ex_s1_rs1_data),
        .ex_s1_rs2_data      (ex_s1_rs2_data),
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
    // MEM-ready load consumers repair their S0 ALU operands from WB here.
    // A separate unrepaired ALU feeds ID forwarding so this late path cannot
    // become WB->ALU->ID/IF in static timing.
    ex_stage_ctrl u_ex_stage_ctrl (
        .ex_pc                      (ex_pc),
        .ex_s1_pc                   (ex_s1_pc),
        .ex_rs1_wb_repair           (ex_rs1_wb_repair),
        .ex_rs2_wb_repair           (ex_rs2_wb_repair),
        .wb_write_data              (wb_write_data),
        .ex_alu_src1                (ex_alu_src1),
        .ex_alu_src2                (ex_alu_src2),
        .ex_is_csr                  (ex_is_csr),
        .ex_csr_rdata               (ex_csr_rdata),
        .ex_is_muldiv               (ex_is_muldiv),
        .ex_muldiv_result           (muldiv_result),
        .alu_forward_result         (alu_forward_result),
        .alu_result                 (alu_result),
        .ex_s1_valid                (ex_s1_valid),
        .ex_s1_is_branch            (ex_s1_is_branch),
        .ex_s1_is_jal               (ex_s1_is_jal),
        .ex_s1_branch_cond          (ex_s1_branch_cond),
        .ex_s1_rs1_data             (ex_s1_rs1_data),
        .ex_s1_rs2_data             (ex_s1_rs2_data),
        .alu_s1_result              (alu_s1_result),
        .mem_branch_flush           (mem_branch_flush),
        .ex_ready_go                (ex_ready_go_w),
        .mem_allowin                (mem_allowin),
        .ex_branch_redirect         (ex_branch_registered_flush),
        .branch_target              (branch_target),
        .ex_system_redirect         (ex_system_redirect),
        .ex_system_target           (ex_system_target),
        .ex_pc_plus_4               (ex_pc_plus_4),
        .ex_s1_pc_plus_4            (ex_s1_pc_plus_4),
        .ex_alu_src1_repair         (ex_alu_src1_repair),
        .ex_alu_src2_repair         (ex_alu_src2_repair),
        .ex_forward_result          (ex_forward_result),
        .ex_pipe_alu_result         (ex_pipe_alu_result),
        .ex_result_late             (ex_result_late),
        .ex_s1_branch_target        (ex_s1_branch_target),
        .ex_s1_branch_redirect      (ex_s1_branch_redirect),
        .ex_registered_branch_flush (ex_registered_branch_flush),
        .ex_registered_branch_target(ex_registered_branch_target)
    );

    alu u_alu_forward (
        .alu_op     (ex_alu_op),
        .alu_src1   (ex_alu_src1),
        .alu_src2   (ex_alu_src2),
        .alu_result (alu_forward_result),
        .alu_sum    (alu_forward_sum),
        .alu_addr   (alu_forward_addr)
    );

    alu u_alu (
        .alu_op     (ex_alu_op),
        .alu_src1   (ex_alu_src1_repair),
        .alu_src2   (ex_alu_src2_repair),
        .alu_result (alu_result),
        .alu_sum    (alu_sum),
        .alu_addr   (alu_addr)
    );

    alu u_alu_s1 (
        .alu_op     (ex_s1_alu_op),
        .alu_src1   (ex_s1_alu_src1),
        .alu_src2   (ex_s1_alu_src2),
        .alu_result (alu_s1_result),
        .alu_sum    (alu_s1_sum),
        .alu_addr   (alu_s1_addr)
    );

    muldiv_unit u_muldiv_unit (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (ex_muldiv_req),
        .req_op    (ex_muldiv_op),
        .req_mul_rs1(ex_alu_src1_repair),
        .req_mul_rs2(ex_alu_src2_repair),
        .req_div_rs1(ex_alu_src1),
        .req_div_rs2(ex_alu_src2),
        .consume   (muldiv_consume),
        .flush     (muldiv_flush),
        .busy      (muldiv_busy),
        .done      (muldiv_done),
        .result    (muldiv_result)
    );

    // ==================== Minimal M-mode CSR / Trap ====================
    csr_trap_unit u_csr_trap_unit (
        .clk               (clk),
        .rst_n             (rst_n),
        .ex_valid          (ex_valid),
        .ex_ready_go       (ex_ready_go_w),
        .mem_allowin       (mem_allowin),
        .mem_branch_flush  (mem_branch_flush),
        .ex_redirect_fire  (ex_redirect_fire),
        .ex_pc             (ex_pc),
        .ex_rs1_data       (ex_rs1_data),
        .ex_rs1_addr       (ex_rs1_addr),
        .ex_is_csr         (ex_is_csr),
        .ex_csr_uses_imm   (ex_csr_uses_imm),
        .ex_csr_cmd        (ex_csr_cmd),
        .ex_csr_addr       (ex_csr_addr),
        .ex_is_ecall       (ex_is_ecall),
        .ex_is_mret        (ex_is_mret),
        .ex_system_inst    (ex_system_inst),
        .ex_system_redirect(ex_system_redirect),
        .ex_system_target  (ex_system_target),
        .ex_csr_rdata      (ex_csr_rdata)
    );

    branch_unit u_branch_unit (
        .target_pc        (ex_branch_target_pre),
        .fallthrough_pc   (ex_fallthrough_pc),
        .is_branch        (ex_is_branch),
        .branch_taken_pre (ex_branch_taken_pre),
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

    mem_interface u_mem_interface_s1_load (
        // Store side (EX stage, shares the single LSU when Slot0 is non-LSU)
        .store_valid     (ex_s1_valid),
        .store_en        (ex_s1_mem_write_en),
        .store_addr_low  (alu_s1_addr[1:0]),
        .store_mem_size  (ex_s1_mem_size),
        .store_data_in   (ex_s1_rs2_data),
        .store_wea       (dram_wea_s1),
        .store_data_out  (s1_store_data_shifted),
        // Load side (WB stage)
        .load_addr_low   (wb_s1_addr_low),
        .load_mem_size   (wb_s1_mem_size),
        .load_unsigned   (wb_s1_mem_unsigned),
        .load_dram_dout  (wb_s1_load_rdata),
        .load_data_out   (wb_s1_load_data)
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
        // Register branch redirects before replaying the frontend.  Keeping
        // this off the same-cycle IROM path buys timing at one extra miss cycle.
        // Gate with EX readiness: don't propagate while the EX instruction stalls.
        // (DCache refill). This ensures the flush-generating instruction advances
        // to MEM first, rather than being killed by its own registered flush.
        .ex_branch_flush  (ex_registered_branch_flush),
        .ex_branch_target (ex_registered_branch_target),
        .mem_branch_flush (mem_branch_flush),
        .mem_branch_target(mem_branch_target),
        .ex_alu_result    (ex_pipe_alu_result),
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
        .ex_branch_flush     (branch_flush),
        .mem_branch_flush    (mem_branch_flush),
        .ex_s1_pc            (ex_s1_pc),
        .ex_s1_inst          (ex_s1_inst),
        .ex_s1_alu_result    (alu_s1_result),
        .ex_s1_pc_plus_4     (ex_s1_pc_plus_4),
        .ex_s1_rd            (ex_s1_rd),
        .ex_s1_reg_write_en  (ex_s1_reg_write_en),
        .ex_s1_wb_sel        (ex_s1_wb_sel),
        .ex_s1_mem_read_en   (ex_s1_mem_read_en),
        .ex_s1_mem_write_en  (ex_s1_mem_write_en),
        .ex_s1_mem_size      (ex_s1_mem_size),
        .ex_s1_mem_unsigned  (ex_s1_mem_unsigned),
        .ex_s1_store_wea     (dram_wea_s1),
        .ex_s1_store_data    (s1_store_data_shifted),
        .ex_s1_is_cacheable  (is_cacheable_s1),
        .mem_s1_valid        (mem_s1_valid),
        .mem_s1_pc           (mem_s1_pc),
        .mem_s1_inst         (mem_s1_inst),
        .mem_s1_alu_result   (mem_s1_alu_result),
        .mem_s1_pc_plus_4    (mem_s1_pc_plus_4),
        .mem_s1_rd           (mem_s1_rd),
        .mem_s1_reg_write_en (mem_s1_reg_write_en),
        .mem_s1_wb_sel       (mem_s1_wb_sel),
        .mem_s1_mem_read_en  (mem_s1_mem_read_en),
        .mem_s1_mem_write_en (mem_s1_mem_write_en),
        .mem_s1_mem_size     (mem_s1_mem_size),
        .mem_s1_mem_unsigned (mem_s1_mem_unsigned),
        .mem_s1_store_wea    (mem_s1_store_wea),
        .mem_s1_store_data   (mem_s1_store_data),
        .mem_s1_is_cacheable (mem_s1_is_cacheable)
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
        .mem_s1_alu_result   (mem_s1_alu_result),
        .mem_s1_pc_plus_4    (mem_s1_pc_plus_4),
        .mem_s1_rd           (mem_s1_rd),
        .mem_s1_reg_write_en (mem_s1_reg_write_en),
        .mem_s1_wb_sel       (mem_s1_wb_sel),
        .mem_s1_mem_read_en  (mem_s1_mem_read_en),
        .mem_s1_mem_size     (mem_s1_mem_size),
        .mem_s1_mem_unsigned (mem_s1_mem_unsigned),
        .mem_s1_addr_low     (mem_s1_alu_result[1:0]),
        .mem_s1_load_rdata   (mem_load_data),
        .wb_s1_valid         (wb_s1_valid),
        .wb_s1_pc            (wb_s1_pc),
        .wb_s1_inst          (wb_s1_inst),
        .wb_s1_alu_result    (wb_s1_alu_result),
        .wb_s1_pc_plus_4     (wb_s1_pc_plus_4),
        .wb_s1_rd            (wb_s1_rd),
        .wb_s1_reg_write_en  (wb_s1_reg_write_en),
        .wb_s1_wb_sel        (wb_s1_wb_sel),
        .wb_s1_is_load       (wb_s1_is_load),
        .wb_s1_mem_size      (wb_s1_mem_size),
        .wb_s1_mem_unsigned  (wb_s1_mem_unsigned),
        .wb_s1_addr_low      (wb_s1_addr_low),
        .wb_s1_load_rdata    (wb_s1_load_rdata)
    );

    // ==================== WB stage ====================

    wb_mux u_wb_mux (
        .wb_alu_result (wb_alu_result),
        .wb_load_data  (wb_load_data),
        .wb_pc_plus_4  (wb_pc_plus_4),
        .wb_sel        (wb_wb_sel),
        .wb_write_data (wb_write_data)
    );

    wb_mux u_wb_mux_s1 (
        .wb_alu_result (wb_s1_alu_result),
        .wb_load_data  (wb_s1_load_data),
        .wb_pc_plus_4  (wb_s1_pc_plus_4),
        .wb_sel        (wb_s1_wb_sel),
        .wb_write_data (wb_s1_write_data)
    );

endmodule
