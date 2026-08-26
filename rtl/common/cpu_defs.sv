// ============================================================
// 中文说明：定义流水线、译码、访存、预测器和异常处理共用的枚举、结构体和常量。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 包：cpu_defs。
// 说明：定义供所有模块共享的全局常量、枚举和结构体。
// ============================================================

package cpu_defs;

    // 通用流水线只接收语义化操作；指令编码位于 rtl/isa/<isa>/，
    // 不应泄漏到这个公共定义包。
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

    // 这些值刻意独立于任何 ISA 编码，即使位模式碰巧与旧实现相同也不依赖它。
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

    // redirect 经过 EX/MEM 时携带的是来源选择，而不是最终 32 位目标。
    // MEM 从普通流水线 payload 已携带的候选项中选择目标，使 EX 阶段较晚的
    // 分支判断不会驱动宽重定向寄存器的每一个数据位。
    typedef enum logic [1:0] {
        REDIRECT_S0_CONTROL = 2'b00,
        REDIRECT_PRIVILEGED = 2'b01,
        REDIRECT_S1_CONTROL = 2'b10,
        REDIRECT_S1_REPLAY  = 2'b11
    } redirect_source_t;

    typedef enum logic [2:0] {
        PRIV_NONE    = 3'b000,
        PRIV_REG     = 3'b001,
        PRIV_SYSCALL = 3'b010,
        PRIV_RETURN  = 3'b011,
        // LoongArch 稳定计数器读取共用特权结果路径，但不是 CSR 访问，
        // 在 PLV0 之外仍然合法。
        PRIV_COUNTER = 3'b100,
        // CPUCFG 也复用特权结果路径，但它是非特权的只读架构配置查询。
        PRIV_CPUCFG  = 3'b101
    } priv_op_t;

    typedef enum logic [2:0] {
        PRIV_CMD_NONE     = 3'b000,
        PRIV_CMD_WRITE    = 3'b001,
        PRIV_CMD_SET      = 3'b010,
        PRIV_CMD_CLEAR    = 3'b011,
        // LoongArch CSRXCHG 使用寄存器提供掩码，因此不能用 RISC-V 的
        // set/clear 命令表示。
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
    // ISA 适配器向平台相关的验证包装器暴露一组不透明架构状态。
    // 通用核心不解释其中单个字的含义，从而保持 ISA 边界。
    localparam int PRIV_DEBUG_STATE_WORDS = 27;
    localparam int PRIV_DEBUG_STATE_W = PRIV_DEBUG_STATE_WORDS * 32;

    // 一条完整译码后的架构指令。valid/ready 保留在 payload 外部，
    // 使每个流水线边界都显式保存握手状态。
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

    // ---- 前端 / IF-ID payload ----
    // 按功能组织流水线数据。握手和 lane-valid 信号保持独立，
    // 使每个阶段边界的流水控制都清晰可见。
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

    // 跨越 IF/ID 携带的 ISA 无关相关性元数据。ISA 专用预译码器在 IROM
    // 响应旁边计算这些信息，队列和 IF/ID 寄存器随后提供给后端，
    // 不把完整译码器放入 ID 停顿/反压反馈环路。
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
        logic       serializing;
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

    // ---- 前端指令预译码 ----
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

    // 在 ICache refill 时生成的精确指令类别。5 位足以覆盖 NSCSCC 核心实现的
    // 所有 LA32R 指令族。bit0 只在会阻止下一条顺序指令的静态类别中置 1。
    // 这个低位 kind 信息存放在 ICache 缩短 tag 的 LUTRAM 部分，因此 F0
    // 判断 slot1 是否可进入取指队列时，不需要等待较晚的 RAMB36 输出译码。
    typedef enum logic [4:0] {
        ICACHE_KIND_ALU_RR       = 5'd0,
        ICACHE_KIND_ILLEGAL      = 5'd1,
        ICACHE_KIND_ALU_IMM      = 5'd2,
        ICACHE_KIND_BRANCH       = 5'd3,
        ICACHE_KIND_UPPER_IMM    = 5'd4,
        ICACHE_KIND_BRANCH_LINK  = 5'd5,
        ICACHE_KIND_LOAD         = 5'd6,
        ICACHE_KIND_JIRL         = 5'd7,
        ICACHE_KIND_STORE        = 5'd8,
        ICACHE_KIND_PRIV_FLOW    = 5'd9,
        ICACHE_KIND_MUL          = 5'd10,
        ICACHE_KIND_DIVMOD       = 5'd12,
        ICACHE_KIND_CONDITIONAL  = 5'd14,
        ICACHE_KIND_CSR_READ     = 5'd16,
        ICACHE_KIND_CSR_WRITE    = 5'd18,
        ICACHE_KIND_CSR_EXCHANGE = 5'd20,
        ICACHE_KIND_COUNTER      = 5'd22,
        ICACHE_KIND_COUNTER_ID   = 5'd24,
        ICACHE_KIND_CPUCFG       = 5'd26
    } icache_inst_kind_t;

    localparam integer ICACHE_KIND_STATIC_KILL_BIT = 0;

    // 每条指令恰好缓存 7 位预译码信息。最常用的两个控制位保持显式，
    // 其余前端属性由 5 位精确 kind 描述。物理 ICache 仍把这 7 位拆分到
    // RAMB36 奇偶位和缩短 tag 的 LUTRAM 存储中。
    typedef struct packed {
        logic block_younger;
        logic writes_dst;
        icache_inst_kind_t inst_kind;
    } frontend_icache_predecode_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] inst;
        // 预测元数据。
        logic        pred_taken;
        logic [31:0] pred_target;
        logic        pred_source_abtb;
        logic        stage1_branch_owned;
        logic [ 1:0] pred_cfi_type;
        logic [ 7:0] stage1_pht_index;
        logic [ 1:0] stage1_pht_counter;
        // 译码后的指令类别。
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
        // 寄存器调度元数据。
        logic        writes_dst;
        logic        uses_src0;
        logic        uses_src1;
        logic        is_jump;
        logic        is_control;
        logic        is_lsu;
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

    // 与每个取指队列表项并行保存的元数据。类型定义始终完整，以保持模块
    // 边界和调试探针稳定；具体实现可以在综合状态中省略宽字段。
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

    // ---- 预测结果确认 / 训练接口 ----
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

    // ---- 前端预测器观测接口 ----
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

    // ---- ID/EX 有效载荷 ----
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

    // ---- EX/MEM 有效载荷 ----
    typedef struct packed {
        logic             valid;
        redirect_source_t source;
        logic             actual_taken;
    } redirect_t;

    typedef struct packed {
        logic [31:0] inst;
        logic [31:0] alu_result;
        logic [31:0] pc;
        logic [31:0] pc_plus_4;
        logic [ 1:0] target_clear_mask;
        logic [31:0] priv_target;
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
        logic [ 1:0] target_clear_mask;
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

    // ---- MEM/WB 有效载荷 ----
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
