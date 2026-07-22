// ============================================================
// Package: cpu_defs
// Description: 全局常量定义，供所有模块共享
// ============================================================

package cpu_defs;

    // The common pipeline consumes semantic operations only. Instruction
    // encodings live in rtl/isa/<isa>/ and must not leak into this package.
    typedef enum logic [3:0] {
        ALU_ADD  = 4'b0_000,
        ALU_SUB  = 4'b1_000,
        ALU_SLL  = 4'b0_001,
        ALU_SLT  = 4'b0_010,
        ALU_SLTU = 4'b0_011,
        ALU_XOR  = 4'b0_100,
        ALU_SRL  = 4'b0_101,
        ALU_SRA  = 4'b1_101,
        ALU_OR   = 4'b0_110,
        ALU_NOR  = 4'b1_110,
        ALU_AND  = 4'b0_111
    } alu_op_t;

    typedef enum logic [2:0] {
        EXEC_NONE   = 3'd0,
        EXEC_ALU    = 3'd1,
        EXEC_LSU    = 3'd2,
        EXEC_BRANCH = 3'd3,
        EXEC_MULDIV = 3'd4,
        EXEC_PRIV   = 3'd5,
        EXEC_FENCE  = 3'd6
    } exec_unit_t;

    typedef enum logic [1:0] {
        OPERAND_A_SRC0 = 2'b00,
        OPERAND_A_PC   = 2'b01,
        OPERAND_A_ZERO = 2'b10
    } operand_a_sel_t;

    typedef enum logic {
        OPERAND_B_SRC1 = 1'b0,
        OPERAND_B_IMM  = 1'b1
    } operand_b_sel_t;

    typedef enum logic [1:0] {
        WB_EXEC    = 2'b00,
        WB_LOAD    = 2'b01,
        WB_NEXT_PC = 2'b10,
        WB_NONE    = 2'b11
    } wb_src_t;

    typedef enum logic [1:0] {
        MEM_NONE  = 2'b00,
        MEM_LOAD  = 2'b01,
        MEM_STORE = 2'b10
    } mem_cmd_t;

    typedef enum logic [1:0] {
        MEM_BYTE = 2'b00,
        MEM_HALF = 2'b01,
        MEM_WORD = 2'b10
    } mem_size_t;

    // Values are deliberately independent from any ISA encoding even where
    // the bit patterns happen to match the current RISC-V implementation.
    typedef enum logic [2:0] {
        BR_EQ     = 3'b000,
        BR_NE     = 3'b001,
        BR_NONE   = 3'b010,
        BR_ALWAYS = 3'b011,
        BR_LT     = 3'b100,
        BR_GE     = 3'b101,
        BR_LTU    = 3'b110,
        BR_GEU    = 3'b111
    } branch_op_t;

    typedef enum logic [1:0] {
        CF_NONE        = 2'b00,
        CF_CONDITIONAL = 2'b01,
        CF_DIRECT      = 2'b10,
        CF_INDIRECT    = 2'b11
    } control_flow_t;

    typedef enum logic {
        TARGET_PC   = 1'b0,
        TARGET_SRC0 = 1'b1
    } target_base_t;

    typedef enum logic [1:0] {
        CFI_TYPE_JUMP   = 2'b00,
        CFI_TYPE_CALL   = 2'b01,
        CFI_TYPE_BRANCH = 2'b10,
        CFI_TYPE_RETURN = 2'b11
    } cfi_type_t;

    typedef enum logic [2:0] {
        PRIV_NONE    = 3'b000,
        PRIV_REG     = 3'b001,
        PRIV_SYSCALL = 3'b010,
        PRIV_RETURN  = 3'b011,
        // LoongArch stable-counter reads share the privileged result path but
        // are not CSR accesses and remain legal outside PLV0.
        PRIV_COUNTER = 3'b100
    } priv_op_t;

    typedef enum logic [2:0] {
        PRIV_CMD_NONE     = 3'b000,
        PRIV_CMD_WRITE    = 3'b001,
        PRIV_CMD_SET      = 3'b010,
        PRIV_CMD_CLEAR    = 3'b011,
        // LoongArch CSRXCHG uses a register mask and therefore cannot be
        // represented by the RISC-V set/clear commands.
        PRIV_CMD_EXCHANGE = 3'b100
    } priv_cmd_t;

    typedef enum logic [2:0] {
        MULDIV_MUL    = 3'b000,
        MULDIV_MULH   = 3'b001,
        MULDIV_MULHSU = 3'b010,
        MULDIV_MULHU  = 3'b011,
        MULDIV_DIV    = 3'b100,
        MULDIV_DIVU   = 3'b101,
        MULDIV_REM    = 3'b110,
        MULDIV_REMU   = 3'b111
    } muldiv_op_t;

    typedef enum logic [1:0] {
        EXCEPTION_NONE       = 2'b00,
        EXCEPTION_ILLEGAL    = 2'b01,
        EXCEPTION_BREAKPOINT = 2'b10
    } decode_exception_t;

    localparam int PRIV_ADDR_W = 16;
    // ISA adapters expose an opaque bank of architectural state to their
    // platform-specific verification wrappers.  The common core assigns no
    // meaning to individual words, preserving the ISA boundary.
    localparam int PRIV_DEBUG_STATE_WORDS = 27;
    localparam int PRIV_DEBUG_STATE_W = PRIV_DEBUG_STATE_WORDS * 32;

    // One fully decoded architectural instruction. Valid/ready stays outside
    // the payload so every pipeline boundary keeps handshake state explicit.
    typedef struct packed {
        exec_unit_t       exec_unit;
        logic [4:0]       src0_addr;
        logic [4:0]       src1_addr;
        logic [4:0]       dst_addr;
        logic             src0_used;
        logic             src1_used;
        logic             dst_write;
        operand_a_sel_t   operand_a_sel;
        operand_b_sel_t   operand_b_sel;
        logic [31:0]      imm;
        alu_op_t          alu_op;
        wb_src_t          wb_src;
        mem_cmd_t         mem_cmd;
        mem_size_t        mem_size;
        logic             mem_unsigned;
        control_flow_t    control_flow;
        branch_op_t       branch_op;
        target_base_t     target_base;
        logic [1:0]       target_clear_mask;
        logic             cfi_update;
        cfi_type_t        cfi_type;
        priv_op_t         priv_op;
        logic             priv_uses_imm;
        priv_cmd_t        priv_cmd;
        logic [PRIV_ADDR_W-1:0] priv_addr;
        logic [4:0]       priv_imm;
        muldiv_op_t       muldiv_op;
        decode_exception_t exception;
        logic [1:0]       lane_mask;
        logic             block_younger;
        logic             serializing;
    } decoded_uop_t;

    // ---- Frontend / IF-ID payloads ----
    // Keep pipeline data grouped by function. Handshake and lane-valid signals
    // remain separate so pipeline control is explicit at every stage boundary.
    typedef struct packed {
        logic        taken; // 方向
        logic [31:0] target; // 目标地址
        logic        source_abtb; //是否来自于btb
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

    // ISA-neutral dependency metadata carried across IF/ID. The ISA-specific
    // predecoder computes it beside the IROM response, then the queue and
    // IF/ID registers make it available without putting the full decoder in
    // the ID stall/backpressure feedback loop.
    typedef struct packed {
        logic       src0_used;
        logic       src1_used;
        logic [4:0] src0_addr;
        logic [4:0] src1_addr;
        logic       dst_write;
        logic [4:0] dst_addr;
        logic       alu_only;
        logic       conditional_control;
        logic       indirect_control;
        logic       mem_read;
        logic       mem_write;
        logic       is_muldiv;
        logic       is_mul;
    } issue_hint_t;

    typedef struct packed {
        logic [31:0]      inst;
        prediction_meta_t prediction;
        issue_hint_t      issue_hint;
    } fetch_slot_t;

    typedef struct packed {
        logic [31:0] pc;
        fetch_slot_t slot0;
        fetch_slot_t slot1;
    } if_id_payload_t;

    // ---- Frontend instruction predecode ----
    typedef struct packed {
        logic       is_conditional_branch;
        logic       is_direct_jump;
        logic       is_indirect_jump;
        logic       is_privileged;
        logic       is_privileged_flow;
        logic       is_fence;
        logic       is_illegal;
        logic       is_muldiv;
        logic       is_mul;
        logic       is_load;
        logic       is_store;
        logic       is_alu_type;
        logic       is_jump;
        logic       is_control;
        logic       is_lsu;
        logic       is_cfi;
        logic       writes_dst;
        logic       uses_src0;
        logic       uses_src1;
        logic [4:0] src0_addr;
        logic [4:0] src1_addr;
        logic [4:0] dst_addr;
        logic [1:0] lane_mask;
        logic       block_younger;
        logic       serializing;
    } frontend_predecode_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] inst;
        // Prediction metadata / 预测元数据
        logic        pred_taken;
        logic [31:0] pred_target;
        logic        pred_source_abtb;
        logic        stage1_branch_owned;
        logic [ 1:0] pred_cfi_type;
        logic [ 7:0] stage1_pht_index;
        logic [ 1:0] stage1_pht_counter;
        // Decoded instruction class / 指令类型
        logic        is_conditional_branch;
        logic        is_direct_jump;
        logic        is_indirect_jump;
        logic        is_privileged;
        logic        is_privileged_flow;
        logic        is_fence;
        logic        is_illegal;
        logic        is_muldiv;
        logic        is_mul;
        logic        is_load;
        logic        is_store;
        logic        is_alu_type;
        // Register scheduling metadata / 寄存器调度信息
        logic        writes_dst;
        logic        uses_src0;
        logic        uses_src1;
        logic        is_jump;
        logic        is_control;
        logic        is_lsu;
        // Force single issue for classes unsupported by pairing.
        // 对不支持配对的指令强制单发射。
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
        logic       is_muldiv;
        logic       is_alu_type;
        logic       is_lsu;
        logic       is_cfi;
        logic       writes_dst;
        logic       uses_src0;
        logic       uses_src1;
        logic [4:0] dst_addr;
        logic [4:0] src0_addr;
        logic [4:0] src1_addr;
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
        logic        is_conditional_branch;
        logic        is_direct_jump;
        logic        is_indirect_jump;
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
        logic        is_conditional_branch;
        logic        is_direct_jump;
        logic        is_indirect_jump;
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
        logic              alu_src1_wb_repair;
        logic              alu_src2_wb_repair;
        alu_op_t           alu_op;
        logic              reg_write_en;
        wb_src_t           wb_sel;
        logic              mem_read_en;
        logic              mem_write_en;
        mem_size_t         mem_size;
        logic              mem_unsigned;
        control_flow_t     control_flow;
        branch_op_t        branch_op;
        logic [ 1:0]       target_clear_mask;
        id_ex_prediction_t prediction;
    } id_ex_common_t;

    typedef struct packed {
        id_ex_common_t common;
        logic [31:0]    inst;
        priv_op_t       priv_op;
        logic           priv_uses_imm;
        priv_cmd_t      priv_cmd;
        logic [PRIV_ADDR_W-1:0] priv_addr;
        logic [4:0]     priv_imm;
        decode_exception_t exception;
        logic          is_muldiv;
        muldiv_op_t     muldiv_op;
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
        logic [31:0] inst;
        logic [31:0] alu_result;
        logic [31:0] pc;
        logic [31:0] pc_plus_4;
        logic [ 4:0] rd;
        logic        reg_write_en;
        wb_src_t    wb_sel;
        logic        is_mul;
        logic        mem_read_en;
        mem_size_t  mem_size;
        logic        mem_unsigned;
        logic [ 3:0] store_wea;
        logic [31:0] store_data;
        logic        is_cacheable;
        logic        mem_write_en;
        logic        exception;
        logic        csr_rstat;
        logic [31:0] csr_data;
    } ex_mem_slot0_t;

    typedef struct packed {
        logic [31:0] pc;
        logic [31:0] inst;
        logic [31:0] alu_result;
        logic [31:0] pc_plus_4;
        logic [ 4:0] rd;
        logic        reg_write_en;
        wb_src_t    wb_sel;
        logic        mem_read_en;
        logic        mem_write_en;
        mem_size_t  mem_size;
        logic        mem_unsigned;
        logic [ 3:0] store_wea;
        logic [31:0] store_data;
        logic        is_cacheable;
    } ex_mem_slot1_t;

    // ---- MEM/WB payloads ----
    typedef struct packed {
        logic [31:0] pc;
        logic [31:0] inst;
        logic [31:0] alu_result;
        logic [31:0] pc_plus_4;
        logic [ 4:0] rd;
        logic        reg_write_en;
        wb_src_t    wb_sel;
        logic        is_load;
        logic [31:0] load_data;
        logic        is_store;
        mem_size_t  mem_size;
        logic        mem_unsigned;
        logic [31:0] mem_addr;
        logic [31:0] store_data;
        logic        exception;
        logic        csr_rstat;
        logic [31:0] csr_data;
    } mem_wb_slot0_t;

    typedef struct packed {
        logic [31:0] pc;
        logic [31:0] inst;
        logic [31:0] alu_result;
        logic [31:0] pc_plus_4;
        logic [ 4:0] rd;
        logic        reg_write_en;
        wb_src_t    wb_sel;
        logic        is_load;
        logic        is_store;
        mem_size_t  mem_size;
        logic        mem_unsigned;
        logic [31:0] mem_addr;
        logic [31:0] store_data;
    } mem_wb_slot1_t;

endpackage
