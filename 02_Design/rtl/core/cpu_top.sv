// ============================================================
// Module: cpu_top
// Description: RV32I 5-stage pipeline skeleton and module interconnect
// Rule: Keep behavior in stage/helper modules; cpu_top owns wiring and small glue.
// IROM: 外部例化，通过端口访问
// DRAM: 通过 DCache 访问（student_top 中例化）
// Frontend Prediction: Stage-1 ABTB + PHT canonical steering
// ============================================================

`ifdef SYNTHESIS
`ifdef ABTB_MEASUREMENT
`define CPU_TOP_ABTB_OBSERVE
`endif
`else
`define CPU_TOP_ABTB_OBSERVE
`endif

module cpu_top (
    input  logic        clk,
    input  logic        rst_n,

    // IROM 接口 (IF stage): 64-bit aligned block ROM
    output logic [11:0] irom_addr,
    input  logic [63:0] irom_data,

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
    input  logic [31:0] mmio_rdata,      // MEM stage: 读数据
    input  logic        timer_irq_pending
);

    localparam logic [1:0] ABTB_TYPE_JAL    = 2'b00;
    localparam logic [1:0] ABTB_TYPE_CALL   = 2'b01;
    localparam logic [1:0] ABTB_TYPE_BRANCH = 2'b10;
    localparam logic [1:0] ABTB_TYPE_RET    = 2'b11;

    // ================================================================
    //  Internal wires
    // ================================================================

    // ---- PC & IF ----
    wire [31:0] pc;
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
    wire        id_ready_go_raw;
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
    // Keep inst_buf_before_window out of the prediction lookup path.
    // Buffered-slot prediction metadata is precomputed and stored beside
    // inst_buf below.
    wire [31:0] pred_pc_live = pc;

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
    wire [31:0] fwd_s1_rs1_data;
    wire [31:0] fwd_s1_rs2_data;
    wire        fwd_rs1_wb_repair;
    wire        fwd_rs2_wb_repair;
    wire        fwd_s1_rs1_wb_repair;
    wire        fwd_s1_rs2_wb_repair;
    wire        fwd_rs1_wb_repair_s1;
    wire        fwd_rs2_wb_repair_s1;
    wire        fwd_s1_rs1_wb_repair_s1;
    wire        fwd_s1_rs2_wb_repair_s1;

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
    wire        ex_rs1_wb_repair_s1;
    wire        ex_rs2_wb_repair_s1;
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
    wire        ex_s1_rs1_wb_repair;
    wire        ex_s1_rs2_wb_repair;
    wire        ex_s1_rs1_wb_repair_s1;
    wire        ex_s1_rs2_wb_repair_s1;
    wire        ex_s1_alu_src1_is_rs1;
    wire        ex_s1_alu_src2_is_rs2;

    // ---- ALU ----
    wire [31:0] alu_result;
    wire [31:0] alu_sum;               // ALU 加法器直出（跳过 output MUX）
    wire [31:0] alu_addr;              // FIX-A: 独立地址加法器（不依赖 alu_op）
    wire [31:0] alu_s1_result;
    wire [31:0] alu_s1_sum;
    wire [31:0] alu_s1_addr;
    wire [31:0] ex_alu_src1_repair;
    wire [31:0] ex_alu_src2_repair;
    wire [31:0] ex_s1_alu_src1_repair;
    wire [31:0] ex_s1_alu_src2_repair;
    wire [31:0] ex_rs1_data_repair;
    wire [31:0] ex_rs2_data_repair;
    wire [31:0] ex_s1_rs1_data_repair;
    wire [31:0] ex_s1_rs2_data_repair;

    // ---- Branch ----
    wire        branch_flush;          // EX stage combinational (for predictor update)
    wire [31:0] branch_target;         // EX stage combinational
    wire        actual_taken;          // for predictor update
    wire [31:0] actual_target;         // for predictor update
    wire [31:0] ex_control_target;     // EX-computed target for Slot 0 CFI
    wire        ex_branch_registered_flush;
    wire        ex_s1_branch_redirect; // Slot1 branch delayed frontend redirect
    wire [31:0] ex_s1_branch_target;
    wire        ex_s1_actual_taken;
    wire        ex_redirect_fire;
    wire        ex_system_inst;
    wire        ex_system_redirect;
    wire [31:0] ex_system_target;
    wire        timer_irq_request;
    wire        timer_irq_redirect;
    wire [31:0] timer_irq_target;
    logic       timer_irq_hold;
    wire        timer_irq_pipe_empty;
    wire        timer_irq_take;
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
    wire [ 4:0] wb_load_shift;
    wire        wb_load_byte_signed;
    wire        wb_load_byte_unsigned;
    wire        wb_load_half_signed;
    wire        wb_load_half_unsigned;
    wire        wb_load_word;
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
    wire [ 4:0] wb_s1_load_shift;
    wire        wb_s1_load_byte_signed;
    wire        wb_s1_load_byte_unsigned;
    wire        wb_s1_load_half_signed;
    wire        wb_s1_load_half_unsigned;
    wire        wb_s1_load_word;
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
    wire if_ready_go_w;             // driven by frontend_ftq
    wire mmio_st_ld_hazard;
    wire ex_muldiv_ready = mem_branch_flush | ~ex_muldiv_req | muldiv_done;
    wire ex_ready_go_w  = ~mmio_st_ld_hazard & ex_muldiv_ready;
    wire mem_ready_go_w = cache_ready; // DCache controls MEM stage flow
    assign id_ready_go = id_ready_go_raw & ~timer_irq_hold;
    assign timer_irq_pipe_empty = ~ex_valid & ~mem_valid & ~wb_valid
                                & ~ex_s1_valid & ~mem_s1_valid & ~wb_s1_valid;
    assign timer_irq_take = timer_irq_hold & id_valid & timer_irq_pipe_empty;

    always_ff @(posedge clk) begin
        if (!rst_n)
            timer_irq_hold <= 1'b0;
        else if (timer_irq_take)
            timer_irq_hold <= 1'b0;
        else if (frontend_branch_flush)
            timer_irq_hold <= 1'b0;
        else if (timer_irq_request & id_valid)
            timer_irq_hold <= 1'b1;
    end

    // ---- Flush / redirect ----
    wire id_flush = frontend_branch_flush;
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
    wire        id_alu_src1_is_rs1;
    wire        id_alu_src2_is_rs2;
    wire        id_s1_alu_src1_is_rs1;
    wire        id_s1_alu_src2_is_rs2;
    wire        id_rs1_used;
    wire        id_rs2_used;
    wire        id_s1_rs1_used;
    wire        id_s1_rs2_used;
    wire        id_s0_alu_only;
    wire        id_s1_repair_ok;
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
        .timer_irq_redirect          (timer_irq_redirect),
        .timer_irq_target            (timer_irq_target),
        .ex_redirect_fire            (ex_redirect_fire),
        .ex_fast_redirect            (ex_fast_redirect),
        .ex_fast_redirect_target     (ex_fast_redirect_target),
        .mem_branch_replay           (mem_branch_replay),
        .frontend_branch_flush       (frontend_branch_flush),
        .frontend_branch_target      (frontend_branch_target)
    );

    // ================================================================
    //  Stage-1 prediction wires
    // ================================================================

    // ID stage prediction (from IF/ID reg)
    wire        id_pred_taken;
    wire [31:0] id_pred_target;
    wire        id_s1_pred_taken;
    wire [31:0] id_s1_pred_target;

    // EX stage prediction (from ID/EX reg)
    wire        ex_pred_taken;
    wire [31:0] ex_pred_target;
    wire        ex_s1_pred_taken;
    wire [31:0] ex_s1_pred_target;

    // ABTB lookup/training metadata. ABTB/PHT owns Stage-1 J/CALL and branch
    // steering by default. Legacy predictor metadata has been retired.
    wire        abtb_lookup_accept;
    wire        abtb_bank0_hit;
    wire        abtb_bank0_lookup_hit;
    wire        abtb_bank0_way;
    wire [ 1:0] abtb_bank0_cfi_type;
    wire [31:0] abtb_bank0_target;
    wire        abtb_bank0_pred_taken;
    wire [31:0] abtb_bank0_pred_target;
    wire        abtb_bank1_hit;
    wire        abtb_bank1_lookup_hit;
    wire        abtb_bank1_way;
    wire [ 1:0] abtb_bank1_cfi_type;
    wire [31:0] abtb_bank1_target;
    wire        abtb_bank1_pred_taken;
    wire [31:0] abtb_bank1_pred_target;
    wire        abtb_shadow_pred_taken;
    wire        abtb_shadow_pred_bank;
    wire [ 1:0] abtb_shadow_pred_cfi_type;
    wire [31:0] abtb_shadow_pred_target;
    wire [31:0] abtb_shadow_pred_next_pc;

    wire        if_abtb_hit_out;
    wire        if_abtb_way_out;
    wire [ 1:0] if_abtb_cfi_type_out;
    wire [31:0] if_abtb_target_out;
    wire        if_abtb_pred_taken_out;
    wire [31:0] if_abtb_pred_target_out;
    wire        if_pred_source_abtb_out;
    wire        if_stage1_branch_owned_out;
    wire        if_s1_abtb_hit_out;
    wire        if_s1_abtb_way_out;
    wire [ 1:0] if_s1_abtb_cfi_type_out;
    wire [31:0] if_s1_abtb_target_out;
    wire        if_s1_abtb_pred_taken_out;
    wire [31:0] if_s1_abtb_pred_target_out;
    wire        if_s1_pred_source_abtb_out;
    wire        if_s1_stage1_branch_owned_out;

    wire        id_abtb_hit;
    wire        id_abtb_way;
    wire [ 1:0] id_abtb_cfi_type;
    wire [31:0] id_abtb_target;
    wire        id_abtb_pred_taken;
    wire [31:0] id_abtb_pred_target;
    wire        id_pred_source_abtb;
    wire        id_stage1_branch_owned;
    wire        id_abtb_update_qualified_w;
    wire [ 1:0] id_abtb_update_cfi_type_w;
    wire        id_s1_abtb_hit;
    wire        id_s1_abtb_way;
    wire [ 1:0] id_s1_abtb_cfi_type;
    wire [31:0] id_s1_abtb_target;
    wire        id_s1_abtb_pred_taken;
    wire [31:0] id_s1_abtb_pred_target;
    wire        id_s1_pred_source_abtb;
    wire        id_s1_stage1_branch_owned;
    wire        id_s1_abtb_update_qualified_w;
    wire [ 1:0] id_s1_abtb_update_cfi_type_w;

    wire        ex_abtb_hit;
    wire        ex_abtb_way;
    wire [ 1:0] ex_abtb_cfi_type;
    wire [31:0] ex_abtb_target;
    wire        ex_abtb_pred_taken;
    wire [31:0] ex_abtb_pred_target;
    wire        ex_pred_source_abtb;
    wire        ex_stage1_branch_owned;
    wire        ex_abtb_update_qualified;
    wire [ 1:0] ex_abtb_update_cfi_type;
    wire        ex_s1_abtb_hit;
    wire        ex_s1_abtb_way;
    wire [ 1:0] ex_s1_abtb_cfi_type;
    wire [31:0] ex_s1_abtb_target;
    wire        ex_s1_abtb_pred_taken;
    wire [31:0] ex_s1_abtb_pred_target;
    wire        ex_s1_pred_source_abtb;
    wire        ex_s1_stage1_branch_owned;
    wire        ex_s1_abtb_update_qualified;
    wire [ 1:0] ex_s1_abtb_update_cfi_type;
    wire [ 7:0] stage1_bank0_pht_index;
    wire [ 1:0] stage1_bank0_pht_counter;
    wire        stage1_bank0_pht_taken;
    wire [ 7:0] stage1_bank1_pht_index;
    wire [ 1:0] stage1_bank1_pht_counter;
    wire        stage1_bank1_pht_taken;
    wire [ 7:0] stage1_lookup_ghr;
    wire [ 7:0] stage1_committed_ghr;
    wire [ 7:0] if_stage1_pht_index;
    wire [ 1:0] if_stage1_pht_counter;
    wire [ 7:0] if_s1_stage1_pht_index;
    wire [ 1:0] if_s1_stage1_pht_counter;
    wire [ 7:0] id_stage1_pht_index;
    wire [ 1:0] id_stage1_pht_counter;
    wire [ 7:0] id_s1_stage1_pht_index;
    wire [ 1:0] id_s1_stage1_pht_counter;
    wire [ 7:0] ex_stage1_pht_index;
    wire [ 1:0] ex_stage1_pht_counter;
    wire [ 7:0] ex_s1_stage1_pht_index;
    wire [ 1:0] ex_s1_stage1_pht_counter;
    wire        stage1_direction_update_valid;
    wire [ 7:0] stage1_direction_update_index;
    wire [ 1:0] stage1_direction_update_counter;

    wire        abtb_update_valid;
    wire        abtb_update_hit;
    wire        abtb_update_way;
    wire [31:0] abtb_update_pc;
    wire [ 1:0] abtb_update_cfi_type;
    wire [31:0] abtb_update_target;
    wire        stage1_steer_valid;
    wire        stage1_steer_source_abtb;
    wire        stage1_steer_branch_owned;
    wire        stage1_steer_branch_owned_nt;
    wire        stage1_steer_taken;
    wire        stage1_steer_bank;
    wire [ 1:0] stage1_steer_cfi_type;
    wire [31:0] stage1_steer_target;
    wire [31:0] stage1_steer_next_pc;

    wire        s0_pred_update_valid_raw;
    wire        s1_pred_update_valid_raw;
    wire        pred_train_from_s1;
    wire        pred_train_valid;
    wire [31:0] pred_train_pc;
    wire        pred_train_is_branch;
    wire        pred_train_is_jal;
    wire        pred_train_is_jalr;
    wire        pred_train_actual_taken;
    wire [31:0] pred_train_actual_target;

    // ================================================================
    //  Module instantiations
    // ================================================================

    id_stage_derive u_id_stage_derive (
        .id_pc             (id_pc),
        .id_inst           (id_inst),
        .id_inst1          (id_inst1),
        .dec_alu_src1_sel  (dec_alu_src1_sel),
        .dec_alu_src2_sel  (dec_alu_src2_sel),
        .dec_reg_write_en  (dec_reg_write_en),
        .dec_wb_sel        (dec_wb_sel),
        .dec_mem_read_en   (dec_mem_read_en),
        .dec_mem_write_en  (dec_mem_write_en),
        .dec_is_branch     (dec_is_branch),
        .dec_is_jal        (dec_is_jal),
        .dec_is_jalr       (dec_is_jalr),
        .dec_is_csr        (dec_is_csr),
        .dec_csr_uses_rs1  (dec_csr_uses_rs1),
        .dec_is_muldiv     (dec_is_muldiv),
        .dec1_alu_src1_sel (dec1_alu_src1_sel),
        .dec1_alu_src2_sel (dec1_alu_src2_sel),
        .dec1_mem_read_en  (dec1_mem_read_en),
        .dec1_mem_write_en (dec1_mem_write_en),
        .dec1_is_branch    (dec1_is_branch),
        .dec1_is_jal       (dec1_is_jal),
        .dec1_is_jalr      (dec1_is_jalr),
        .dec1_csr_uses_rs1 (dec1_csr_uses_rs1),
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
        .id_alu_src1_is_rs1(id_alu_src1_is_rs1),
        .id_alu_src2_is_rs2(id_alu_src2_is_rs2),
        .id_s1_alu_src1_is_rs1(id_s1_alu_src1_is_rs1),
        .id_s1_alu_src2_is_rs2(id_s1_alu_src2_is_rs2),
        .id_rs1_used       (id_rs1_used),
        .id_rs2_used       (id_rs2_used),
        .id_s1_rs1_used    (id_s1_rs1_used),
        .id_s1_rs2_used    (id_s1_rs2_used),
        .id_s0_alu_only    (id_s0_alu_only),
        .id_s1_repair_ok   (id_s1_repair_ok),
        .id_abtb_update_qualified(id_abtb_update_qualified_w),
        .id_abtb_update_cfi_type (id_abtb_update_cfi_type_w),
        .id_s1_abtb_update_qualified(id_s1_abtb_update_qualified_w),
        .id_s1_abtb_update_cfi_type (id_s1_abtb_update_cfi_type_w)
    );

    // ==================== Branch Predictor ====================

    assign s0_pred_update_valid_raw = ex_valid
                                  & (ex_is_branch | ex_is_jal | ex_is_jalr);
    assign s1_pred_update_valid_raw = ex_s1_valid
                                  & (ex_s1_is_branch | ex_s1_is_jal
                                   | ex_s1_is_jalr);
    assign pred_train_from_s1 = ~s0_pred_update_valid_raw
                            & s1_pred_update_valid_raw;
    assign pred_train_valid = (s0_pred_update_valid_raw | s1_pred_update_valid_raw)
                          & ex_ready_go_w
                          & mem_allowin
                          & ~mem_branch_flush;

    assign pred_train_pc            = pred_train_from_s1 ? ex_s1_pc
                                                     : ex_pc;
    assign pred_train_is_branch     = pred_train_from_s1 ? ex_s1_is_branch
                                                     : ex_is_branch;
    assign pred_train_is_jal        = pred_train_from_s1 ? ex_s1_is_jal
                                                     : ex_is_jal;
    assign pred_train_is_jalr       = pred_train_from_s1 ? ex_s1_is_jalr
                                                         : ex_is_jalr;
    assign pred_train_actual_taken  = pred_train_from_s1 ? ex_s1_actual_taken
                                                     : actual_taken;
    assign pred_train_actual_target = pred_train_from_s1 ? ex_s1_branch_target
                                                     : actual_target;

    // ABTB/PHT reuse the existing EX slot arbitration, unified pipeline-fire
    // qualification, and wrong-path suppression. A not-taken branch does not
    // write ABTB.
    wire abtb_train_update_qualified =
        pred_train_from_s1 ? ex_s1_abtb_update_qualified
                         : ex_abtb_update_qualified;
    wire [1:0] abtb_train_update_cfi_type =
        pred_train_from_s1 ? ex_s1_abtb_update_cfi_type
                         : ex_abtb_update_cfi_type;
    wire abtb_train_is_branch =
        abtb_train_update_cfi_type == ABTB_TYPE_BRANCH;
    wire abtb_train_write_qualified =
        abtb_train_update_qualified
        & (!abtb_train_is_branch | pred_train_actual_taken);

    assign abtb_update_valid = pred_train_valid
                             & abtb_train_write_qualified;
    assign abtb_update_hit = pred_train_from_s1 ? ex_s1_abtb_hit
                                               : ex_abtb_hit;
    assign abtb_update_way = pred_train_from_s1 ? ex_s1_abtb_way
                                               : ex_abtb_way;
    assign abtb_update_pc = pred_train_pc;
    assign abtb_update_cfi_type = abtb_train_update_cfi_type;
    assign abtb_update_target = pred_train_actual_target;
    assign stage1_direction_update_valid =
        pred_train_valid && pred_train_is_branch;
    assign stage1_direction_update_index =
        pred_train_from_s1 ? ex_s1_stage1_pht_index
                         : ex_stage1_pht_index;
    assign stage1_direction_update_counter =
        pred_train_from_s1 ? ex_s1_stage1_pht_counter
                         : ex_stage1_pht_counter;

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && s0_pred_update_valid_raw && s1_pred_update_valid_raw)
            $error("Single predictor update port saw simultaneous slot0 and slot1 control flow");
    end
`endif

    frontend_stage1_direction u_frontend_stage1_direction (
        .clk                 (clk),
        .rst_n               (rst_n),
        .predict_pc          (pc),
        .lookup_ghr          (stage1_lookup_ghr),
        .bank0_index         (stage1_bank0_pht_index),
        .bank0_counter       (stage1_bank0_pht_counter),
        .bank0_taken         (stage1_bank0_pht_taken),
        .bank1_index         (stage1_bank1_pht_index),
        .bank1_counter       (stage1_bank1_pht_counter),
        .bank1_taken         (stage1_bank1_pht_taken),
        .update_valid        (stage1_direction_update_valid),
        .update_index        (stage1_direction_update_index),
        .update_counter      (stage1_direction_update_counter),
        .update_actual_taken (pred_train_actual_taken),
        .committed_ghr       (stage1_committed_ghr)
    );

