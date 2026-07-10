// ============================================================
// Package: cpu_defs
// Description: 全局常量定义，供所有模块共享
// ============================================================

package cpu_defs;

    // ---- ALU 操作编码: {funct7[5], funct3} ----
    localparam logic [3:0] ALU_ADD  = 4'b0_000;
    localparam logic [3:0] ALU_SUB  = 4'b1_000;
    localparam logic [3:0] ALU_SLL  = 4'b0_001;
    localparam logic [3:0] ALU_SLT  = 4'b0_010;
    localparam logic [3:0] ALU_SLTU = 4'b0_011;
    localparam logic [3:0] ALU_XOR  = 4'b0_100;
    localparam logic [3:0] ALU_SRL  = 4'b0_101;
    localparam logic [3:0] ALU_SRA  = 4'b1_101;
    localparam logic [3:0] ALU_OR   = 4'b0_110;
    localparam logic [3:0] ALU_AND  = 4'b0_111;

    // ---- 立即数类型编码 ----
    localparam logic [2:0] IMM_I = 3'b000;
    localparam logic [2:0] IMM_S = 3'b001;
    localparam logic [2:0] IMM_B = 3'b010;
    localparam logic [2:0] IMM_U = 3'b011;
    localparam logic [2:0] IMM_J = 3'b100;

    // ---- RV32I opcode 编码 ----
    localparam logic [6:0] OP_R_TYPE = 7'b0110011;
    localparam logic [6:0] OP_I_ALU  = 7'b0010011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_SYSTEM = 7'b1110011;
    localparam logic [6:0] OP_FENCE  = 7'b0001111;

    // ---- ABTB control-flow type encoding ----
    localparam logic [1:0] ABTB_TYPE_JAL    = 2'b00;
    localparam logic [1:0] ABTB_TYPE_CALL   = 2'b01;
    localparam logic [1:0] ABTB_TYPE_BRANCH = 2'b10;
    localparam logic [1:0] ABTB_TYPE_RET    = 2'b11;

    // ---- RV32M funct7/funct3 encoding ----
    localparam logic [6:0] MULDIV_FUNCT7 = 7'b0000001;
    localparam logic [2:0] M_OP_MUL    = 3'b000;
    localparam logic [2:0] M_OP_MULH   = 3'b001;
    localparam logic [2:0] M_OP_MULHSU = 3'b010;
    localparam logic [2:0] M_OP_MULHU  = 3'b011;
    localparam logic [2:0] M_OP_DIV    = 3'b100;
    localparam logic [2:0] M_OP_DIVU   = 3'b101;
    localparam logic [2:0] M_OP_REM    = 3'b110;
    localparam logic [2:0] M_OP_REMU   = 3'b111;

    // ---- RV32 bit-manipulation execution operations ----
    // Register/immediate forms with identical semantics share one operation.
    // BM_NONE keeps ordinary RV32I/M instructions on the existing datapath.
    typedef enum logic [5:0] {
        BM_NONE,
        BM_SH1ADD,
        BM_SH2ADD,
        BM_SH3ADD,
        BM_ANDN,
        BM_ORN,
        BM_XNOR,
        BM_CLZ,
        BM_CTZ,
        BM_CPOP,
        BM_MAX,
        BM_MAXU,
        BM_MIN,
        BM_MINU,
        BM_SEXT_B,
        BM_SEXT_H,
        BM_ZEXT_H,
        BM_ROL,
        BM_ROR,
        BM_ORC_B,
        BM_REV8,
        BM_CLMUL,
        BM_CLMULR,
        BM_CLMULH,
        BM_BCLR,
        BM_BEXT,
        BM_BINV,
        BM_BSET,
        BM_PACK,
        BM_PACKH,
        BM_BREV8,
        BM_ZIP,
        BM_UNZIP,
        BM_XPERM4,
        BM_XPERM8
    } bitmanip_op_t;

    // ---- Frontend / IF-ID payloads ----
    // Keep pipeline data grouped by function. Handshake and lane-valid signals
    // remain separate so pipeline control is explicit at every stage boundary.
    typedef struct packed {
        logic        taken;
        logic [31:0] target;
        logic        source_abtb;
        logic        stage1_branch_owned;
        logic        abtb_hit;
        logic        abtb_way;
        logic [ 1:0] abtb_cfi_type;
        logic [31:0] abtb_target;
        logic        abtb_pred_taken;
        logic [31:0] abtb_pred_target;
        logic [ 7:0] stage1_pht_index;
        logic [ 1:0] stage1_pht_counter;
    } prediction_meta_t;

    typedef struct packed {
        logic [31:0]      inst;
        prediction_meta_t prediction;
    } fetch_slot_t;

    typedef struct packed {
        logic [31:0] pc;
        fetch_slot_t slot0;
        fetch_slot_t slot1;
    } if_id_payload_t;

    // ---- Frontend instruction predecode ----
    typedef struct packed {
        // ins type
        logic is_branch;
        logic is_jal;
        logic is_jalr;
        logic is_system;
        logic is_fence;
        logic is_illegal;
        logic is_muldiv;
        logic is_load;
        logic is_store;
        logic is_alu_type;
        logic is_jump;
        logic is_control;
        logic is_lsu;
        logic is_cfi;
        // 寄存器使用情况
        logic writes_rd;
        logic uses_rs1;
        logic uses_rs2;
        // pair logic
        // some ins couldn't be issued with other instructions, so we need to force them to be issued alone.
        // for example, force_signle_slot0 means that the instruction in slot0 should be issued alone, and the instruction in slot1 should be issued as NOP ins.
        logic force_single_slot0; // force_single_slot0=(jalr|system|fence|illegal|muldiv)
        logic force_single_slot1; // force_single_slot1=(system|fence|illegal|muldiv)
    } frontend_predecode_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] inst;
        logic        pred_taken;
        logic [31:0] pred_target;
        logic        pred_source_abtb;
        logic        stage1_branch_owned;
        logic [ 1:0] pred_cfi_type;
        logic [ 7:0] stage1_pht_index;
        logic [ 1:0] stage1_pht_counter;
        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic        is_system;
        logic        is_fence;
        logic        is_illegal;
        logic        is_muldiv;
        logic        is_load;
        logic        is_store;
        logic        is_alu_type;
        logic        writes_rd;
        logic        uses_rs1;
        logic        uses_rs2;
        logic        is_jump;
        logic        is_control;
        logic        is_lsu;
        logic        force_single;
    } frontend_fq_entry_t;

    typedef struct packed {
        logic       branch_owned;
        logic [7:0] pht_index;
        logic [1:0] pht_counter;
    } frontend_f0_bank_meta_t;

    typedef struct packed {
        logic        taken;
        logic        source_abtb;
        logic        bank;
        logic [ 1:0] cfi_type;
        logic [31:0] target;
        logic [31:0] next_pc;
    } frontend_f0_steer_state_t;

    typedef struct packed {
        logic                         valid;
        logic [ 1:0]                  epoch;
        logic [31:0]                  start_pc;
        logic [ 1:0]                  base_mask;
        frontend_f0_steer_state_t     steer;
        frontend_f0_bank_meta_t       bank0_meta;
        frontend_f0_bank_meta_t       bank1_meta;
    } frontend_f0_state_t;

    // Metadata shadowed alongside each fetch-queue entry. The type is always
    // complete so module boundaries and debug probes stay stable; individual
    // implementations may omit the wide fields from synthesized state.
    typedef struct packed {
        logic        hit;
        logic        way;
        logic [ 1:0] cfi_type;
        logic [31:0] target;
        logic        pred_taken;
        logic [31:0] pred_target;
    } frontend_abtb_meta_t;

    typedef struct packed {
        logic       pred_taken;
        logic       force_single;
        logic       is_alu_type;
        logic       is_lsu;
        logic       is_cfi;
        logic       writes_rd;
        logic       uses_rs1;
        logic       uses_rs2;
        logic [4:0] rd;
        logic [4:0] rs1;
        logic [4:0] rs2;
    } frontend_pair_meta_t;

    typedef struct packed {
        logic        lookup_hit;
        logic [ 1:0] cfi_type;
        logic [31:0] target;
        logic        pred_taken;
    } frontend_steer_bank_t;

    typedef struct packed {
        logic        valid;
        logic        source_abtb;
        logic        branch_owned;
        logic        branch_owned_nt;
        logic        taken;
        logic        bank;
        logic [ 1:0] cfi_type;
        logic [31:0] target;
        logic [31:0] next_pc;
    } frontend_steer_result_t;

    // ---- Predictor resolve / training interfaces ----
    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic        actual_taken;
        logic [31:0] actual_target;
        logic        update_qualified;
        logic [ 1:0] update_cfi_type;
        logic        abtb_hit;
        logic        abtb_way;
        logic [ 7:0] pht_index;
        logic [ 1:0] pht_counter;
    } predictor_resolve_t;

    typedef struct packed {
        logic        valid;
        logic        from_slot1;
        logic [31:0] pc;
        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic        actual_taken;
        logic [31:0] actual_target;
    } predictor_train_t;

    typedef struct packed {
        logic        valid;
        logic        hit;
        logic        way;
        logic [31:0] pc;
        logic [ 1:0] cfi_type;
        logic [31:0] target;
    } abtb_update_t;

    typedef struct packed {
        logic       valid;
        logic [7:0] index;
        logic [1:0] counter;
        logic       actual_taken;
    } pht_update_t;

    // ---- Frontend predictor observability interfaces ----
    typedef struct packed {
        logic        hit;
        logic        way;
        logic [ 1:0] cfi_type;
        logic [31:0] target;
        logic        pred_taken;
        logic [31:0] pred_target;
        logic        pht_taken;
    } abtb_lookup_bank_t;

    typedef struct packed {
        logic        pred_taken;
        logic        pred_bank;
        logic [ 1:0] pred_cfi_type;
        logic [31:0] pred_target;
        logic [31:0] pred_next_pc;
    } abtb_shadow_result_t;

    typedef struct packed {
        logic valid;
        logic source_abtb;
        logic branch_owned;
        logic branch_owned_nt;
        logic bank;
    } stage1_steer_event_t;

    typedef struct packed {
        logic [31:0] lookup_block;
        logic [31:0] bank0_hit;
        logic [31:0] bank1_hit;
        logic [31:0] ex_update;
        logic [31:0] allocation;
        logic [31:0] hit_update;
        logic [31:0] direct_lookup;
        logic [31:0] direct_steer;
        logic [31:0] direct_bank0;
        logic [31:0] direct_bank1;
        logic [31:0] direct_correct;
        logic [31:0] direct_redirect;
        logic [31:0] direct_target_miss;
        logic [31:0] stage1_sequential;
        logic [31:0] stage1_abtb_owned;
        logic [31:0] stage1_branch_owned_nt;
        logic [31:0] stage1_confirmed_branch;
        logic [31:0] stage1_abtb_branch_hit;
        logic [31:0] stage1_pht_taken;
        logic [31:0] stage1_pht_not_taken;
        logic [31:0] stage1_pht_correct;
        logic [31:0] stage1_pht_wrong;
        logic [31:0] stage1_bank0_branch_lookup;
        logic [31:0] stage1_bank1_branch_lookup;
    } frontend_abtb_counters_t;

    // ---- ID/EX payloads ----
    typedef struct packed {
        prediction_meta_t prediction;
        logic             update_qualified;
        logic [ 1:0]      update_cfi_type;
    } id_ex_prediction_t;

    typedef struct packed {
        logic [31:0]       pc;
        logic [31:0]       alu_src1;
        logic [31:0]       alu_src2;
        logic [31:0]       rs1_data;
        logic [31:0]       rs2_data;
        logic              rs1_wb_repair;
        logic              rs2_wb_repair;
        logic [ 4:0]       rd;
        logic [ 4:0]       rs1_addr;
        logic [ 4:0]       rs2_addr;
        logic              alu_src1_is_rs1;
        logic              alu_src2_is_rs2;
        logic [ 3:0]       alu_op;
        logic              reg_write_en;
        logic [ 1:0]       wb_sel;
        logic              mem_read_en;
        logic              mem_write_en;
        logic [ 1:0]       mem_size;
        logic              mem_unsigned;
        logic              is_branch;
        logic [ 2:0]       branch_cond;
        logic              is_jal;
        logic              is_jalr;
        id_ex_prediction_t prediction;
    } id_ex_common_t;

    typedef struct packed {
        id_ex_common_t common;
        logic          is_csr;
        logic          csr_uses_imm;
        logic [ 2:0]   csr_cmd;
        logic [11:0]   csr_addr;
        logic          is_ecall;
        logic          is_mret;
        logic          is_muldiv;
        logic [ 2:0]   muldiv_op;
        logic          is_bitmanip;
        bitmanip_op_t  bitmanip_op;
    } id_ex_slot0_t;

    typedef struct packed {
        id_ex_common_t common;
        logic [31:0]   inst;
    } id_ex_slot1_t;

    // ---- EX/MEM payloads ----
    typedef struct packed {
        logic        valid;
        logic [31:0] target;
    } redirect_t;

    typedef struct packed {
        logic [31:0] alu_result;
        logic [31:0] pc;
        logic [31:0] pc_plus_4;
        logic [ 4:0] rd;
        logic        reg_write_en;
        logic [ 1:0] wb_sel;
        logic        mem_read_en;
        logic [ 1:0] mem_size;
        logic        mem_unsigned;
        logic [ 3:0] store_wea;
        logic [31:0] store_data;
        logic        is_cacheable;
    } ex_mem_slot0_t;

    typedef struct packed {
        logic [31:0] pc;
        logic [31:0] inst;
        logic [31:0] alu_result;
        logic [31:0] pc_plus_4;
        logic [ 4:0] rd;
        logic        reg_write_en;
        logic [ 1:0] wb_sel;
        logic        mem_read_en;
        logic        mem_write_en;
        logic [ 1:0] mem_size;
        logic        mem_unsigned;
        logic [ 3:0] store_wea;
        logic [31:0] store_data;
        logic        is_cacheable;
    } ex_mem_slot1_t;

    // ---- MEM/WB payloads ----
    typedef struct packed {
        logic [31:0] alu_result;
        logic [31:0] pc_plus_4;
        logic [ 4:0] rd;
        logic        reg_write_en;
        logic [ 1:0] wb_sel;
        logic        is_load;
        logic [31:0] load_data;
    } mem_wb_slot0_t;

    typedef struct packed {
        logic [31:0] pc;
        logic [31:0] inst;
        logic [31:0] alu_result;
        logic [31:0] pc_plus_4;
        logic [ 4:0] rd;
        logic        reg_write_en;
        logic [ 1:0] wb_sel;
        logic        is_load;
    } mem_wb_slot1_t;

endpackage