`ifdef ABTB_MEASUREMENT
    (* dont_touch = "true" *)
`endif
    frontend_abtb u_frontend_abtb (
        .clk                  (clk),
        .rst_n                (rst_n),
        .lookup_valid         (abtb_lookup_accept),
        .predict_pc           (pc),
        .bank0_branch_taken   (stage1_bank0_pht_taken),
        .bank1_branch_taken   (stage1_bank1_pht_taken),
        .bank0_ret_valid      (1'b0),
        .bank0_ret_target     (32'd0),
        .bank1_ret_valid      (1'b0),
        .bank1_ret_target     (32'd0),
        .bank0_eligible       (),
        .bank0_lookup_hit     (abtb_bank0_lookup_hit),
        .bank0_hit            (abtb_bank0_hit),
        .bank0_way            (abtb_bank0_way),
        .bank0_cfi_type       (abtb_bank0_cfi_type),
        .bank0_target         (abtb_bank0_target),
        .bank0_pred_taken     (abtb_bank0_pred_taken),
        .bank0_pred_target    (abtb_bank0_pred_target),
        .bank1_eligible       (),
        .bank1_lookup_hit     (abtb_bank1_lookup_hit),
        .bank1_hit            (abtb_bank1_hit),
        .bank1_way            (abtb_bank1_way),
        .bank1_cfi_type       (abtb_bank1_cfi_type),
        .bank1_target         (abtb_bank1_target),
        .bank1_pred_taken     (abtb_bank1_pred_taken),
        .bank1_pred_target    (abtb_bank1_pred_target),
        .pred_taken           (abtb_shadow_pred_taken),
        .pred_bank            (abtb_shadow_pred_bank),
        .pred_cfi_type        (abtb_shadow_pred_cfi_type),
        .pred_target          (abtb_shadow_pred_target),
        .pred_next_pc         (abtb_shadow_pred_next_pc),
        .update_valid         (abtb_update_valid),
        .update_hit           (abtb_update_hit),
        .update_way           (abtb_update_way),
        .update_pc            (abtb_update_pc),
        .update_cfi_type      (abtb_update_cfi_type),
        .update_target        (abtb_update_target)
    );

`ifdef CPU_TOP_ABTB_OBSERVE
    // Shadow observability. In production synthesis this block is removed; in
    // simulation and ABTB measurement builds these counters do not feed
    // prediction, queue ready/valid, or redirect control.
    logic [31:0] abtb_lookup_block_count;
    logic [31:0] abtb_bank0_hit_count;
    logic [31:0] abtb_bank1_hit_count;
    logic [31:0] abtb_ex_update_count;
    logic [31:0] abtb_allocation_count;
    logic [31:0] abtb_hit_update_count;
    logic [31:0] abtb_direct_lookup_count;
    logic [31:0] abtb_direct_steer_count;
    logic [31:0] abtb_direct_bank0_count;
    logic [31:0] abtb_direct_bank1_count;
    logic [31:0] abtb_direct_correct_count;
    logic [31:0] abtb_direct_redirect_count;
    logic [31:0] abtb_direct_target_miss_count;
    logic [31:0] stage1_sequential_count;
    logic [31:0] stage1_abtb_owned_count;
    logic [31:0] stage1_branch_owned_nt_count;
    logic [31:0] stage1_confirmed_branch_count;
    logic [31:0] stage1_abtb_branch_hit_count;
    logic [31:0] stage1_pht_taken_count;
    logic [31:0] stage1_pht_not_taken_count;
    logic [31:0] stage1_pht_correct_count;
    logic [31:0] stage1_pht_wrong_count;
    logic [31:0] stage1_bank0_branch_lookup_count;
    logic [31:0] stage1_bank1_branch_lookup_count;

    wire abtb_direct_s0_resolve = ex_valid
                                && ex_pred_source_abtb
                                && ex_ready_go_w
                                && mem_allowin
                                && !mem_branch_flush;
    wire abtb_direct_s1_resolve = ex_s1_valid
                                && ex_s1_pred_source_abtb
                                && ex_ready_go_w
                                && mem_allowin
                                && !mem_branch_flush
                                && !s0_pred_update_valid_raw;
    wire abtb_direct_s0_target_miss =
        abtb_direct_s0_resolve && actual_taken && ex_pred_taken
        && (actual_target != ex_pred_target);
    wire abtb_direct_s1_target_miss =
        abtb_direct_s1_resolve && ex_s1_actual_taken && ex_s1_pred_taken
        && (ex_s1_branch_target != ex_s1_pred_target);
    wire stage1_bank0_branch_lookup_event =
        abtb_lookup_accept
        && abtb_bank0_hit
        && (abtb_bank0_cfi_type == ABTB_TYPE_BRANCH);
    wire stage1_bank1_branch_lookup_event =
        abtb_lookup_accept
        && abtb_bank1_hit
        && (abtb_bank1_cfi_type == ABTB_TYPE_BRANCH);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            abtb_lookup_block_count <= 32'd0;
            abtb_bank0_hit_count <= 32'd0;
            abtb_bank1_hit_count <= 32'd0;
            abtb_ex_update_count <= 32'd0;
            abtb_allocation_count <= 32'd0;
            abtb_hit_update_count <= 32'd0;
            abtb_direct_lookup_count <= 32'd0;
            abtb_direct_steer_count <= 32'd0;
            abtb_direct_bank0_count <= 32'd0;
            abtb_direct_bank1_count <= 32'd0;
            abtb_direct_correct_count <= 32'd0;
            abtb_direct_redirect_count <= 32'd0;
            abtb_direct_target_miss_count <= 32'd0;
            stage1_sequential_count <= 32'd0;
            stage1_abtb_owned_count <= 32'd0;
            stage1_branch_owned_nt_count <= 32'd0;
            stage1_confirmed_branch_count <= 32'd0;
            stage1_abtb_branch_hit_count <= 32'd0;
            stage1_pht_taken_count <= 32'd0;
            stage1_pht_not_taken_count <= 32'd0;
            stage1_pht_correct_count <= 32'd0;
            stage1_pht_wrong_count <= 32'd0;
            stage1_bank0_branch_lookup_count <= 32'd0;
            stage1_bank1_branch_lookup_count <= 32'd0;
        end else begin
            if (abtb_lookup_accept)
                abtb_lookup_block_count <= abtb_lookup_block_count + 32'd1;
            if (abtb_lookup_accept && abtb_bank0_hit)
                abtb_bank0_hit_count <= abtb_bank0_hit_count + 32'd1;
            if (abtb_lookup_accept && abtb_bank1_hit)
                abtb_bank1_hit_count <= abtb_bank1_hit_count + 32'd1;
            if (abtb_update_valid)
                abtb_ex_update_count <= abtb_ex_update_count + 32'd1;
            if (abtb_update_valid && !abtb_update_hit)
                abtb_allocation_count <= abtb_allocation_count + 32'd1;
            if (abtb_update_valid && abtb_update_hit)
                abtb_hit_update_count <= abtb_hit_update_count + 32'd1;
            if (stage1_steer_valid)
                abtb_direct_lookup_count <= abtb_direct_lookup_count + 32'd1;
            if (stage1_steer_valid && stage1_steer_source_abtb) begin
                abtb_direct_steer_count <= abtb_direct_steer_count + 32'd1;
                if (stage1_steer_bank)
                    abtb_direct_bank1_count <= abtb_direct_bank1_count + 32'd1;
                else
                    abtb_direct_bank0_count <= abtb_direct_bank0_count + 32'd1;
            end
            if (stage1_steer_valid
                && (stage1_steer_source_abtb || stage1_steer_branch_owned))
                stage1_abtb_owned_count <= stage1_abtb_owned_count + 32'd1;
            if (stage1_steer_valid && stage1_steer_branch_owned_nt)
                stage1_branch_owned_nt_count <=
                    stage1_branch_owned_nt_count + 32'd1;
            if (stage1_steer_valid
                && !stage1_steer_source_abtb
                && !stage1_steer_branch_owned)
                stage1_sequential_count <= stage1_sequential_count + 32'd1;
            if (stage1_bank0_branch_lookup_event)
                stage1_bank0_branch_lookup_count <=
                    stage1_bank0_branch_lookup_count + 32'd1;
            if (stage1_bank1_branch_lookup_event)
                stage1_bank1_branch_lookup_count <=
                    stage1_bank1_branch_lookup_count + 32'd1;
            if (stage1_bank0_branch_lookup_event
                || stage1_bank1_branch_lookup_event)
                stage1_abtb_branch_hit_count <=
                    stage1_abtb_branch_hit_count
                    + {31'd0, stage1_bank0_branch_lookup_event}
                    + {31'd0, stage1_bank1_branch_lookup_event};
            if ((stage1_bank0_branch_lookup_event
                 && stage1_bank0_pht_taken)
                || (stage1_bank1_branch_lookup_event
                    && stage1_bank1_pht_taken))
                stage1_pht_taken_count <=
                    stage1_pht_taken_count
                    + {31'd0, stage1_bank0_branch_lookup_event
                               && stage1_bank0_pht_taken}
                    + {31'd0, stage1_bank1_branch_lookup_event
                               && stage1_bank1_pht_taken};
            if ((stage1_bank0_branch_lookup_event
                 && !stage1_bank0_pht_taken)
                || (stage1_bank1_branch_lookup_event
                    && !stage1_bank1_pht_taken))
                stage1_pht_not_taken_count <=
                    stage1_pht_not_taken_count
                    + {31'd0, stage1_bank0_branch_lookup_event
                               && !stage1_bank0_pht_taken}
                    + {31'd0, stage1_bank1_branch_lookup_event
                               && !stage1_bank1_pht_taken};
            if (stage1_direction_update_valid) begin
                stage1_confirmed_branch_count <=
                    stage1_confirmed_branch_count + 32'd1;
                if (stage1_direction_update_counter[1]
                    == pred_train_actual_taken)
                    stage1_pht_correct_count <=
                        stage1_pht_correct_count + 32'd1;
                else
                    stage1_pht_wrong_count <=
                        stage1_pht_wrong_count + 32'd1;
            end
            if (abtb_direct_s0_resolve) begin
                if (branch_flush)
                    abtb_direct_redirect_count <=
                        abtb_direct_redirect_count + 32'd1;
                else
                    abtb_direct_correct_count <=
                        abtb_direct_correct_count + 32'd1;
            end else if (abtb_direct_s1_resolve) begin
                if (ex_s1_branch_redirect)
                    abtb_direct_redirect_count <=
                        abtb_direct_redirect_count + 32'd1;
                else
                    abtb_direct_correct_count <=
                        abtb_direct_correct_count + 32'd1;
            end
            if (abtb_direct_s0_target_miss || abtb_direct_s1_target_miss)
                abtb_direct_target_miss_count <=
                    abtb_direct_target_miss_count + 32'd1;
        end
    end

`ifdef ABTB_MEASUREMENT
    // Measurement-only sink. It keeps the shadow ABTB, F0 capture, FQ sidecar,
    // IF/ID, ID/EX, and EX update signals observable in the integrated timing
    // build without feeding any production PC, redirect, ready/valid, or IROM
    // steering path.
    localparam int ABTB_MEASUREMENT_SINK_W = 920;
    (* keep = "true" *)
    wire [ABTB_MEASUREMENT_SINK_W-1:0] abtb_measurement_sink_d = {
        pc,
        abtb_lookup_accept,
        abtb_bank0_hit,
        abtb_bank0_way,
        abtb_bank0_cfi_type,
        abtb_bank0_target,
        abtb_bank0_pred_taken,
        abtb_bank0_pred_target,
        abtb_bank1_hit,
        abtb_bank1_way,
        abtb_bank1_cfi_type,
        abtb_bank1_target,
        abtb_bank1_pred_taken,
        abtb_bank1_pred_target,
        abtb_shadow_pred_taken,
        abtb_shadow_pred_bank,
        abtb_shadow_pred_cfi_type,
        abtb_shadow_pred_target,
        abtb_shadow_pred_next_pc,
        if_abtb_hit_out,
        if_abtb_way_out,
        if_abtb_cfi_type_out,
        if_abtb_target_out,
        if_abtb_pred_taken_out,
        if_abtb_pred_target_out,
        if_s1_abtb_hit_out,
        if_s1_abtb_way_out,
        if_s1_abtb_cfi_type_out,
        if_s1_abtb_target_out,
        if_s1_abtb_pred_taken_out,
        if_s1_abtb_pred_target_out,
        id_abtb_hit,
        id_abtb_way,
        id_abtb_cfi_type,
        id_abtb_target,
        id_abtb_pred_taken,
        id_abtb_pred_target,
        id_s1_abtb_hit,
        id_s1_abtb_way,
        id_s1_abtb_cfi_type,
        id_s1_abtb_target,
        id_s1_abtb_pred_taken,
        id_s1_abtb_pred_target,
        ex_abtb_hit,
        ex_abtb_way,
        ex_abtb_cfi_type,
        ex_abtb_target,
        ex_abtb_pred_taken,
        ex_abtb_pred_target,
        ex_abtb_update_qualified,
        ex_abtb_update_cfi_type,
        ex_s1_abtb_hit,
        ex_s1_abtb_way,
        ex_s1_abtb_cfi_type,
        ex_s1_abtb_target,
        ex_s1_abtb_pred_taken,
        ex_s1_abtb_pred_target,
        ex_s1_abtb_update_qualified,
        ex_s1_abtb_update_cfi_type,
        abtb_update_valid,
        abtb_update_hit,
        abtb_update_way,
        abtb_update_pc,
        abtb_update_cfi_type,
        abtb_update_target,
        abtb_lookup_block_count,
        abtb_bank0_hit_count,
        abtb_bank1_hit_count,
        abtb_ex_update_count,
        abtb_allocation_count,
        abtb_hit_update_count
    };

    (* dont_touch = "true" *)
    logic [ABTB_MEASUREMENT_SINK_W-1:0] abtb_measurement_sink_q;

    always_ff @(posedge clk) begin
        if (!rst_n)
            abtb_measurement_sink_q <= '0;
        else
            abtb_measurement_sink_q <= abtb_measurement_sink_d;
    end
`endif
`endif

    // ==================== Pre-IF ====================

    wire        can_dual_issue;
    wire        can_dual_fetch;
    wire        raw_pair_raw;
    wire        raw_inst1_is_alu_type;
    wire        raw_inst0_is_jump;
    logic       predict_dual;

    wire [31:0] if_inst0_out;
    wire [31:0] if_inst1_out;
    wire [31:0] if_pc_out;
    wire        if_pred_taken_out;
    wire [31:0] if_pred_target_out;
    wire        if_s1_pred_taken_out;
    wire [31:0] if_s1_pred_target_out;
    wire        if_skip_out;
    wire        if_s1_valid;
    wire        if_sequential_fetch;
    wire        inst_buf_valid_next;

    assign irom_inst0 = irom_data[31:0];
    assign irom_inst1 = irom_data[63:32];

    assign can_dual_fetch = can_dual_issue;
    assign raw_inst1_is_alu_type = 1'b0;
    assign raw_inst0_is_jump = 1'b0;
    assign if_sequential_fetch = ~if_pred_taken_out;
    assign inst_buf_valid_next = 1'b0;
    assign inst_buf = 32'd0;
    assign inst_buf_pc = 32'd0;
    assign inst_buf_valid = 1'b0;
    assign skip_inst0_valid = 1'b0;
    assign if_buf_before_window = 1'b0;

    frontend_ftq u_frontend_ftq (
        .clk              (clk),
        .rst_n            (rst_n),
        .id_allowin       (id_allowin),
        .ex_redirect_valid(frontend_branch_flush),
        .ex_redirect_target(frontend_branch_target),
        .irom_addr        (irom_addr),
        .irom_data        (irom_data),
        .abtb_bank0_lookup_hit  (abtb_bank0_lookup_hit),
        .abtb_bank0_hit         (abtb_bank0_hit),
        .abtb_bank0_way         (abtb_bank0_way),
        .abtb_bank0_cfi_type    (abtb_bank0_cfi_type),
        .abtb_bank0_target      (abtb_bank0_target),
        .abtb_bank0_pred_taken  (abtb_bank0_pred_taken),
        .abtb_bank0_pred_target (abtb_bank0_pred_target),
        .abtb_bank1_lookup_hit  (abtb_bank1_lookup_hit),
        .abtb_bank1_hit         (abtb_bank1_hit),
        .abtb_bank1_way         (abtb_bank1_way),
        .abtb_bank1_cfi_type    (abtb_bank1_cfi_type),
        .abtb_bank1_target      (abtb_bank1_target),
        .abtb_bank1_pred_taken  (abtb_bank1_pred_taken),
        .abtb_bank1_pred_target (abtb_bank1_pred_target),
        .stage1_bank0_pht_index(stage1_bank0_pht_index),
        .stage1_bank0_pht_counter(stage1_bank0_pht_counter),
        .stage1_bank1_pht_index(stage1_bank1_pht_index),
        .stage1_bank1_pht_counter(stage1_bank1_pht_counter),
        .if_valid         (if_valid),
        .if_ready_go      (if_ready_go_w),
        .if_pc            (if_pc_out),
        .if_inst0         (if_inst0_out),
        .if_inst1         (if_inst1_out),
        .if_s1_valid      (if_s1_valid),
        .if_pred_taken      (if_pred_taken_out),
        .if_pred_target     (if_pred_target_out),
        .if_pred_source_abtb(if_pred_source_abtb_out),
        .if_stage1_branch_owned(if_stage1_branch_owned_out),
        .if_s1_pred_taken   (if_s1_pred_taken_out),
        .if_s1_pred_target  (if_s1_pred_target_out),
        .if_s1_pred_source_abtb(if_s1_pred_source_abtb_out),
        .if_s1_stage1_branch_owned(if_s1_stage1_branch_owned_out),
        .if_abtb_hit         (if_abtb_hit_out),
        .if_abtb_way         (if_abtb_way_out),
        .if_abtb_cfi_type    (if_abtb_cfi_type_out),
        .if_abtb_target      (if_abtb_target_out),
        .if_abtb_pred_taken  (if_abtb_pred_taken_out),
        .if_abtb_pred_target (if_abtb_pred_target_out),
        .if_s1_abtb_hit         (if_s1_abtb_hit_out),
        .if_s1_abtb_way         (if_s1_abtb_way_out),
        .if_s1_abtb_cfi_type    (if_s1_abtb_cfi_type_out),
        .if_s1_abtb_target      (if_s1_abtb_target_out),
        .if_s1_abtb_pred_taken  (if_s1_abtb_pred_taken_out),
        .if_s1_abtb_pred_target (if_s1_abtb_pred_target_out),
        .if_stage1_pht_index(if_stage1_pht_index),
        .if_stage1_pht_counter(if_stage1_pht_counter),
        .if_s1_stage1_pht_index(if_s1_stage1_pht_index),
        .if_s1_stage1_pht_counter(if_s1_stage1_pht_counter),
        .current_pc       (pc),
        .abtb_lookup_accept(abtb_lookup_accept),
        .stage1_steer_valid(stage1_steer_valid),
        .stage1_steer_source_abtb(stage1_steer_source_abtb),
        .stage1_steer_branch_owned(stage1_steer_branch_owned),
        .stage1_steer_branch_owned_nt(stage1_steer_branch_owned_nt),
        .stage1_steer_taken(stage1_steer_taken),
        .stage1_steer_bank(stage1_steer_bank),
        .stage1_steer_cfi_type(stage1_steer_cfi_type),
        .stage1_steer_target(stage1_steer_target),
        .stage1_steer_next_pc(stage1_steer_next_pc),
        .can_dual_issue   (can_dual_issue),
        .raw_pair_raw     (raw_pair_raw),
        .predict_dual     (predict_dual),
        .irom_held_valid  (irom_held_valid),
        .if_skip_out      (if_skip_out)
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
        .if_pred_taken    (if_pred_taken_out),
        .if_pred_target   (if_pred_target_out),
        .if_pred_source_abtb(if_pred_source_abtb_out),
        .if_stage1_branch_owned(if_stage1_branch_owned_out),
        .if_s1_pred_taken    (if_s1_pred_taken_out),
        .if_s1_pred_target   (if_s1_pred_target_out),
        .if_s1_pred_source_abtb(if_s1_pred_source_abtb_out),
        .if_s1_stage1_branch_owned(if_s1_stage1_branch_owned_out),
        .if_abtb_hit         (if_abtb_hit_out),
        .if_abtb_way         (if_abtb_way_out),
        .if_abtb_cfi_type    (if_abtb_cfi_type_out),
        .if_abtb_target      (if_abtb_target_out),
        .if_abtb_pred_taken  (if_abtb_pred_taken_out),
        .if_abtb_pred_target (if_abtb_pred_target_out),
        .if_s1_abtb_hit         (if_s1_abtb_hit_out),
        .if_s1_abtb_way         (if_s1_abtb_way_out),
        .if_s1_abtb_cfi_type    (if_s1_abtb_cfi_type_out),
        .if_s1_abtb_target      (if_s1_abtb_target_out),
        .if_s1_abtb_pred_taken  (if_s1_abtb_pred_taken_out),
        .if_s1_abtb_pred_target (if_s1_abtb_pred_target_out),
        .if_stage1_pht_index(if_stage1_pht_index),
        .if_stage1_pht_counter(if_stage1_pht_counter),
        .if_s1_stage1_pht_index(if_s1_stage1_pht_index),
        .if_s1_stage1_pht_counter(if_s1_stage1_pht_counter),
        .id_pred_taken    (id_pred_taken),
        .id_pred_target   (id_pred_target),
        .id_pred_source_abtb(id_pred_source_abtb),
        .id_stage1_branch_owned(id_stage1_branch_owned),
        .id_s1_pred_taken    (id_s1_pred_taken),
        .id_s1_pred_target   (id_s1_pred_target),
        .id_s1_pred_source_abtb(id_s1_pred_source_abtb),
        .id_s1_stage1_branch_owned(id_s1_stage1_branch_owned),
        .id_abtb_hit         (id_abtb_hit),
        .id_abtb_way         (id_abtb_way),
        .id_abtb_cfi_type    (id_abtb_cfi_type),
        .id_abtb_target      (id_abtb_target),
        .id_abtb_pred_taken  (id_abtb_pred_taken),
        .id_abtb_pred_target (id_abtb_pred_target),
        .id_s1_abtb_hit         (id_s1_abtb_hit),
        .id_s1_abtb_way         (id_s1_abtb_way),
        .id_s1_abtb_cfi_type    (id_s1_abtb_cfi_type),
        .id_s1_abtb_target      (id_s1_abtb_target),
        .id_s1_abtb_pred_taken  (id_s1_abtb_pred_taken),
        .id_s1_abtb_pred_target (id_s1_abtb_pred_target),
        .id_stage1_pht_index(id_stage1_pht_index),
        .id_stage1_pht_counter(id_stage1_pht_counter),
        .id_s1_stage1_pht_index(id_s1_stage1_pht_index),
        .id_s1_stage1_pht_counter(id_s1_stage1_pht_counter)
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
        .id_s0_mem_read (dec_mem_read_en),
        .id_s0_mem_write(dec_mem_write_en),
        .rf_rs1_data    (rf_rs1_data),
        .rf_rs2_data    (rf_rs2_data),
        .id_s1_valid    (id_s1_valid),
        .id_s1_rs1_addr (id_s1_rs1_addr),
        .id_s1_rs2_addr (id_s1_rs2_addr),
        .id_s1_rs1_used (id_s1_rs1_used),
        .id_s1_rs2_used (id_s1_rs2_used),
        .id_s1_repair_ok(id_s1_repair_ok),
        .rf_s1_rs1_data (rf_s1_rs1_data),
        .rf_s1_rs2_data (rf_s1_rs2_data),
        .ex_valid       (ex_valid),
        .ex_reg_write   (ex_reg_write_en & (~ex_is_muldiv | muldiv_done)),
        .ex_mem_read    (ex_mem_read_en),
        .ex_rd          (ex_rd),
        .ex_alu_result  (ex_forward_result),
        .ex_pc_plus_4   (ex_pc_plus_4),
        .ex_wb_sel      (ex_wb_sel),
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
        .id_s1_rs1_data (fwd_s1_rs1_data),
        .id_s1_rs2_data (fwd_s1_rs2_data),
        .id_rs1_wb_repair(fwd_rs1_wb_repair),
        .id_rs2_wb_repair(fwd_rs2_wb_repair),
        .id_rs1_wb_repair_s1(fwd_rs1_wb_repair_s1),
        .id_rs2_wb_repair_s1(fwd_rs2_wb_repair_s1),
        .id_s1_rs1_wb_repair(fwd_s1_rs1_wb_repair),
        .id_s1_rs2_wb_repair(fwd_s1_rs2_wb_repair),
        .id_s1_rs1_wb_repair_s1(fwd_s1_rs1_wb_repair_s1),
        .id_s1_rs2_wb_repair_s1(fwd_s1_rs2_wb_repair_s1),
        .id_ready_go    (id_ready_go_raw)
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
        .id_rs1_wb_repair_s1(fwd_rs1_wb_repair_s1),
        .id_rs2_wb_repair_s1(fwd_rs2_wb_repair_s1),
        .id_rd            (id_rd_addr),
        .id_rs1_addr      (id_rs1_addr),
        .id_rs2_addr      (id_rs2_addr),
        .id_alu_src1_is_rs1(id_alu_src1_is_rs1),
        .id_alu_src2_is_rs2(id_alu_src2_is_rs2),
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
        .id_is_csr        (dec_is_csr),
        .id_csr_uses_imm  (dec_csr_uses_imm),
        .id_csr_cmd       (id_csr_cmd),
        .id_csr_addr      (id_csr_addr),
        .id_is_ecall      (dec_is_ecall),
        .id_is_mret       (dec_is_mret),
        .id_is_muldiv     (dec_is_muldiv),
        .id_muldiv_op     (id_inst[14:12]),
        // Stage-1 canonical prediction passthrough.
        .id_pred_taken      (id_pred_taken),
        .id_pred_target     (id_pred_target),
        .id_pred_source_abtb(id_pred_source_abtb),
        .id_stage1_branch_owned(id_stage1_branch_owned),
        .id_abtb_hit         (id_abtb_hit),
        .id_abtb_way         (id_abtb_way),
        .id_abtb_cfi_type    (id_abtb_cfi_type),
        .id_abtb_target      (id_abtb_target),
        .id_abtb_pred_taken  (id_abtb_pred_taken),
        .id_abtb_pred_target (id_abtb_pred_target),
        .id_abtb_update_qualified(id_abtb_update_qualified_w),
        .id_abtb_update_cfi_type (id_abtb_update_cfi_type_w),
        .id_stage1_pht_index(id_stage1_pht_index),
        .id_stage1_pht_counter(id_stage1_pht_counter),
        .ex_pc            (ex_pc),
        .ex_alu_src1      (ex_alu_src1),
        .ex_alu_src2      (ex_alu_src2),
        .ex_rs1_data      (ex_rs1_data),
        .ex_rs2_data      (ex_rs2_data),
        .ex_rs1_wb_repair (ex_rs1_wb_repair),
        .ex_rs2_wb_repair (ex_rs2_wb_repair),
        .ex_rs1_wb_repair_s1(ex_rs1_wb_repair_s1),
        .ex_rs2_wb_repair_s1(ex_rs2_wb_repair_s1),
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
        // Branch prediction out
        .ex_pred_taken      (ex_pred_taken),
        .ex_pred_target     (ex_pred_target),
        .ex_pred_source_abtb(ex_pred_source_abtb),
        .ex_stage1_branch_owned(ex_stage1_branch_owned),
        .ex_abtb_hit         (ex_abtb_hit),
        .ex_abtb_way         (ex_abtb_way),
        .ex_abtb_cfi_type    (ex_abtb_cfi_type),
        .ex_abtb_target      (ex_abtb_target),
        .ex_abtb_pred_taken  (ex_abtb_pred_taken),
        .ex_abtb_pred_target (ex_abtb_pred_target),
        .ex_abtb_update_qualified(ex_abtb_update_qualified),
        .ex_abtb_update_cfi_type (ex_abtb_update_cfi_type),
        .ex_stage1_pht_index(ex_stage1_pht_index),
        .ex_stage1_pht_counter(ex_stage1_pht_counter)
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
        .id_alu_src1         (id_s1_alu_src1),
        .id_alu_src2         (id_s1_alu_src2),
        .id_rs1_data         (fwd_s1_rs1_data),
        .id_rs2_data         (fwd_s1_rs2_data),
        .id_rs1_wb_repair    (fwd_s1_rs1_wb_repair),
        .id_rs2_wb_repair    (fwd_s1_rs2_wb_repair),
        .id_rs1_wb_repair_s1 (fwd_s1_rs1_wb_repair_s1),
        .id_rs2_wb_repair_s1 (fwd_s1_rs2_wb_repair_s1),
        .id_rd               (id_s1_rd_addr),
        .id_rs1_addr         (id_s1_rs1_addr),
        .id_rs2_addr         (id_s1_rs2_addr),
        .id_alu_src1_is_rs1  (id_s1_alu_src1_is_rs1),
        .id_alu_src2_is_rs2  (id_s1_alu_src2_is_rs2),
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
        .id_pred_taken         (id_s1_pred_taken),
        .id_pred_target        (id_s1_pred_target),
        .id_pred_source_abtb (id_s1_pred_source_abtb),
        .id_stage1_branch_owned(id_s1_stage1_branch_owned),
        .id_abtb_hit         (id_s1_abtb_hit),
        .id_abtb_way         (id_s1_abtb_way),
        .id_abtb_cfi_type    (id_s1_abtb_cfi_type),
        .id_abtb_target      (id_s1_abtb_target),
        .id_abtb_pred_taken  (id_s1_abtb_pred_taken),
        .id_abtb_pred_target (id_s1_abtb_pred_target),
        .id_abtb_update_qualified(id_s1_abtb_update_qualified_w),
        .id_abtb_update_cfi_type (id_s1_abtb_update_cfi_type_w),
        .id_stage1_pht_index(id_s1_stage1_pht_index),
        .id_stage1_pht_counter(id_s1_stage1_pht_counter),
        .ex_s1_valid         (ex_s1_valid),
        .ex_s1_pc            (ex_s1_pc),
        .ex_s1_inst          (ex_s1_inst),
        .ex_s1_alu_src1      (ex_s1_alu_src1),
        .ex_s1_alu_src2      (ex_s1_alu_src2),
        .ex_s1_rs1_data      (ex_s1_rs1_data),
        .ex_s1_rs2_data      (ex_s1_rs2_data),
        .ex_s1_rs1_wb_repair (ex_s1_rs1_wb_repair),
        .ex_s1_rs2_wb_repair (ex_s1_rs2_wb_repair),
        .ex_s1_rs1_wb_repair_s1(ex_s1_rs1_wb_repair_s1),
        .ex_s1_rs2_wb_repair_s1(ex_s1_rs2_wb_repair_s1),
        .ex_s1_rd            (ex_s1_rd),
        .ex_s1_rs1_addr      (ex_s1_rs1_addr),
        .ex_s1_rs2_addr      (ex_s1_rs2_addr),
        .ex_s1_alu_src1_is_rs1(ex_s1_alu_src1_is_rs1),
        .ex_s1_alu_src2_is_rs2(ex_s1_alu_src2_is_rs2),
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
        .ex_s1_is_jalr       (ex_s1_is_jalr),
        .ex_s1_pred_taken      (ex_s1_pred_taken),
        .ex_s1_pred_target     (ex_s1_pred_target),
        .ex_s1_pred_source_abtb(ex_s1_pred_source_abtb),
        .ex_s1_stage1_branch_owned(ex_s1_stage1_branch_owned),
        .ex_s1_abtb_hit         (ex_s1_abtb_hit),
        .ex_s1_abtb_way         (ex_s1_abtb_way),
        .ex_s1_abtb_cfi_type    (ex_s1_abtb_cfi_type),
        .ex_s1_abtb_target      (ex_s1_abtb_target),
        .ex_s1_abtb_pred_taken  (ex_s1_abtb_pred_taken),
        .ex_s1_abtb_pred_target (ex_s1_abtb_pred_target),
        .ex_s1_abtb_update_qualified(ex_s1_abtb_update_qualified),
        .ex_s1_abtb_update_cfi_type (ex_s1_abtb_update_cfi_type),
        .ex_s1_stage1_pht_index(ex_s1_stage1_pht_index),
        .ex_s1_stage1_pht_counter(ex_s1_stage1_pht_counter)
    );

    // ==================== EX stage ====================
    // MEM-ready load consumers repair their operands from WB here. The
    // repaired result is allowed to feed younger ID consumers after moving CFI
    // target/compare work out of ID.
    ex_stage_ctrl u_ex_stage_ctrl (
        .ex_pc                      (ex_pc),
        .ex_s1_pc                   (ex_s1_pc),
        .ex_valid                   (ex_valid),
        .ex_rs1_wb_repair           (ex_rs1_wb_repair),
        .ex_rs2_wb_repair           (ex_rs2_wb_repair),
        .ex_rs1_wb_repair_s1        (ex_rs1_wb_repair_s1),
        .ex_rs2_wb_repair_s1        (ex_rs2_wb_repair_s1),
        .wb_load_data               (wb_load_data),
        .wb_s1_load_data            (wb_s1_load_data),
        .ex_alu_src1                (ex_alu_src1),
        .ex_alu_src2                (ex_alu_src2),
        .ex_alu_src1_is_rs1         (ex_alu_src1_is_rs1),
        .ex_alu_src2_is_rs2         (ex_alu_src2_is_rs2),
        .ex_rs1_data                (ex_rs1_data),
        .ex_rs2_data                (ex_rs2_data),
        .ex_is_branch               (ex_is_branch),
        .ex_is_jal                  (ex_is_jal),
        .ex_is_jalr                 (ex_is_jalr),
        .ex_is_csr                  (ex_is_csr),
        .ex_csr_rdata               (ex_csr_rdata),
        .ex_is_muldiv               (ex_is_muldiv),
        .ex_muldiv_result           (muldiv_result),
        .alu_result                 (alu_result),
        .ex_s1_valid                (ex_s1_valid),
        .ex_s1_is_branch            (ex_s1_is_branch),
        .ex_s1_is_jal               (ex_s1_is_jal),
        .ex_s1_is_jalr              (ex_s1_is_jalr),
        .ex_s1_branch_cond          (ex_s1_branch_cond),
        .ex_s1_rs1_wb_repair        (ex_s1_rs1_wb_repair),
        .ex_s1_rs2_wb_repair        (ex_s1_rs2_wb_repair),
        .ex_s1_rs1_wb_repair_s1     (ex_s1_rs1_wb_repair_s1),
        .ex_s1_rs2_wb_repair_s1     (ex_s1_rs2_wb_repair_s1),
        .ex_s1_alu_src1             (ex_s1_alu_src1),
        .ex_s1_alu_src2             (ex_s1_alu_src2),
        .ex_s1_alu_src1_is_rs1      (ex_s1_alu_src1_is_rs1),
        .ex_s1_alu_src2_is_rs2      (ex_s1_alu_src2_is_rs2),
        .ex_s1_rs1_data             (ex_s1_rs1_data),
        .ex_s1_rs2_data             (ex_s1_rs2_data),
        .ex_s1_predicted_taken      (ex_s1_pred_taken),
        .ex_s1_predicted_target     (ex_s1_pred_target),
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
        .ex_s1_alu_src1_repair      (ex_s1_alu_src1_repair),
        .ex_s1_alu_src2_repair      (ex_s1_alu_src2_repair),
        .ex_rs1_data_repair         (ex_rs1_data_repair),
        .ex_rs2_data_repair         (ex_rs2_data_repair),
        .ex_s1_rs1_data_repair      (ex_s1_rs1_data_repair),
        .ex_s1_rs2_data_repair      (ex_s1_rs2_data_repair),
        .ex_forward_result          (ex_forward_result),
        .ex_pipe_alu_result         (ex_pipe_alu_result),
        .ex_control_target          (ex_control_target),
        .ex_s1_branch_target        (ex_s1_branch_target),
        .ex_s1_actual_taken         (ex_s1_actual_taken),
        .ex_s1_branch_redirect      (ex_s1_branch_redirect),
        .ex_registered_branch_flush (ex_registered_branch_flush),
        .ex_registered_branch_target(ex_registered_branch_target)
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
        .alu_src1   (ex_s1_alu_src1_repair),
        .alu_src2   (ex_s1_alu_src2_repair),
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
        .timer_irq_pending (timer_irq_pending),
        .timer_irq_take    (timer_irq_take),
        .timer_irq_mepc    (id_pc),
        .ex_system_inst    (ex_system_inst),
        .ex_system_redirect(ex_system_redirect),
        .ex_system_target  (ex_system_target),
        .timer_irq_request (timer_irq_request),
        .timer_irq_redirect(timer_irq_redirect),
        .timer_irq_target  (timer_irq_target),
        .ex_csr_rdata      (ex_csr_rdata)
    );

    branch_unit u_branch_unit (
        .target_pc        (ex_control_target),
        .fallthrough_pc   (ex_pc_plus_4),
        .rs1_data         (ex_rs1_data_repair),
        .rs2_data         (ex_rs2_data_repair),
        .is_branch        (ex_is_branch),
        .branch_cond      (ex_branch_cond),
        .is_jal           (ex_is_jal),
        .is_jalr          (ex_is_jalr),
        .ex_valid         (ex_valid),
        .predicted_taken  (ex_pred_taken),
        .predicted_target (ex_pred_target),
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
        .store_data_in   (ex_rs2_data_repair),
        .store_wea       (dram_wea),
        .store_data_out  (store_data_shifted),
        // Load side (WB stage)
        .load_shift      (wb_load_shift),
        .load_byte_signed(wb_load_byte_signed),
        .load_byte_unsigned(wb_load_byte_unsigned),
        .load_half_signed(wb_load_half_signed),
        .load_half_unsigned(wb_load_half_unsigned),
        .load_word       (wb_load_word),
        .load_dram_dout  (wb_load_rdata),   // from MEM/WB register (cache or mmio)
        .load_data_out   (wb_load_data)
    );

    mem_interface u_mem_interface_s1_load (
        // Store side (EX stage, shares the single LSU when Slot0 is non-LSU)
        .store_valid     (ex_s1_valid),
        .store_en        (ex_s1_mem_write_en),
        .store_addr_low  (alu_s1_addr[1:0]),
        .store_mem_size  (ex_s1_mem_size),
        .store_data_in   (ex_s1_rs2_data_repair),
        .store_wea       (dram_wea_s1),
        .store_data_out  (s1_store_data_shifted),
        // Load side (WB stage)
        .load_shift      (wb_s1_load_shift),
        .load_byte_signed(wb_s1_load_byte_signed),
        .load_byte_unsigned(wb_s1_load_byte_unsigned),
        .load_half_signed(wb_s1_load_half_signed),
        .load_half_unsigned(wb_s1_load_half_unsigned),
        .load_word       (wb_s1_load_word),
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
        .wb_load_shift    (wb_load_shift),
        .wb_load_byte_signed(wb_load_byte_signed),
        .wb_load_byte_unsigned(wb_load_byte_unsigned),
        .wb_load_half_signed(wb_load_half_signed),
        .wb_load_half_unsigned(wb_load_half_unsigned),
        .wb_load_word     (wb_load_word),
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
        .wb_s1_load_shift    (wb_s1_load_shift),
        .wb_s1_load_byte_signed(wb_s1_load_byte_signed),
        .wb_s1_load_byte_unsigned(wb_s1_load_byte_unsigned),
        .wb_s1_load_half_signed(wb_s1_load_half_signed),
        .wb_s1_load_half_unsigned(wb_s1_load_half_unsigned),
        .wb_s1_load_word     (wb_s1_load_word),
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

`ifdef CPU_TOP_ABTB_OBSERVE
`undef CPU_TOP_ABTB_OBSERVE
`endif
