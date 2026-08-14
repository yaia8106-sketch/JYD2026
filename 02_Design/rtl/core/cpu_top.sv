// ============================================================
// 中文说明：连接取指、译码、执行、访存、写回、Cache、AXI 和 LoongArch 特权单元，是处理器核心的顶层连线模块。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：处理器使用五级流水线。各阶段的具体行为放在对应子模块中，
// cpu_top 主要负责模块连接和少量必要的连线逻辑。
// IROM 在本模块外部实例化，通过端口连接；DRAM 由上层实例化的 DCache 访问。
// 前端默认使用一级 ABTB 与 PHT 组合的取指方向预测。
// ============================================================

`ifdef SYNTHESIS
`ifdef ABTB_MEASUREMENT
`define CPU_TOP_ABTB_OBSERVE
`endif
`else
`define CPU_TOP_ABTB_OBSERVE
`endif

module cpu_top
    import cpu_defs::*;
#(
    parameter bit IROM_VARIABLE_LATENCY = 1'b0,
    parameter logic [31:0] RESET_PC = 32'h8000_0000,
    parameter logic [31:0] CACHE_ADDR_BASE = 32'h8010_0000,
    parameter logic [31:0] CACHE_ADDR_MASK = 32'hFFFC_0000,
    parameter bit AXI_UNCACHED_DATA = 1'b0,
    parameter bit CACHE_RDATA_FORMATTED = 1'b0
)
(
    input  logic        clk,
    input  logic        rst_n,

    // IROM 接口（IF 阶段）：64 位对齐取指块。
    output logic [11:0] irom_addr,
    output logic        irom_req_valid,
    output logic [31:0] irom_req_addr,
    output logic        irom_req_kill,
    input  logic        irom_req_ready,
    input  logic        irom_resp_valid,
    input  logic [63:0] irom_data,
    input  logic [13:0] irom_resp_predecode,

    // DCache 接口（EX 到 MEM 阶段）。
    output logic        cache_req,       // EX 阶段：访存请求有效
    output logic        cache_wr,        // EX 阶段：0=load，1=store
    output logic [31:0] cache_addr,      // EX 阶段：访存地址
    output logic [16:0] cache_lookup_addr, // EX 阶段：addr[18:2]，DCache 短查询路径
    output logic [ 3:0] cache_wea,       // EX 阶段：字节写使能
    output logic [31:0] cache_wdata,     // EX 阶段：原始 store 数据
    output logic [ 3:0] cache_load_mask, // EX 阶段：load 字节通道
    output logic [ 1:0] cache_load_size,
    output logic        cache_load_unsigned,
    output logic        cache_uncached,  // 平台路径：绕过 DCache 数据阵列
    input  logic [31:0] cache_rdata,     // MEM 阶段：DCache 读数据
    input  logic [31:0] cache_rdata_ex,  // EX load 修复使用的独立副本
    input  logic        cache_ready,     // MEM 阶段：命中或缺失完成
    output logic        cache_flush,     // MEM 阶段：流水线冲刷（中止 refill）
    output logic        cache_pipeline_stall, // DCache 同步：~mem_allowin

    // MMIO 接口，保持原有外设风格的分拆地址端口。
    output logic [31:0] mmio_addr,       // EX 阶段：地址
    output logic [31:0] mmio_wr_addr,    // MEM 阶段：写地址
    output logic [ 3:0] mmio_wea,        // MEM 阶段：写使能
    output logic [31:0] mmio_wdata,      // MEM 阶段：写数据
    input  logic [31:0] mmio_rdata,      // MEM 阶段：读数据
    input  logic        timer_irq_pending,

    // chiplab 核心接口使用的架构提交和调试输出。
    output logic        debug0_wb_valid,
    output logic [31:0] debug0_wb_pc,
    output logic [ 3:0] debug0_wb_rf_wen,
    output logic [ 4:0] debug0_wb_rf_wnum,
    output logic [31:0] debug0_wb_rf_wdata,
    output logic [31:0] debug0_wb_inst,
    output logic        debug0_wb_exception,
    output logic        debug0_wb_mem_read,
    output logic        debug0_wb_mem_write,
    output logic [ 1:0] debug0_wb_mem_size,
    output logic        debug0_wb_mem_unsigned,
    output logic [31:0] debug0_wb_mem_addr,
    output logic [31:0] debug0_wb_store_data,
    output logic        debug0_wb_csr_rstat,
    output logic [31:0] debug0_wb_csr_data,
    output logic        debug1_wb_valid,
    output logic [31:0] debug1_wb_pc,
    output logic [ 3:0] debug1_wb_rf_wen,
    output logic [ 4:0] debug1_wb_rf_wnum,
    output logic [31:0] debug1_wb_rf_wdata,
    output logic [31:0] debug1_wb_inst,
    output logic        debug1_wb_mem_read,
    output logic        debug1_wb_mem_write,
    output logic [ 1:0] debug1_wb_mem_size,
    output logic        debug1_wb_mem_unsigned,
    output logic [31:0] debug1_wb_mem_addr,
    output logic [31:0] debug1_wb_store_data,
    output logic [1023:0] debug_gpr_state,
    output logic [PRIV_DEBUG_STATE_W-1:0] debug_priv_state,
    output logic        debug_excp_valid,
    output logic        debug_ertn,
    output logic [31:0] debug_intr_no,
    output logic [ 5:0] debug_cause,
    output logic [31:0] debug_exception_pc,
    output logic [31:0] debug_exception_inst
);

    // ================================================================
    //  内部连线
    // ================================================================

    // ---- PC 和 IF ----
    // pc 由前端取指状态机驱动，同时作为当前 BP0 请求的预测器查找 PC。
    wire [31:0] pc;
    wire        if_valid;

    // 预先计算并寄存 PC+4，避免把进位链放入 irom_addr 的默认路径。
    // 每个分支从自己的寄存器源独立计算 +4，不形成 irom_addr 反馈。
    logic [31:0] pc_plus4;
    logic [31:0] pc_plus8;
    logic [31:0] pc_plus12;

    // ---- IF/ID 流水寄存器 ----
    wire        id_valid;
    wire        id_allowin;
    wire        id_ready_go;
    wire        id_dependency_ready;
    wire        id_dependency_ready_if_mem_ready;
    wire        id_dependency_ready_if_mem_wait;
    wire        id_non_load_hazard;
    wire        id_mul_launch_ex_raw_hazard;
    // 结构化 payload 让每个 slot 的预测元数据和指令一起跨过流水边界。
    wire cpu_defs::if_id_payload_t if_id_payload;
    wire cpu_defs::if_id_payload_t id_payload;
    wire [31:0] id_pc = id_payload.pc;
    wire [31:0] id_inst = id_payload.slot0.inst;
    wire [31:0] id_inst1 = id_payload.slot1.inst;
    wire issue_hint_t id_issue_hint = id_payload.slot0.issue_hint;
    wire issue_hint_t id_s1_issue_hint = id_payload.slot1.issue_hint;
    wire [4:0] id_s0_rf_rs1_addr;
    wire [4:0] id_s0_rf_rs2_addr;
    wire [4:0] id_s1_rf_rs1_addr;
    wire [4:0] id_s1_rf_rs2_addr;
    wire        id_s1_valid;       // 已寄存的 Slot1 发射有效

    // ---- 指令保持寄存器 ----
    wire        irom_held_valid;

    // ---- LoongArch 译码输出 ----
    wire decoded_uop_t dec_uop;
    wire decoded_uop_t dec1_uop;
    wire alu_op_t dec_alu_op = dec_uop.alu_op;
    wire operand_a_sel_t dec_alu_src1_sel = dec_uop.operand_a_sel;
    wire operand_b_sel_t dec_alu_src2_sel = dec_uop.operand_b_sel;
    wire dec_reg_write_en = dec_uop.dst_write;
    wire wb_src_t dec_wb_sel = dec_uop.wb_src;
    wire dec_mem_read_en = dec_uop.mem_cmd == MEM_LOAD;
    wire dec_mem_write_en = dec_uop.mem_cmd == MEM_STORE;
    wire mem_size_t dec_mem_size = dec_uop.mem_size;
    wire dec_mem_unsigned = dec_uop.mem_unsigned;
    wire dec_is_conditional_control =
        dec_uop.control_flow == CF_CONDITIONAL;
    wire dec_is_indirect_control =
        dec_uop.control_flow == CF_INDIRECT;
    wire dec_is_muldiv = dec_uop.exec_unit == EXEC_MULDIV;
    wire id_is_mul = dec_is_muldiv
                   & (dec_uop.muldiv_op <= MULDIV_MULHU);
    wire id_issue_is_muldiv = id_issue_hint.is_muldiv;
    wire id_issue_is_mul = id_issue_hint.is_mul;

    // ---- slot1 LoongArch 译码输出 ----
    wire alu_op_t dec1_alu_op = dec1_uop.alu_op;
    wire operand_a_sel_t dec1_alu_src1_sel = dec1_uop.operand_a_sel;
    wire operand_b_sel_t dec1_alu_src2_sel = dec1_uop.operand_b_sel;
    wire dec1_reg_write_en = dec1_uop.dst_write;
    wire wb_src_t dec1_wb_sel = dec1_uop.wb_src;
    wire dec1_mem_read_en = dec1_uop.mem_cmd == MEM_LOAD;
    wire dec1_mem_write_en = dec1_uop.mem_cmd == MEM_STORE;
    wire mem_size_t dec1_mem_size = dec1_uop.mem_size;
    wire dec1_mem_unsigned = dec1_uop.mem_unsigned;

    wire [31:0] id_imm = dec_uop.imm;
    wire [31:0] id_s1_imm = dec1_uop.imm;

    // ---- 寄存器堆 ----
    wire [31:0] rf_rs1_data;
    wire [31:0] rf_rs2_data;
    wire [31:0] rf_s1_rs1_data;
    wire [31:0] rf_s1_rs2_data;

    // ---- 操作数前递 ----
    wire [31:0] fwd_rs1_data;
    wire [31:0] fwd_rs2_data;
    wire [31:0] mul_fwd_rs1_data;
    wire [31:0] mul_fwd_rs2_data;
    wire [31:0] fwd_s1_rs1_data;
    wire [31:0] fwd_s1_rs2_data;
    wire        fwd_rs1_wb_repair;
    wire        fwd_rs2_wb_repair;
    wire        fwd_s1_rs1_wb_repair;
    wire        fwd_s1_rs2_wb_repair;

    // ---- 从前递网络得到的并行化 ALU 操作数 ----
    wire [31:0] id_alu_src1;
    wire [31:0] id_alu_src2;
    wire [31:0] id_s1_alu_src1;
    wire [31:0] id_s1_alu_src2;

    // ---- ID/EX ----
    wire        ex_valid;
    wire        ex_allowin;
    wire cpu_defs::id_ex_slot0_t id_ex_s0_payload;
    wire cpu_defs::id_ex_slot0_t ex_s0_payload;
    wire        ex_s0_hazard_valid;
    wire        ex_s0_hazard_reg_write;
    wire        ex_s0_hazard_is_muldiv;
    wire        ex_s0_hazard_mem_read;
    wire        ex_s0_hazard_result_repair;
    wire [ 4:0] ex_s0_hazard_rd;
    wire [ 3:0] ex_s0_repair_q;
    wire [31:0] ex_pc = ex_s0_payload.common.pc;
    wire [31:0] ex_inst = ex_s0_payload.inst;
    wire [31:0] ex_alu_src1 = ex_s0_payload.common.alu_src1;
    wire [31:0] ex_alu_src2 = ex_s0_payload.common.alu_src2;
    wire [31:0] ex_rs1_data = ex_s0_payload.common.rs1_data;
    wire [31:0] ex_rs2_data = ex_s0_payload.common.rs2_data;
    wire        ex_rs1_wb_repair = ex_s0_repair_q[0];
    wire        ex_rs2_wb_repair = ex_s0_repair_q[1];
    wire [ 4:0] ex_rd = ex_s0_payload.common.rd;
    wire [ 4:0] ex_rs1_addr = ex_s0_payload.common.rs1_addr;
    wire [ 4:0] ex_rs2_addr = ex_s0_payload.common.rs2_addr;
    wire        ex_alu_src1_wb_repair = ex_s0_repair_q[2];
    wire        ex_alu_src2_wb_repair = ex_s0_repair_q[3];
    wire alu_op_t ex_alu_op = ex_s0_payload.common.alu_op;
    wire        ex_reg_write_en = ex_s0_payload.common.reg_write_en;
    wire wb_src_t ex_wb_sel = ex_s0_payload.common.wb_sel;
    wire        ex_mem_read_en = ex_s0_payload.common.mem_read_en;
    wire        ex_mem_write_en = ex_s0_payload.common.mem_write_en;
    wire mem_size_t ex_mem_size = ex_s0_payload.common.mem_size;
    wire        ex_mem_unsigned = ex_s0_payload.common.mem_unsigned;
    wire control_flow_t ex_control_flow =
        ex_s0_payload.common.control_flow;
    wire branch_op_t ex_branch_op = ex_s0_payload.common.branch_op;
    wire [1:0] ex_target_clear_mask =
        ex_s0_payload.common.target_clear_mask;
    wire ex_is_conditional_control =
        ex_control_flow == CF_CONDITIONAL;
    wire ex_is_direct_control = ex_control_flow == CF_DIRECT;
    wire ex_is_indirect_control = ex_control_flow == CF_INDIRECT;
    wire priv_op_t ex_priv_op = ex_s0_payload.priv_op;
    wire ex_is_priv_reg = ex_priv_op == PRIV_REG;
    wire ex_is_counter = ex_priv_op == PRIV_COUNTER;
    wire ex_is_cpucfg = ex_priv_op == PRIV_CPUCFG;
    wire ex_uses_priv_result = ex_is_priv_reg | ex_is_counter | ex_is_cpucfg;
    wire ex_priv_uses_imm = ex_s0_payload.priv_uses_imm;
    wire priv_cmd_t ex_priv_cmd = ex_s0_payload.priv_cmd;
    wire [PRIV_ADDR_W-1:0] ex_priv_addr = ex_s0_payload.priv_addr;
    wire [4:0] ex_priv_imm = ex_s0_payload.priv_imm;
    wire decode_exception_t ex_exception = ex_s0_payload.exception;
    wire        ex_is_muldiv = ex_s0_payload.is_muldiv;
    wire muldiv_op_t ex_muldiv_op = ex_s0_payload.muldiv_op;

    // ---- Slot 1 ID/EX ----
    wire        ex_s1_valid;
    wire cpu_defs::id_ex_slot1_t id_ex_s1_payload;
    wire cpu_defs::id_ex_slot1_t ex_s1_payload;
    wire        ex_s1_hazard_valid;
    wire        ex_s1_hazard_reg_write;
    wire        ex_s1_hazard_mem_read;
    wire        ex_s1_hazard_result_repair;
    wire [ 4:0] ex_s1_hazard_rd;
    wire [ 3:0] ex_s1_repair_q;
    wire [31:0] ex_s1_pc = ex_s1_payload.common.pc;
    wire [31:0] ex_s1_inst = ex_s1_payload.inst;
    wire [ 4:0] ex_s1_rd = ex_s1_payload.common.rd;
    wire [ 4:0] ex_s1_rs1_addr = ex_s1_payload.common.rs1_addr;
    wire [ 4:0] ex_s1_rs2_addr = ex_s1_payload.common.rs2_addr;
    wire alu_op_t ex_s1_alu_op = ex_s1_payload.common.alu_op;
    wire        ex_s1_reg_write_en = ex_s1_payload.common.reg_write_en;
    wire wb_src_t ex_s1_wb_sel = ex_s1_payload.common.wb_sel;
    wire        ex_s1_mem_read_en = ex_s1_payload.common.mem_read_en;
    wire        ex_s1_mem_write_en = ex_s1_payload.common.mem_write_en;
    wire mem_size_t ex_s1_mem_size = ex_s1_payload.common.mem_size;
    wire        ex_s1_mem_unsigned = ex_s1_payload.common.mem_unsigned;
    wire control_flow_t ex_s1_control_flow =
        ex_s1_payload.common.control_flow;
    wire branch_op_t ex_s1_branch_op = ex_s1_payload.common.branch_op;
    wire [1:0] ex_s1_target_clear_mask =
        ex_s1_payload.common.target_clear_mask;
    wire ex_s1_is_conditional_control =
        ex_s1_control_flow == CF_CONDITIONAL;
    wire ex_s1_is_direct_control = ex_s1_control_flow == CF_DIRECT;
    wire ex_s1_is_indirect_control =
        ex_s1_control_flow == CF_INDIRECT;
    wire [31:0] ex_s1_alu_src1 = ex_s1_payload.common.alu_src1;
    wire [31:0] ex_s1_alu_src2 = ex_s1_payload.common.alu_src2;
    wire [31:0] ex_s1_rs1_data = ex_s1_payload.common.rs1_data;
    wire [31:0] ex_s1_rs2_data = ex_s1_payload.common.rs2_data;
    wire        ex_s1_rs1_wb_repair = ex_s1_repair_q[0];
    wire        ex_s1_rs2_wb_repair = ex_s1_repair_q[1];
    wire        ex_s1_alu_src1_wb_repair = ex_s1_repair_q[2];
    wire        ex_s1_alu_src2_wb_repair = ex_s1_repair_q[3];

    // ---- ALU ----
    wire [31:0] alu_result;
    wire [31:0] alu_sum;               // MUX 前的原始 ALU 加法结果
    wire [31:0] alu_addr;              // 独立地址加法结果，不依赖 alu_op
    wire [31:0] alu_s1_result;
    wire [31:0] alu_s1_sum;
    wire [31:0] alu_s1_addr;
    wire [31:0] ex_fast_forward_result;
    wire [31:0] ex_s1_fast_forward_result;
    // 五位移位量原本会同时驱动完整的 Slot1 ALU 和前递桶形移位器的每一级。
    // 为 EX 到 ID 的快速结果保留一个物理独立、周期一致的副本，避免架构
    // ALU 的布局给这条关键源路径增加负载。
    wire [ 4:0] ex_s1_fast_src2_low;
    wire        ex_s0_store_data_bypass_q;
    wire [31:0] ex_alu_src1_repair;
    wire [31:0] ex_alu_src2_repair;
    wire [31:0] ex_s1_alu_src1_repair;
    wire [31:0] ex_s1_alu_src2_repair;
    wire [31:0] ex_rs1_data_repair;
    wire [31:0] ex_rs2_data_repair;
    wire [31:0] ex_s1_rs1_data_repair;
    wire [31:0] ex_s1_rs2_data_repair;
    wire [18:0] ex_lsu_addr_low;
    wire [18:0] ex_s1_lsu_addr_low;
    wire [ 1:0] ex_lsu_align_low;
    wire [ 1:0] ex_s1_lsu_align_low;

    // ---- 分支 ----
    wire        branch_flush;          // EX 阶段组合结果（供预测器更新）
    wire        actual_taken;          // 供预测器更新的实际方向
    wire [31:0] actual_target;         // 供预测器更新的实际目标
    wire [31:0] ex_control_target;     // EX 计算的 Slot0 CFI 目标
    wire        ex_s1_branch_redirect; // Slot1 分支延迟前端重定向
    wire [31:0] ex_s1_branch_target;
    wire        ex_s1_actual_taken;
    wire        ex_redirect_fire;
    wire        ex_priv_flow;
    wire        ex_priv_redirect;
    wire [31:0] ex_priv_target;
    wire        ex_priv_trap;
    wire        ex_priv_wait_older;
    wire        ex_s1_addr_replay;
    wire        timer_irq_request;
    wire        timer_irq_redirect;
    wire [31:0] timer_irq_target;
    wire        timer_irq_hold;
    wire        timer_irq_block;
    wire        timer_irq_pipe_empty;
    wire        timer_irq_take;
    wire        ex_fast_redirect;
    wire [31:0] ex_fast_redirect_target;
    wire        ex_registered_branch_flush;
    wire cpu_defs::redirect_source_t ex_registered_redirect_source;
    wire        ex_registered_redirect_actual_taken;

    // ---- 已寄存的分支冲刷（MEM 阶段，用于 250MHz 时序）----
    wire cpu_defs::redirect_t ex_mem_redirect;
    wire cpu_defs::redirect_t mem_redirect;
    wire        mem_branch_flush = mem_redirect.valid;
    wire [31:0] mem_branch_target;
    wire        mem_branch_replay;
    wire        frontend_branch_flush;
    wire [31:0] frontend_branch_target;

    // ---- 访存接口 ----
    wire [ 3:0] dram_wea;
    wire [ 3:0] dram_wea_s1;
    wire [31:0] ex_s1_store_data_raw;
    // 旧平台返回原始数据；NSCSCC DCache 已经完成格式化。
    wire [31:0] mem_load_data;
    wire [31:0] mem_load_data_ex;
    wire [31:0] mem_load_data_ext;
    wire [31:0] mem_load_data_ext_ex;
    // 任一 MEM 槽位中已经 ready 的 load 都可以修复满足条件的 EX 消费者。
    wire        mem_load_ready;
    wire        is_cacheable;          // EX 阶段：地址位于 DRAM 范围
    wire        is_cacheable_s1;       // EX 阶段：Slot1 地址位于 DRAM 范围

    // ---- EX 预计算结果 ----
    wire [31:0] ex_pc_plus_4;
    wire [31:0] ex_s1_pc_plus_4;

    // ---- EX/MEM ----
    wire        mem_valid;
    wire        mem_allowin;
    // MEM 接受条件的消费者局部副本。它们逻辑上都是同一个组合方程；
    // 显式按功能分簇，避免一条全局网络横跨 LSU/EX 控制、前端恢复和两个
    // 宽 EX/MEM payload bank。
    (* keep = "true" *) wire mem_allowin_lsu;
    (* keep = "true" *) wire mem_allowin_control;
    (* keep = "true" *) wire mem_allowin_pipe;
    wire cpu_defs::ex_mem_slot0_t ex_mem_s0_payload;
    wire cpu_defs::ex_mem_slot0_t mem_s0_payload;
    wire        mem_hazard_valid;
    wire        mem_hazard_reg_write;
    wire        mem_hazard_is_load;
    wire        mem_hazard_is_mul;
    wire [ 4:0] mem_hazard_rd;
    wire [ 4:0] mem_fwd_s0_rd;
    wire [ 4:0] mem_fwd_s1_rd;
    wire wb_src_t mem_hazard_wb_sel;
    wire [31:0] mem_alu_result = mem_s0_payload.alu_result;
    wire [31:0] mem_pc = mem_s0_payload.pc;
    wire [31:0] mem_inst = mem_s0_payload.inst;
    wire [31:0] mem_pc_plus_4 = mem_s0_payload.pc_plus_4;
    wire [ 4:0] mem_rd = mem_s0_payload.rd;
    wire        mem_reg_write_en = mem_s0_payload.reg_write_en;
    wire wb_src_t mem_wb_sel = mem_s0_payload.wb_sel;
    wire        mem_is_mul = mem_s0_payload.is_mul;
    wire        mem_mem_read_en = mem_s0_payload.mem_read_en;
    wire        mem_mem_write_en = mem_s0_payload.mem_write_en;
    wire mem_size_t mem_mem_size = mem_s0_payload.mem_size;
    wire        mem_mem_unsigned = mem_s0_payload.mem_unsigned;
    wire [ 3:0] mem_store_wea = mem_s0_payload.store_wea;
    wire [31:0] mem_store_data = mem_s0_payload.store_data;
    wire        is_cacheable_mem = mem_s0_payload.is_cacheable;
    wire        mem_exception = mem_s0_payload.exception;
    wire        mem_csr_rstat = mem_s0_payload.csr_rstat;
    wire [31:0] mem_csr_data = mem_s0_payload.csr_data;

    // ---- Slot1 MEM ----
    wire        mem_s1_valid;
    wire        mem_s1_hazard_valid;
    wire        mem_s1_hazard_is_load;
    wire [ 4:0] mem_s1_hazard_rd;
    wire cpu_defs::ex_mem_slot1_t ex_mem_s1_payload;
    wire cpu_defs::ex_mem_slot1_t mem_s1_payload;
    wire [31:0] mem_s1_pc = mem_s1_payload.pc;
    wire [31:0] mem_s1_inst = mem_s1_payload.inst;
    wire [31:0] mem_s1_alu_result = mem_s1_payload.alu_result;
    wire [31:0] mem_s1_pc_plus_4 = mem_s1_payload.pc_plus_4;
    wire [ 4:0] mem_s1_rd = mem_s1_payload.rd;
    wire        mem_s1_reg_write_en = mem_s1_payload.reg_write_en;
    wire wb_src_t mem_s1_wb_sel = mem_s1_payload.wb_sel;
    wire        mem_s1_mem_read_en = mem_s1_payload.mem_read_en;
    wire        mem_s1_mem_write_en = mem_s1_payload.mem_write_en;
    wire mem_size_t mem_s1_mem_size = mem_s1_payload.mem_size;
    wire        mem_s1_mem_unsigned = mem_s1_payload.mem_unsigned;
    wire [ 3:0] mem_s1_store_wea = mem_s1_payload.store_wea;
    wire [31:0] mem_s1_store_data = mem_s1_payload.store_data;
    wire        mem_s1_is_cacheable = mem_s1_payload.is_cacheable;

    // 发射策略保证每个发射组最多只有一个 LSU 操作。
    wire        mem_s1_load_active = mem_s1_valid & mem_s1_mem_read_en;
    wire        mem_load_valid = (mem_valid & mem_mem_read_en)
                               | mem_s1_load_active;
    wire        mem_selected_load_en = mem_mem_read_en | mem_s1_load_active;
    wire [ 1:0] mem_selected_load_addr_low = mem_s1_load_active
                                                ? mem_s1_alu_result[1:0]
                                                : mem_alu_result[1:0];
    wire [ 1:0] mem_selected_load_size = mem_s1_load_active
                                            ? mem_s1_mem_size
                                            : mem_mem_size;
    wire        mem_selected_load_unsigned = mem_s1_load_active
                                                ? mem_s1_mem_unsigned
                                                : mem_mem_unsigned;

    // ---- MEM/WB ----
    wire        wb_valid;
    wire        wb_allowin;
    wire cpu_defs::mem_wb_slot0_t mem_wb_s0_payload;
    wire cpu_defs::mem_wb_slot0_t wb_s0_payload;
    wire [31:0] wb_alu_result = wb_s0_payload.alu_result;
    wire [31:0] wb_pc_plus_4 = wb_s0_payload.pc_plus_4;
    wire [ 4:0] wb_rd = wb_s0_payload.rd;
    wire        wb_reg_write_en = wb_s0_payload.reg_write_en;
    wire wb_src_t wb_wb_sel = wb_s0_payload.wb_sel;
    wire [31:0] wb_load_data = wb_s0_payload.load_data;
    wire [31:0] wb_load_data_ex_s0;
    wire [31:0] wb_load_data_ex_s1;

    // ---- Slot1 WB 镜像 ----
    wire        wb_s1_valid;
    wire cpu_defs::mem_wb_slot1_t mem_wb_s1_payload;
    wire cpu_defs::mem_wb_slot1_t wb_s1_payload;
    wire [31:0] wb_s1_alu_result = wb_s1_payload.alu_result;
    wire [31:0] wb_s1_pc_plus_4 = wb_s1_payload.pc_plus_4;
    wire [ 4:0] wb_s1_rd = wb_s1_payload.rd;
    wire        wb_s1_reg_write_en = wb_s1_payload.reg_write_en;
    wire wb_src_t wb_s1_wb_sel = wb_s1_payload.wb_sel;

    // ---- WB ----
    wire [31:0] wb_write_data;
    wire [31:0] wb_s1_write_data;

    // ---- 选定 ISA 的特权状态 ----
    wire [31:0] ex_priv_rdata;
    wire [31:0] ex_forward_result;
    wire [31:0] ex_pipe_alu_result;
    wire        ex_fast_alu_forward = ~ex_uses_priv_result & ~ex_is_muldiv
                                    & (ex_wb_sel != WB_NEXT_PC);

    // ---- 整数乘除法单元 ----
    wire        muldiv_busy;
    wire        muldiv_done;
    wire [31:0] muldiv_result;
    wire        muldiv_consume;
    wire [31:0] mem_wb_alu_result;

    // 只有物理上位于 EX 快速旁路网络中的值才报告 EX 前递命中。
    // load、MulDiv 和特权结果从已经寄存的较老流水级获取。
    wire        ex_forward_reg_write = ex_reg_write_en
                                      & ~ex_mem_read_en
                                      & ~ex_is_muldiv
                                      & ~ex_uses_priv_result;
    wire        ex_s1_forward_reg_write = ex_s1_reg_write_en
                                         & ~ex_s1_mem_read_en;
    // ---- 双发射性能计数器 ----
    wire [31:0] dual_issue_count;

    // ---- 后端流控制 ----
    wire if_ready_go;               // 由 frontend_ftq 驱动
    wire mmio_st_ld_hazard;
    wire ex_muldiv_ready;
    wire ex_priv_ready;
    wire ex_priv_commit_ready;
    wire ex_ready_go;
    wire mem_ready_go;
    (* keep = "true" *) wire ex_allowin_if_cache_ready;
    (* keep = "true" *) wire ex_allowin_if_cache_wait;
    wire serializing_inflight;
    wire id_serializing_ready;
    wire id_barrier_ready;
    wire id_muldiv_unit_ready;
    wire ex_allowin_ex_local;
    wire id_allowin_pipe;
    wire id_allowin_frontend;
    wire id_to_ex_fire;

    // ---- 冲刷 / 重定向 ----
    wire id_flush = frontend_branch_flush;
    wire ex_flush = frontend_branch_flush;

    // Slot0 乘法可以与独立的 Slot1 指令配对，因此每条接受的乘法都必须
    // 在这里建立 MulDiv 所有权。
    wire id_mul_prestart = id_to_ex_fire & id_is_mul;

    // ---- 从选定 ISA 译码器得到的寄存器地址 ----
    wire [4:0] id_rs1_addr;
    wire [4:0] id_rs2_addr;
    wire [4:0] id_rd_addr;
    wire [4:0] id_s1_rs1_addr;
    wire [4:0] id_s1_rs2_addr;
    wire [4:0] id_s1_rd_addr;
    wire [31:0] id_pc_plus_4;
    wire [31:0] id_s1_pc;
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
    wire        id_s0_alu_store_data_bypass;
    wire        ex_s1_side_effect_kill;
    wire        ex_s1_lsu_select_raw;

    // ================================================================
    //  一级预测连线。
    // ================================================================

    // ID 阶段预测信息（来自 IF/ID 寄存器）。
    wire        id_pred_taken = id_payload.slot0.prediction.taken;
    wire [31:0] id_pred_target = id_payload.slot0.prediction.target;
    wire        id_s1_pred_taken = id_payload.slot1.prediction.taken;
    wire [31:0] id_s1_pred_target = id_payload.slot1.prediction.target;

    // EX 阶段预测信息（来自 ID/EX 寄存器）。
    wire        ex_pred_taken =
        ex_s0_payload.common.prediction.prediction.taken;
    wire [31:0] ex_pred_target =
        ex_s0_payload.common.prediction.prediction.target;
    wire        ex_s1_pred_taken =
        ex_s1_payload.common.prediction.prediction.taken;
    wire [31:0] ex_s1_pred_target =
        ex_s1_payload.common.prediction.prediction.target;

    // ABTB 查询/训练元数据。默认由 ABTB/PHT 负责一级 J/CALL 和条件分支
    // 的方向选择；旧预测器元数据已经停用。
    wire        abtb_lookup_accept;
    wire        abtb_bank0_hit;
    wire        abtb_bank0_lookup_hit;
    wire        abtb_bank0_way;
    wire [ 1:0] abtb_bank0_cfi_type;
    wire [31:0] abtb_bank0_abtb_pred_target;
    wire        abtb_bank0_pred_taken;
    wire [31:0] abtb_bank0_final_pred_target;
    wire        abtb_bank1_hit;
    wire        abtb_bank1_lookup_hit;
    wire        abtb_bank1_way;
    wire [ 1:0] abtb_bank1_cfi_type;
    wire [31:0] abtb_bank1_abtb_pred_target;
    wire        abtb_bank1_pred_taken;
    wire [31:0] abtb_bank1_final_pred_target;
    wire        abtb_shadow_pred_taken;
    wire        abtb_shadow_pred_bank;
    wire [ 1:0] abtb_shadow_pred_cfi_type;
    wire [31:0] abtb_shadow_pred_target;
    wire [31:0] abtb_shadow_pred_next_pc;
    wire [31:0] abtb_early_pred_next_pc;

    // 正式预测器路径始终使用结构化阶段记录。下面的标量名称只是定向测试
    // 使用的兼容探针。
    wire prediction_meta_t id_s0_prediction = id_payload.slot0.prediction;
    wire prediction_meta_t id_s1_prediction = id_payload.slot1.prediction;
    wire id_ex_prediction_t ex_s0_prediction =
        ex_s0_payload.common.prediction;
    wire id_ex_prediction_t ex_s1_prediction =
        ex_s1_payload.common.prediction;

    // 正式路径保持直接别名。虽然直通辅助模块的层次结构看起来整齐，
    // 但它会阻止 Vivado 将这些字段与消费者放在同一优化边界中。
    wire        if_abtb_hit_out = if_id_payload.slot0.prediction.abtb_hit;
    wire        if_abtb_way_out = if_id_payload.slot0.prediction.abtb_way;
    wire [ 1:0] if_abtb_cfi_type_out =
        if_id_payload.slot0.prediction.abtb_cfi_type;
    wire [31:0] if_abtb_target_out =
        if_id_payload.slot0.prediction.abtb_target;
    wire        if_abtb_pred_taken_out =
        if_id_payload.slot0.prediction.abtb_pred_taken;
    wire [31:0] if_abtb_pred_target_out =
        if_id_payload.slot0.prediction.abtb_pred_target;
    wire        if_pred_source_abtb_out =
        if_id_payload.slot0.prediction.source_abtb;
    wire        if_stage1_branch_owned_out =
        if_id_payload.slot0.prediction.stage1_branch_owned;
    wire        if_s1_abtb_hit_out =
        if_id_payload.slot1.prediction.abtb_hit;
    wire        if_s1_abtb_way_out =
        if_id_payload.slot1.prediction.abtb_way;
    wire [ 1:0] if_s1_abtb_cfi_type_out =
        if_id_payload.slot1.prediction.abtb_cfi_type;
    wire [31:0] if_s1_abtb_target_out =
        if_id_payload.slot1.prediction.abtb_target;
    wire        if_s1_abtb_pred_taken_out =
        if_id_payload.slot1.prediction.abtb_pred_taken;
    wire [31:0] if_s1_abtb_pred_target_out =
        if_id_payload.slot1.prediction.abtb_pred_target;
    wire        if_s1_pred_source_abtb_out =
        if_id_payload.slot1.prediction.source_abtb;
    wire        if_s1_stage1_branch_owned_out =
        if_id_payload.slot1.prediction.stage1_branch_owned;

    wire        id_abtb_hit = id_s0_prediction.abtb_hit;
    wire        id_abtb_way = id_s0_prediction.abtb_way;
    wire        id_abtb_update_qualified_w;
    wire [ 1:0] id_abtb_update_cfi_type_w;
    wire        id_s1_abtb_update_qualified_w;
    wire [ 1:0] id_s1_abtb_update_cfi_type_w;

    wire        ex_abtb_hit = ex_s0_prediction.prediction.abtb_hit;
    wire        ex_abtb_way = ex_s0_prediction.prediction.abtb_way;
    wire [ 1:0] ex_abtb_cfi_type =
        ex_s0_prediction.prediction.abtb_cfi_type;
    wire [31:0] ex_abtb_target =
        ex_s0_prediction.prediction.abtb_target;
    wire        ex_abtb_pred_taken =
        ex_s0_prediction.prediction.abtb_pred_taken;
    wire [31:0] ex_abtb_pred_target =
        ex_s0_prediction.prediction.abtb_pred_target;
    wire [ 7:0] stage1_bank0_pht_index;
    wire [ 1:0] stage1_bank0_pht_counter;
    wire        stage1_bank0_pht_taken;
    wire [ 7:0] stage1_bank1_pht_index;
    wire [ 1:0] stage1_bank1_pht_counter;
    wire        stage1_bank1_pht_taken;
    wire [ 7:0] stage1_lookup_ghr;
    wire [ 7:0] stage1_committed_ghr;
    wire [ 7:0] if_stage1_pht_index =
        if_id_payload.slot0.prediction.stage1_pht_index;
    wire [ 1:0] if_stage1_pht_counter =
        if_id_payload.slot0.prediction.stage1_pht_counter;
    wire [ 7:0] if_s1_stage1_pht_index =
        if_id_payload.slot1.prediction.stage1_pht_index;
    wire [ 1:0] if_s1_stage1_pht_counter =
        if_id_payload.slot1.prediction.stage1_pht_counter;
    wire [ 7:0] id_stage1_pht_index = id_s0_prediction.stage1_pht_index;
    wire [ 1:0] id_stage1_pht_counter = id_s0_prediction.stage1_pht_counter;
    wire [ 7:0] id_s1_stage1_pht_index = id_s1_prediction.stage1_pht_index;
    wire [ 1:0] id_s1_stage1_pht_counter =
        id_s1_prediction.stage1_pht_counter;
    wire [ 7:0] ex_stage1_pht_index =
        ex_s0_prediction.prediction.stage1_pht_index;
    wire [ 1:0] ex_stage1_pht_counter =
        ex_s0_prediction.prediction.stage1_pht_counter;
    wire [ 7:0] ex_s1_stage1_pht_index =
        ex_s1_prediction.prediction.stage1_pht_index;
    wire [ 1:0] ex_s1_stage1_pht_counter =
        ex_s1_prediction.prediction.stage1_pht_counter;
    wire cpu_defs::predictor_resolve_t predictor_resolve_s0;
    wire cpu_defs::predictor_resolve_t predictor_resolve_s1;
    wire cpu_defs::predictor_train_t predictor_train;
    wire cpu_defs::abtb_update_t predictor_abtb_update;
    wire cpu_defs::pht_update_t predictor_pht_update;
    wire cpu_defs::abtb_update_t predictor_abtb_write;
    wire cpu_defs::pht_update_t predictor_pht_write;

    // 预测器定向测试引用的兼容别名。
    wire [ 1:0] stage1_direction_update_counter =
        predictor_pht_update.counter;
    wire        stage1_direction_write_valid =
        predictor_pht_write.valid;
    wire [ 7:0] stage1_direction_write_index =
        predictor_pht_write.index;
    wire [ 1:0] stage1_direction_write_counter =
        predictor_pht_write.counter;
    wire        stage1_direction_write_actual_taken =
        predictor_pht_write.actual_taken;

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

`ifdef CPU_TOP_ABTB_OBSERVE
    // 定向预测器测试和性能工具使用的兼容名称；计数器本身位于观测边界之后。
    wire cpu_defs::frontend_abtb_counters_t abtb_monitor_counters;
    wire [31:0] abtb_lookup_block_count =
        abtb_monitor_counters.lookup_block;
    wire [31:0] abtb_bank0_hit_count = abtb_monitor_counters.bank0_hit;
    wire [31:0] abtb_bank1_hit_count = abtb_monitor_counters.bank1_hit;
    wire [31:0] abtb_ex_update_count = abtb_monitor_counters.ex_update;
    wire [31:0] abtb_allocation_count = abtb_monitor_counters.allocation;
    wire [31:0] abtb_hit_update_count = abtb_monitor_counters.hit_update;
    wire [31:0] abtb_direct_lookup_count =
        abtb_monitor_counters.direct_lookup;
    wire [31:0] abtb_direct_steer_count =
        abtb_monitor_counters.direct_steer;
    wire [31:0] abtb_direct_bank0_count =
        abtb_monitor_counters.direct_bank0;
    wire [31:0] abtb_direct_bank1_count =
        abtb_monitor_counters.direct_bank1;
    wire [31:0] abtb_direct_correct_count =
        abtb_monitor_counters.direct_correct;
    wire [31:0] abtb_direct_redirect_count =
        abtb_monitor_counters.direct_redirect;
    wire [31:0] abtb_direct_target_miss_count =
        abtb_monitor_counters.direct_target_miss;
    wire [31:0] stage1_sequential_count =
        abtb_monitor_counters.stage1_sequential;
    wire [31:0] stage1_abtb_owned_count =
        abtb_monitor_counters.stage1_abtb_owned;
    wire [31:0] stage1_branch_owned_nt_count =
        abtb_monitor_counters.stage1_branch_owned_nt;
    wire [31:0] stage1_confirmed_branch_count =
        abtb_monitor_counters.stage1_confirmed_branch;
    wire [31:0] stage1_abtb_branch_hit_count =
        abtb_monitor_counters.stage1_abtb_branch_hit;
    wire [31:0] stage1_pht_taken_count =
        abtb_monitor_counters.stage1_pht_taken;
    wire [31:0] stage1_pht_not_taken_count =
        abtb_monitor_counters.stage1_pht_not_taken;
    wire [31:0] stage1_pht_correct_count =
        abtb_monitor_counters.stage1_pht_correct;
    wire [31:0] stage1_pht_wrong_count =
        abtb_monitor_counters.stage1_pht_wrong;
    wire [31:0] stage1_bank0_branch_lookup_count =
        abtb_monitor_counters.stage1_bank0_branch_lookup;
    wire [31:0] stage1_bank1_branch_lookup_count =
        abtb_monitor_counters.stage1_bank1_branch_lookup;
`endif

    // ---- 前端交付 / 兼容探针 ----
    wire        can_dual_issue;
    wire        raw_pair_raw;
    logic       predict_dual;
    wire [31:0] if_inst0_out = if_id_payload.slot0.inst;
    wire [31:0] if_inst1_out = if_id_payload.slot1.inst;
    wire [31:0] if_pc_out = if_id_payload.pc;
    wire        if_pred_taken_out = if_id_payload.slot0.prediction.taken;
    wire [31:0] if_pred_target_out = if_id_payload.slot0.prediction.target;
    wire        if_s1_pred_taken_out = if_id_payload.slot1.prediction.taken;
    wire [31:0] if_s1_pred_target_out = if_id_payload.slot1.prediction.target;
    wire        if_skip_out;
    wire        if_s1_valid;

    // 已停用的 raw-pair 和 skip 探针只为现有性能工具保留，不连接任何控制
    // 或数据通路消费者。
    wire raw_inst1_is_alu_type = 1'b0;
    wire raw_inst0_is_jump = 1'b0;
    wire if_sequential_fetch = ~if_pred_taken_out;
    wire skip_inst0_valid = 1'b0;

    // ================================================================
    //  模块实例化。
    // ================================================================

    // ==================== 全局流水线控制 ====================

    backend_flow_ctrl u_backend_flow_ctrl (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .cache_ready                 (cache_ready),
        .wb_allowin                  (wb_allowin),
        .id_valid                    (id_valid),
        .id_issue_is_muldiv          (id_issue_is_muldiv),
        .id_issue_serializing        (id_issue_hint.serializing),
        .id_decoded_serializing      (dec_uop.serializing),
        .id_dependency_ready         (id_dependency_ready),
        .id_dependency_ready_if_mem_ready(
            id_dependency_ready_if_mem_ready),
        .id_dependency_ready_if_mem_wait(
            id_dependency_ready_if_mem_wait),
        .id_non_load_hazard          (id_non_load_hazard),
        .id_flush                    (id_flush),
        .ex_valid                    (ex_valid),
        .ex_slot1_valid              (ex_s1_valid),
        .ex_is_muldiv                (ex_is_muldiv),
        .ex_is_divrem                (ex_muldiv_op[2]),
        .ex_priv_wait_older          (ex_priv_wait_older),
        .mmio_store_load_hazard      (mmio_st_ld_hazard),
        .mem_valid                   (mem_valid),
        .mem_slot1_valid             (mem_s1_valid),
        .mem_is_mul                  (mem_is_mul),
        .mem_branch_flush            (mem_branch_flush),
        .wb_valid                    (wb_valid),
        .wb_slot1_valid              (wb_s1_valid),
        .muldiv_busy                 (muldiv_busy),
        .muldiv_done                 (muldiv_done),
        .muldiv_consume              (muldiv_consume),
        .serializing_inflight        (serializing_inflight),
        .timer_irq_request           (timer_irq_request),
        .timer_irq_hold              (timer_irq_hold),
        .ex_muldiv_ready             (ex_muldiv_ready),
        .ex_priv_ready               (ex_priv_ready),
        .ex_priv_commit_ready        (ex_priv_commit_ready),
        .ex_ready_go                 (ex_ready_go),
        .mem_ready_go                (mem_ready_go),
        .mem_allowin_lsu             (mem_allowin_lsu),
        .mem_allowin_control         (mem_allowin_control),
        .mem_allowin_pipe            (mem_allowin_pipe),
        .timer_irq_block             (timer_irq_block),
        .id_serializing_ready        (id_serializing_ready),
        .id_barrier_ready            (id_barrier_ready),
        .id_muldiv_unit_ready        (id_muldiv_unit_ready),
        .id_ready_go                 (id_ready_go),
        .ex_allowin_if_cache_ready   (ex_allowin_if_cache_ready),
        .ex_allowin_if_cache_wait    (ex_allowin_if_cache_wait),
        .ex_allowin                  (ex_allowin),
        .ex_allowin_timing_copy      (ex_allowin_ex_local),
        .id_allowin                  (id_allowin),
        .id_allowin_pipe             (id_allowin_pipe),
        .id_allowin_frontend         (id_allowin_frontend),
        .id_to_ex_fire               (id_to_ex_fire)
    );

    serialization_ctrl u_serialization_ctrl (
        .clk                  (clk),
        .rst_n                (rst_n),
        .id_issue_fire        (id_to_ex_fire),
        .id_issue_serializing (id_issue_hint.serializing),
        .wb_slot0_valid       (wb_valid),
        .serializing_inflight (serializing_inflight)
    );

    // 重定向优先级集中在这里：EX 快速系统/定时器重定向可以覆盖旧的
    // 已寄存 MEM 重定向重放。
    redirect_ctrl u_redirect_ctrl (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .ex_ready_go                 (ex_ready_go),
        .mem_allowin                 (mem_allowin_control),
        .mem_branch_flush            (mem_branch_flush),
        .mem_branch_target           (mem_branch_target),
        .ex_priv_redirect            (ex_priv_redirect),
        .ex_priv_target              (ex_priv_target),
        .timer_irq_redirect          (timer_irq_redirect),
        .timer_irq_target            (timer_irq_target),
        .ex_redirect_fire            (ex_redirect_fire),
        .ex_fast_redirect            (ex_fast_redirect),
        .ex_fast_redirect_target     (ex_fast_redirect_target),
        .mem_branch_replay           (mem_branch_replay),
        .frontend_branch_flush       (frontend_branch_flush),
        .frontend_branch_target      (frontend_branch_target)
    );

    // 定时器中断等流水线为空后才重定向到 mtvec，从而保持精确陷阱入口。
    timer_irq_ctrl u_timer_irq_ctrl (
        .clk               (clk),
        .rst_n             (rst_n),
        .timer_irq_request (timer_irq_request),
        .id_valid          (id_valid),
        .frontend_flush    (frontend_branch_flush),
        .ex_valid          (ex_valid),
        .mem_valid         (mem_valid),
        .wb_valid          (wb_valid),
        .ex_s1_valid       (ex_s1_valid),
        .mem_s1_valid      (mem_s1_valid),
        .wb_s1_valid       (wb_s1_valid),
        .timer_irq_hold    (timer_irq_hold),
        .pipeline_empty    (timer_irq_pipe_empty),
        .timer_irq_take    (timer_irq_take)
    );

    // 两个发射槽共用的字段提取和轻量译码策略。
    id_stage_derive u_id_stage_derive (
        .id_pc             (id_pc),
        .slot0_uop         (dec_uop),
        .slot1_uop         (dec1_uop),
        .slot0_hint        (id_issue_hint),
        .slot1_hint        (id_s1_issue_hint),
        .id_rs1_addr       (id_rs1_addr),
        .id_rs2_addr       (id_rs2_addr),
        .id_rd_addr        (id_rd_addr),
        .id_s1_rs1_addr    (id_s1_rs1_addr),
        .id_s1_rs2_addr    (id_s1_rs2_addr),
        .id_s1_rd_addr     (id_s1_rd_addr),
        .id_pc_plus_4      (id_pc_plus_4),
        .id_s1_pc          (id_s1_pc),
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

    // ==================== 分支预测器 ====================
    // EX 确认控制流实际结果；更新控制器每周期最多选择一条架构有效的 CFI
    // 训练 ABTB/PHT。

    predictor_resolve_builder u_predictor_resolve_builder (
        .s0_valid             (ex_valid),
        .s0_pc                (ex_pc),
        .s0_is_conditional_control(ex_is_conditional_control),
        .s0_is_direct_control (ex_is_direct_control),
        .s0_is_indirect_control(ex_is_indirect_control),
        .s0_actual_taken      (actual_taken),
        .s0_actual_target     (actual_target),
        .s0_update_qualified  (ex_s0_prediction.update_qualified),
        .s0_update_cfi_type   (ex_s0_prediction.update_cfi_type),
        .s0_abtb_hit          (ex_abtb_hit),
        .s0_abtb_way          (ex_abtb_way),
        .s0_pht_index         (ex_stage1_pht_index),
        .s0_pht_counter       (ex_stage1_pht_counter),
        .s1_valid             (ex_s1_valid),
        .s1_pc                (ex_s1_pc),
        .s1_is_conditional_control(ex_s1_is_conditional_control),
        .s1_is_direct_control (ex_s1_is_direct_control),
        .s1_is_indirect_control(ex_s1_is_indirect_control),
        .s1_actual_taken      (ex_s1_actual_taken),
        .s1_actual_target     (ex_s1_branch_target),
        .s1_update_qualified  (ex_s1_prediction.update_qualified),
        .s1_update_cfi_type   (ex_s1_prediction.update_cfi_type),
        .s1_abtb_hit          (ex_s1_prediction.prediction.abtb_hit),
        .s1_abtb_way          (ex_s1_prediction.prediction.abtb_way),
        .s1_pht_index         (ex_s1_stage1_pht_index),
        .s1_pht_counter       (ex_s1_stage1_pht_counter),
        .slot0_resolve        (predictor_resolve_s0),
        .slot1_resolve        (predictor_resolve_s1)
    );

    predictor_update_ctrl u_predictor_update_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        .ex_ready_go      (ex_ready_go),
        .mem_allowin      (mem_allowin_control),
        .mem_branch_flush (mem_branch_flush),
        .slot0_resolve    (predictor_resolve_s0),
        .slot1_resolve    (predictor_resolve_s1),
        .slot0_cfi_valid  (s0_pred_update_valid_raw),
        .slot1_cfi_valid  (s1_pred_update_valid_raw),
        .train            (predictor_train),
        .abtb_update      (predictor_abtb_update),
        .pht_update       (predictor_pht_update),
        .abtb_write       (predictor_abtb_write),
        .pht_write        (predictor_pht_write)
    );

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
        .update_valid        (stage1_direction_write_valid),
        .update_index        (stage1_direction_write_index),
        .update_counter      (stage1_direction_write_counter),
        .update_actual_taken (stage1_direction_write_actual_taken),
        .committed_ghr       (stage1_committed_ghr)
    );

`ifdef ABTB_MEASUREMENT
    (* dont_touch = "true" *)
`endif
    frontend_abtb #(
        .LOCAL_LOOKUP_INDEX (1'b1),
        .RESET_PC           (RESET_PC)
    ) u_frontend_abtb (
        .clk                  (clk),
        .rst_n                (rst_n),
        .redirect_valid       (frontend_branch_flush),
        .redirect_target      (frontend_branch_target),
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
        .bank0_abtb_pred_target (abtb_bank0_abtb_pred_target),
        .bank0_pred_taken     (abtb_bank0_pred_taken),
        .bank0_final_pred_target (abtb_bank0_final_pred_target),
        .bank1_eligible       (),
        .bank1_lookup_hit     (abtb_bank1_lookup_hit),
        .bank1_hit            (abtb_bank1_hit),
        .bank1_way            (abtb_bank1_way),
        .bank1_cfi_type       (abtb_bank1_cfi_type),
        .bank1_abtb_pred_target (abtb_bank1_abtb_pred_target),
        .bank1_pred_taken     (abtb_bank1_pred_taken),
        .bank1_final_pred_target (abtb_bank1_final_pred_target),
        .pred_taken           (abtb_shadow_pred_taken),
        .pred_bank            (abtb_shadow_pred_bank),
        .pred_cfi_type        (abtb_shadow_pred_cfi_type),
        .pred_target          (abtb_shadow_pred_target),
        .pred_next_pc         (abtb_shadow_pred_next_pc),
        .pred_next_pc_early   (abtb_early_pred_next_pc),
        .update_valid         (predictor_abtb_write.valid),
        .update_hit           (predictor_abtb_write.hit),
        .update_way           (predictor_abtb_write.way),
        .update_pc            (predictor_abtb_write.pc),
        .update_cfi_type      (predictor_abtb_write.cfi_type),
        .update_target        (predictor_abtb_write.target)
    );

`ifdef CPU_TOP_ABTB_OBSERVE
    // 观测逻辑是单向接收端。打包事件和计数器不进入上面的正式预测器路径。
    frontend_abtb_observer u_frontend_abtb_observer (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .frontend_pc            (pc),
        .lookup_accept          (abtb_lookup_accept),
        .bank0_hit              (abtb_bank0_hit),
        .bank0_way              (abtb_bank0_way),
        .bank0_cfi_type         (abtb_bank0_cfi_type),
        .bank0_abtb_target      (abtb_bank0_abtb_pred_target),
        .bank0_pred_taken       (abtb_bank0_pred_taken),
        .bank0_final_target     (abtb_bank0_final_pred_target),
        .bank0_pht_taken        (stage1_bank0_pht_taken),
        .bank1_hit              (abtb_bank1_hit),
        .bank1_way              (abtb_bank1_way),
        .bank1_cfi_type         (abtb_bank1_cfi_type),
        .bank1_abtb_target      (abtb_bank1_abtb_pred_target),
        .bank1_pred_taken       (abtb_bank1_pred_taken),
        .bank1_final_target     (abtb_bank1_final_pred_target),
        .bank1_pht_taken        (stage1_bank1_pht_taken),
        .shadow_pred_taken      (abtb_shadow_pred_taken),
        .shadow_pred_bank       (abtb_shadow_pred_bank),
        .shadow_pred_cfi_type   (abtb_shadow_pred_cfi_type),
        .shadow_pred_target     (abtb_shadow_pred_target),
        .shadow_pred_next_pc    (abtb_shadow_pred_next_pc),
        .steer_valid            (stage1_steer_valid),
        .steer_source_abtb      (stage1_steer_source_abtb),
        .steer_branch_owned     (stage1_steer_branch_owned),
        .steer_branch_owned_nt  (stage1_steer_branch_owned_nt),
        .steer_bank             (stage1_steer_bank),
        .if_slot0_prediction    (if_id_payload.slot0.prediction),
        .if_slot1_prediction    (if_id_payload.slot1.prediction),
        .id_slot0_prediction    (id_payload.slot0.prediction),
        .id_slot1_prediction    (id_payload.slot1.prediction),
        .ex_slot0_prediction    (ex_s0_payload.common.prediction),
        .ex_slot1_prediction    (ex_s1_payload.common.prediction),
        .slot0_resolve          (predictor_resolve_s0),
        .slot1_resolve          (predictor_resolve_s1),
        .ex_ready_go            (ex_ready_go),
        .mem_allowin            (mem_allowin_control),
        .mem_branch_flush       (mem_branch_flush),
        .slot0_cfi_valid        (s0_pred_update_valid_raw),
        .slot0_redirect         (branch_flush),
        .slot1_redirect         (ex_s1_branch_redirect),
        .abtb_update            (predictor_abtb_update),
        .pht_update             (predictor_pht_update),
        .counters               (abtb_monitor_counters)
    );
`endif

    // ==================== Pre-IF（预取指） ====================

    assign irom_req_kill = frontend_branch_flush;

    // 前端 FTQ 管理 BP0/F0/F1 取指流程，向现有 IF/ID 寄存器最多返回两条
    // 已预译码的指令。
    frontend_ftq #(
        .VARIABLE_IROM_LATENCY(IROM_VARIABLE_LATENCY),
        .RESET_PC             (RESET_PC)
    ) u_frontend_ftq (
        .clk              (clk),
        .rst_n            (rst_n),
        .id_allowin       (id_allowin_frontend),
        .ex_redirect_valid(frontend_branch_flush),
        .ex_redirect_target(frontend_branch_target),
        .irom_addr        (irom_addr),
        .irom_req_valid   (irom_req_valid),
        .irom_req_addr    (irom_req_addr),
        .irom_req_ready   (irom_req_ready),
        .irom_resp_valid  (irom_resp_valid),
        .irom_data        (irom_data),
        .irom_resp_predecode(irom_resp_predecode),
        .abtb_bank0_lookup_hit  (abtb_bank0_lookup_hit),
        .abtb_bank0_hit         (abtb_bank0_hit),
        .abtb_bank0_way         (abtb_bank0_way),
        .abtb_bank0_cfi_type    (abtb_bank0_cfi_type),
        .abtb_bank0_abtb_pred_target      (abtb_bank0_abtb_pred_target),
        .abtb_bank0_pred_taken  (abtb_bank0_pred_taken),
        .abtb_bank0_final_pred_target (abtb_bank0_final_pred_target),
        .abtb_bank1_lookup_hit  (abtb_bank1_lookup_hit),
        .abtb_bank1_hit         (abtb_bank1_hit),
        .abtb_bank1_way         (abtb_bank1_way),
        .abtb_bank1_cfi_type    (abtb_bank1_cfi_type),
        .abtb_bank1_abtb_pred_target      (abtb_bank1_abtb_pred_target),
        .abtb_bank1_pred_taken  (abtb_bank1_pred_taken),
        .abtb_bank1_final_pred_target (abtb_bank1_final_pred_target),
        .abtb_pred_next_pc      (abtb_early_pred_next_pc),
        .stage1_bank0_pht_index(stage1_bank0_pht_index),
        .stage1_bank0_pht_counter(stage1_bank0_pht_counter),
        .stage1_bank1_pht_index(stage1_bank1_pht_index),
        .stage1_bank1_pht_counter(stage1_bank1_pht_counter),
        .if_valid         (if_valid),
        .if_ready_go      (if_ready_go),
        .if_s1_valid      (if_s1_valid),
        .if_payload       (if_id_payload),
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
        .if_ready_go  (if_ready_go),
        .id_allowin   (id_allowin_pipe),
        .id_valid     (id_valid),
        .id_flush     (id_flush),
        .if_s1_valid  (if_s1_valid),
        .id_s1_valid  (id_s1_valid),
        .if_payload   (if_id_payload),
        .id_payload   (id_payload),
        .id_s0_rf_rs1_addr(id_s0_rf_rs1_addr),
        .id_s0_rf_rs2_addr(id_s0_rf_rs2_addr),
        .id_s1_rf_rs1_addr(id_s1_rf_rs1_addr),
        .id_s1_rf_rs2_addr(id_s1_rf_rs2_addr)
    );

    loongarch_decoder u_decoder (
        .inst (id_inst),
        .uop  (dec_uop)
    );

    loongarch_decoder u_decoder_s1 (
        .inst (id_inst1),
        .uop  (dec1_uop)
    );

    regfile u_regfile (
        .clk          (clk),
        .rst_n        (rst_n),
        .rs1_addr     (id_s0_rf_rs1_addr),
        .rs2_addr     (id_s0_rf_rs2_addr),
        .rs1_data     (rf_rs1_data),
        .rs2_data     (rf_rs2_data),
        .rs1_addr_s1  (id_s1_rf_rs1_addr),
        .rs2_addr_s1  (id_s1_rf_rs2_addr),
        .rs1_data_s1  (rf_s1_rs1_data),
        .rs2_data_s1  (rf_s1_rs2_data),
        .rd_addr      (wb_rd),
        .rd_data      (wb_write_data),
        .rd_wen       (wb_reg_write_en),
        .rd_valid     (wb_valid),
        .rd_addr_s1   (wb_s1_rd),
        .rd_data_s1   (wb_s1_write_data),
        .rd_wen_s1    (wb_s1_reg_write_en),
        .rd_valid_s1  (wb_s1_valid),
        .debug_state  (debug_gpr_state)
    );

    // 前递逻辑报告数据相关性是否允许发射。定时器中断保持请求在其后生效，
    // 与其他 ID 阶段 ready 阻塞条件相同。
    forwarding u_forwarding (
        .id_rs1_addr    (id_rs1_addr),
        .id_rs2_addr    (id_rs2_addr),
        .id_rs1_used    (id_rs1_used),
        .id_rs2_used    (id_rs2_used),
        .id_s0_alu_only (id_s0_alu_only),
        .id_s0_conditional_control(id_issue_hint.conditional_control),
        .id_s0_mem_read (id_issue_hint.mem_read),
        .id_s0_mem_write(id_issue_hint.mem_write),
        .id_s0_is_mul   (id_issue_is_mul),
        .id_s0_pc       (id_pc),
        .id_s0_imm      (id_imm),
        .id_s0_alu_src1_sel(dec_alu_src1_sel),
        .id_s0_alu_src2_sel(dec_alu_src2_sel),
        .rf_rs1_data    (rf_rs1_data),
        .rf_rs2_data    (rf_rs2_data),
        .id_s1_valid    (id_s1_valid),
        .id_s1_rs1_addr (id_s1_rs1_addr),
        .id_s1_rs2_addr (id_s1_rs2_addr),
        .id_s1_rs1_used (id_s1_rs1_used),
        .id_s1_rs2_used (id_s1_rs2_used),
        .id_s1_repair_ok(id_s1_repair_ok),
        .id_s1_pc       (id_s1_pc),
        .id_s1_imm      (id_s1_imm),
        .id_s1_alu_src1_sel(dec1_alu_src1_sel),
        .id_s1_alu_src2_sel(dec1_alu_src2_sel),
        .rf_s1_rs1_data (rf_s1_rs1_data),
        .rf_s1_rs2_data (rf_s1_rs2_data),
        // 让 CSR/MulDiv/WB 修复后的架构结果物理上远离下一条 ID 操作数网络。
        // 快速副本只使用 ID/EX 寄存器中的操作数；修复产生者在正确结果到达
        // MEM 前已经由 repair-use 互锁覆盖。
        .ex_alu_result  (ex_fast_forward_result),
        .ex_fast_alu    (ex_fast_alu_forward),
        .ex_fast_alu_result(ex_fast_forward_result),
        .ex_pc_plus_4   (ex_pc_plus_4),
        .ex_wb_sel      (ex_wb_sel),
        .ex_hazard_valid(ex_s0_hazard_valid),
        .ex_hazard_reg_write(ex_s0_hazard_reg_write),
        .ex_hazard_is_muldiv(ex_s0_hazard_is_muldiv),
        .ex_hazard_mem_read(ex_s0_hazard_mem_read),
        .ex_hazard_result_repair(ex_s0_hazard_result_repair),
        .ex_hazard_rd   (ex_s0_hazard_rd),
        .ex_s1_alu_result  (ex_s1_fast_forward_result),
        .ex_s1_pc_plus_4   (ex_s1_pc_plus_4),
        .ex_s1_wb_sel      (ex_s1_wb_sel),
        .ex_s1_hazard_valid(ex_s1_hazard_valid),
        .ex_s1_hazard_reg_write(ex_s1_hazard_reg_write),
        .ex_s1_hazard_mem_read(ex_s1_hazard_mem_read),
        .ex_s1_hazard_result_repair(ex_s1_hazard_result_repair),
        .ex_s1_hazard_rd   (ex_s1_hazard_rd),
        // 前递和 load-hazard 比较使用窄的物理产生者镜像；结果数据仍从下面的
        // 规范 MEM payload 获取。
        .mem_valid      (mem_hazard_valid),
        .mem_reg_write  (mem_hazard_reg_write),
        .mem_is_load    (mem_hazard_is_load),
        .mem_is_mul     (mem_hazard_is_mul),
        .mem_rd         (mem_hazard_rd),
        .mem_fwd_s0_rd  (mem_fwd_s0_rd),
        .mem_fwd_s1_rd  (mem_fwd_s1_rd),
        .mem_alu_result (mem_alu_result),
        .mem_mul_result (muldiv_result),
        .mem_pc_plus_4  (mem_pc_plus_4),
        .mem_load_ready (mem_load_ready),
        .mem_wb_sel     (mem_hazard_wb_sel),
        // 前递和 load-hazard 比较使用物理局部的 EX/MEM 元数据副本。
        // 它与 LSU 和提交路径使用的规范 payload 字段周期一致。
        .mem_s1_valid       (mem_s1_hazard_valid),
        .mem_s1_reg_write   (mem_s1_reg_write_en),
        .mem_s1_is_load     (mem_s1_hazard_is_load),
        .mem_s1_rd          (mem_s1_hazard_rd),
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
        .id_s0_alu_src1 (id_alu_src1),
        .id_s0_alu_src2 (id_alu_src2),
        .id_s1_alu_src1 (id_s1_alu_src1),
        .id_s1_alu_src2 (id_s1_alu_src2),
        .id_rs1_wb_repair(fwd_rs1_wb_repair),
        .id_rs2_wb_repair(fwd_rs2_wb_repair),
        .id_rs1_wb_repair_s1(),
        .id_rs2_wb_repair_s1(),
        .id_s1_rs1_wb_repair(fwd_s1_rs1_wb_repair),
        .id_s1_rs2_wb_repair(fwd_s1_rs2_wb_repair),
        .id_s1_rs1_wb_repair_s1(),
        .id_s1_rs2_wb_repair_s1(),
        .id_ready_go    (id_dependency_ready),
        .id_ready_go_if_mem_ready(id_dependency_ready_if_mem_ready),
        .id_ready_go_if_mem_wait(id_dependency_ready_if_mem_wait),
        .id_non_load_hazard(id_non_load_hazard),
        .id_mul_launch_ex_raw_hazard(id_mul_launch_ex_raw_hazard)
    );

    // 让 DSP 操作数 MUX 物理上独立于普通 ID/EX 输出。真正的 EX -> MUL RAW
    // 已在上面互锁，因此只有已寄存的 MEM/WB/寄存器堆候选可以到达本地
    // DSP 输入寄存器。
    (* keep_hierarchy = "yes" *) mul_operand_forwarding u_mul_operand_forwarding (
        .id_rs1_addr          (id_s0_rf_rs1_addr),
        .id_rs2_addr          (id_s0_rf_rs2_addr),
        .rf_rs1_data          (rf_rs1_data),
        .rf_rs2_data          (rf_rs2_data),
        .mem_valid            (mem_valid),
        .mem_reg_write        (mem_reg_write_en),
        .mem_is_load          (mem_mem_read_en),
        .mem_is_mul           (mem_is_mul),
        .mem_rd               (mem_rd),
        .mem_alu_result       (mem_alu_result),
        .mem_mul_result       (muldiv_result),
        .mem_pc_plus_4        (mem_pc_plus_4),
        .mem_wb_sel           (mem_wb_sel),
        .mem_s1_valid         (mem_s1_valid),
        .mem_s1_reg_write     (mem_s1_reg_write_en),
        .mem_s1_is_load       (mem_s1_mem_read_en),
        .mem_s1_rd            (mem_s1_rd),
        .mem_s1_alu_result    (mem_s1_alu_result),
        .mem_s1_pc_plus_4     (mem_s1_pc_plus_4),
        .mem_s1_wb_sel        (mem_s1_wb_sel),
        .wb_valid             (wb_valid),
        .wb_reg_write         (wb_reg_write_en),
        .wb_rd                (wb_rd),
        .wb_write_data        (wb_write_data),
        .wb_s1_valid          (wb_s1_valid),
        .wb_s1_reg_write      (wb_s1_reg_write_en),
        .wb_s1_rd             (wb_s1_rd),
        .wb_s1_write_data     (wb_s1_write_data),
        .mul_rs1_data         (mul_fwd_rs1_data),
        .mul_rs2_data         (mul_fwd_rs2_data)
    );

    // ==================== ID/EX ====================

    // payload 构造器把大结构体的拼接移出时序寄存器过程。
    id_ex_payload_builder u_id_ex_payload_builder (
        .s0_pc                 (id_pc),
        .s0_inst               (id_inst),
        .s0_uop                (dec_uop),
        .s0_alu_src1           (id_alu_src1),
        .s0_alu_src2           (id_alu_src2),
        .s0_rs1_data           (fwd_rs1_data),
        .s0_rs2_data           (fwd_rs2_data),
        .s0_rs1_wb_repair      (fwd_rs1_wb_repair),
        .s0_rs2_wb_repair      (fwd_rs2_wb_repair),
        .s0_prediction         (id_payload.slot0.prediction),
        .s0_update_qualified   (id_abtb_update_qualified_w),
        .s0_update_cfi_type    (id_abtb_update_cfi_type_w),
        .s1_pc                 (id_s1_pc),
        .s1_inst               (id_inst1),
        .s1_uop                (dec1_uop),
        .s1_alu_src1           (id_s1_alu_src1),
        .s1_alu_src2           (id_s1_alu_src2),
        .s1_rs1_data           (fwd_s1_rs1_data),
        .s1_rs2_data           (fwd_s1_rs2_data),
        .s1_rs1_wb_repair      (fwd_s1_rs1_wb_repair),
        .s1_rs2_wb_repair      (fwd_s1_rs2_wb_repair),
        .s1_prediction         (id_payload.slot1.prediction),
        .s1_update_qualified   (id_s1_abtb_update_qualified_w),
        .s1_update_cfi_type    (id_s1_abtb_update_cfi_type_w),
        .slot0_payload         (id_ex_s0_payload),
        .slot1_payload         (id_ex_s1_payload)
    );

    id_ex_reg u_id_ex_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .id_valid         (id_valid),
        .id_ready_go      (id_ready_go),
        .cache_ready      (cache_ready),
        .ex_allowin_if_cache_ready(ex_allowin_if_cache_ready),
        .ex_allowin_if_cache_wait(ex_allowin_if_cache_wait),
        .ex_valid         (ex_valid),
        .ex_flush         (ex_flush),
        .id_payload       (id_ex_s0_payload),
        .ex_payload       (ex_s0_payload)
    );

    id_ex_reg_s1 u_id_ex_reg_s1 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .id_s1_valid         (id_s1_valid),
        .id_ready_go         (id_ready_go),
        .cache_ready         (cache_ready),
        .ex_allowin_if_cache_ready(ex_allowin_if_cache_ready),
        .ex_allowin_if_cache_wait(ex_allowin_if_cache_wait),
        .ex_flush            (ex_flush),
        .ex_s1_valid         (ex_s1_valid),
        .id_payload          (id_ex_s1_payload),
        .ex_payload          (ex_s1_payload)
    );

    id_ex_timing_mirror u_id_ex_timing_mirror (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .ex_stage_allowin            (ex_allowin_ex_local),
        .ex_stage_flush              (ex_flush),
        .id_slot0_valid              (id_valid),
        .id_slot1_valid              (id_s1_valid),
        .id_ready_go                 (id_ready_go),
        .id_slot0_store_bypass       (id_s0_alu_store_data_bypass),
        .id_slot0_payload            (id_ex_s0_payload),
        .id_slot1_payload            (id_ex_s1_payload),
        .ex_slot0_repair_q           (ex_s0_repair_q),
        .ex_slot1_repair_q           (ex_s1_repair_q),
        .ex_slot0_hazard_valid       (ex_s0_hazard_valid),
        .ex_slot0_hazard_reg_write   (ex_s0_hazard_reg_write),
        .ex_slot0_hazard_is_muldiv   (ex_s0_hazard_is_muldiv),
        .ex_slot0_hazard_mem_read    (ex_s0_hazard_mem_read),
        .ex_slot0_hazard_result_repair(
            ex_s0_hazard_result_repair),
        .ex_slot0_hazard_rd          (ex_s0_hazard_rd),
        .ex_slot1_hazard_valid       (ex_s1_hazard_valid),
        .ex_slot1_hazard_reg_write   (ex_s1_hazard_reg_write),
        .ex_slot1_hazard_mem_read    (ex_s1_hazard_mem_read),
        .ex_slot1_hazard_result_repair(
            ex_s1_hazard_result_repair),
        .ex_slot1_hazard_rd          (ex_s1_hazard_rd),
        .ex_slot1_fast_src2_low      (ex_s1_fast_src2_low),
        .ex_slot0_store_bypass_q     (ex_s0_store_data_bypass_q)
    );

    // ==================== EX 阶段 ====================
    // MEM 已 ready 的 load 消费者在这里从 WB 修复架构操作数。下面物理独立
    // 的原始操作数 ALU 服务更年轻的 ID 消费者，而 repair_use_hazard 会保持
    // 真正的消费者，直到修正结果在 MEM 中寄存。
    ex_stage_ctrl u_ex_stage_ctrl (
        .ex_pc                      (ex_pc),
        .ex_s1_pc                   (ex_s1_pc),
        .ex_valid                   (ex_valid),
        .ex_rs1_wb_repair           (ex_rs1_wb_repair),
        .ex_rs2_wb_repair           (ex_rs2_wb_repair),
        .wb_load_data_ex_s0         (wb_load_data_ex_s0),
        .wb_load_data_ex_s1         (wb_load_data_ex_s1),
        .ex_alu_src1                (ex_alu_src1),
        .ex_alu_src2                (ex_alu_src2),
        .ex_alu_src1_wb_repair      (ex_alu_src1_wb_repair),
        .ex_alu_src2_wb_repair      (ex_alu_src2_wb_repair),
        .ex_rs1_data                (ex_rs1_data),
        .ex_rs2_data                (ex_rs2_data),
        .ex_control_flow            (ex_control_flow),
        .ex_target_clear_mask       (ex_target_clear_mask),
        .ex_is_priv_reg             (ex_uses_priv_result),
        .ex_priv_rdata              (ex_priv_rdata),
        .ex_is_muldiv               (ex_is_muldiv),
        .ex_muldiv_result           (muldiv_result),
        .alu_result                 (alu_result),
        .ex_s1_valid                (ex_s1_valid),
        .ex_s1_control_flow         (ex_s1_control_flow),
        .ex_s1_branch_op            (ex_s1_branch_op),
        .ex_s1_target_clear_mask    (ex_s1_target_clear_mask),
        .ex_s1_rs1_wb_repair        (ex_s1_rs1_wb_repair),
        .ex_s1_rs2_wb_repair        (ex_s1_rs2_wb_repair),
        .ex_s1_alu_src1             (ex_s1_alu_src1),
        .ex_s1_alu_src2             (ex_s1_alu_src2),
        .ex_s1_alu_src1_wb_repair   (ex_s1_alu_src1_wb_repair),
        .ex_s1_alu_src2_wb_repair   (ex_s1_alu_src2_wb_repair),
        .ex_s1_rs1_data             (ex_s1_rs1_data),
        .ex_s1_rs2_data             (ex_s1_rs2_data),
        .ex_s1_predicted_taken      (ex_s1_pred_taken),
        .ex_s1_predicted_target     (ex_s1_pred_target),
        .ex_s1_addr_replay          (ex_s1_addr_replay),
        .mem_branch_flush           (mem_branch_flush),
        .ex_ready_go                (ex_ready_go),
        .mem_allowin                (mem_allowin_lsu),
        .ex_branch_flush            (branch_flush),
        .ex_redirect_fire           (ex_redirect_fire),
        .ex_branch_actual_taken     (actual_taken),
        .ex_priv_redirect           (ex_priv_redirect),
        .ex_priv_flow               (ex_priv_flow),
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
        .ex_registered_redirect_source(ex_registered_redirect_source),
        .ex_registered_redirect_actual_taken(
            ex_registered_redirect_actual_taken)
    );

    alu u_alu (
        .alu_op       (ex_alu_op),
        .alu_src1     (ex_alu_src1_repair),
        .alu_src2     (ex_alu_src2_repair),
        .alu_addr_src1(ex_alu_src1_repair),
        .alu_addr_src2(ex_alu_src2_repair),
        .alu_result   (alu_result),
        .alu_sum      (alu_sum),
        .alu_addr     (alu_addr)
    );

    alu u_alu_s1 (
        .alu_op       (ex_s1_alu_op),
        .alu_src1     (ex_s1_alu_src1_repair),
        .alu_src2     (ex_s1_alu_src2_repair),
        .alu_addr_src1(ex_s1_alu_src1_repair),
        .alu_addr_src2(ex_s1_alu_src2_repair),
        .alu_result   (alu_s1_result),
        .alu_sum      (alu_s1_sum),
        .alu_addr     (alu_s1_addr)
    );

    // 物理独立的普通结果副本，用于 EX 到 ID 的前递。输入直接来自 ID/EX
    // payload 寄存器，因此 WB load 修复和特权读数据不会进入旁路通路。
    // 上面的架构 ALU 保留全部修正后的行为。
    alu_result_datapath u_ex_fast_forward_alu (
        .alu_op     (ex_alu_op),
        .alu_src1   (ex_alu_src1),
        .alu_src2   (ex_alu_src2),
        .shift_amount(ex_alu_src2[4:0]),
        .alu_result (ex_fast_forward_result),
        .alu_sum    ()
    );

    alu_result_datapath u_ex_s1_fast_forward_alu (
        .alu_op     (ex_s1_alu_op),
        .alu_src1   (ex_s1_alu_src1),
        // 算术、比较和逻辑继续使用规范寄存操作数。只有桶形移位器使用物理
        // 局部的五位副本，因此该副本不会启动 32 位进位链。
        .alu_src2   (ex_s1_alu_src2),
        .shift_amount(ex_s1_fast_src2_low),
        .alu_result (ex_s1_fast_forward_result),
        .alu_sum    ()
    );

    lsu_address_prepare u_lsu_address_prepare_slot0 (
        .base_operand          (ex_alu_src1),
        .repaired_base_operand (wb_load_data_ex_s0),
        .offset_operand        (ex_alu_src2),
        .use_repaired_base     (ex_alu_src1_wb_repair),
        .lookup_addr_low       (ex_lsu_addr_low),
        .align_addr_low        (ex_lsu_align_low)
    );

    lsu_address_prepare u_lsu_address_prepare_slot1 (
        .base_operand          (ex_s1_alu_src1),
        .repaired_base_operand (wb_load_data_ex_s1),
        .offset_operand        (ex_s1_alu_src2),
        .use_repaired_base     (ex_s1_alu_src1_wb_repair),
        .lookup_addr_low       (ex_s1_lsu_addr_low),
        .align_addr_low        (ex_s1_lsu_align_low)
    );

    // MulDiv 包装器负责预启动、EX 完成和 MEM 结果生命周期。
    // 它的 ID 操作数来自物理独立的前递副本；不支持的 EX RAW 相关会在启动前
    // 被互锁。
    muldiv_pipeline u_muldiv_pipeline (
        .clk                  (clk),
        .rst_n                (rst_n),
        .id_mul_prestart      (id_mul_prestart),
        .id_muldiv_op         (dec_uop.muldiv_op),
        .id_mul_rs1           (mul_fwd_rs1_data),
        .id_mul_rs2           (mul_fwd_rs2_data),
        .ex_valid             (ex_valid),
        .ex_is_muldiv         (ex_is_muldiv),
        .ex_muldiv_op         (ex_muldiv_op),
        .ex_div_rs1           (ex_alu_src1),
        .ex_div_rs2           (ex_alu_src2),
        .ex_to_mem_allowin    (mem_allowin_lsu),
        .mem_valid            (mem_valid),
        .mem_is_mul           (mem_is_mul),
        .mem_alu_result       (mem_alu_result),
        .mem_ready            (cache_ready),
        .wb_allowin           (wb_allowin),
        .frontend_flush       (frontend_branch_flush),
        .mem_redirect_flush   (mem_branch_flush),
        .busy                 (muldiv_busy),
        .done                 (muldiv_done),
        .result               (muldiv_result),
        .consume              (muldiv_consume),
        .mem_writeback_result (mem_wb_alu_result)
    );

`ifndef SYNTHESIS
    pipeline_consistency_monitor u_pipeline_consistency_monitor (
        .clk                              (clk),
        .rst_n                            (rst_n),
        .id_slot0_valid                   (id_valid),
        .id_slot1_valid                   (id_s1_valid),
        .id_slot0_uop                     (dec_uop),
        .id_slot1_uop                     (dec1_uop),
        .id_slot0_issue_hint              (id_issue_hint),
        .id_slot1_issue_hint              (id_s1_issue_hint),
        .id_slot0_rf_rs1_addr             (id_s0_rf_rs1_addr),
        .id_slot0_rf_rs2_addr             (id_s0_rf_rs2_addr),
        .id_slot1_rf_rs1_addr             (id_s1_rf_rs1_addr),
        .id_slot1_rf_rs2_addr             (id_s1_rf_rs2_addr),
        .id_slot0_rs1_addr                (id_rs1_addr),
        .id_slot0_rs2_addr                (id_rs2_addr),
        .id_slot1_rs1_addr                (id_s1_rs1_addr),
        .id_slot1_rs2_addr                (id_s1_rs2_addr),
        .id_to_ex_fire                    (id_to_ex_fire),
        .id_mul_prestart                  (id_mul_prestart),
        .id_is_mul                        (id_is_mul),
        .id_slot0_alu_src1                (id_alu_src1),
        .id_slot0_alu_src2                (id_alu_src2),
        .id_slot1_alu_src1                (id_s1_alu_src1),
        .id_slot1_alu_src2                (id_s1_alu_src2),
        .id_slot0_forward_rs1             (fwd_rs1_data),
        .id_slot0_forward_rs2             (fwd_rs2_data),
        .id_slot1_forward_rs1             (fwd_s1_rs1_data),
        .id_slot1_forward_rs2             (fwd_s1_rs2_data),
        .id_slot0_pc                      (id_pc),
        .id_slot1_pc                      (id_s1_pc),
        .ex_slot0_valid                   (ex_valid),
        .ex_slot1_valid                   (ex_s1_valid),
        .ex_slot0_payload                 (ex_s0_payload),
        .ex_slot1_payload                 (ex_s1_payload),
        .ex_slot0_repair                  (ex_s0_repair_q),
        .ex_slot1_repair                  (ex_s1_repair_q),
        .ex_slot0_hazard_valid            (ex_s0_hazard_valid),
        .ex_slot0_hazard_reg_write        (ex_s0_hazard_reg_write),
        .ex_slot0_hazard_is_muldiv        (ex_s0_hazard_is_muldiv),
        .ex_slot0_hazard_mem_read         (ex_s0_hazard_mem_read),
        .ex_slot0_hazard_result_repair    (ex_s0_hazard_result_repair),
        .ex_slot0_hazard_rd               (ex_s0_hazard_rd),
        .ex_slot1_hazard_valid            (ex_s1_hazard_valid),
        .ex_slot1_hazard_reg_write        (ex_s1_hazard_reg_write),
        .ex_slot1_hazard_mem_read         (ex_s1_hazard_mem_read),
        .ex_slot1_hazard_result_repair    (ex_s1_hazard_result_repair),
        .ex_slot1_hazard_rd               (ex_s1_hazard_rd),
        .ex_slot1_fast_src2_low           (ex_s1_fast_src2_low),
        .ex_slot0_fast_forward_result     (ex_fast_forward_result),
        .ex_slot1_fast_forward_result     (ex_s1_fast_forward_result),
        .ex_slot0_alu_result              (alu_result),
        .ex_slot1_alu_result              (alu_s1_result),
        .mem_slot0_valid                  (mem_valid),
        .mem_slot1_valid                  (mem_s1_valid),
        .mem_slot0_payload                (mem_s0_payload),
        .mem_slot1_payload                (mem_s1_payload),
        .mem_allowin                      (mem_allowin),
        .mem_allowin_lsu                  (mem_allowin_lsu),
        .mem_allowin_control              (mem_allowin_control),
        .mem_allowin_pipe                 (mem_allowin_pipe),
        .mul_launch_ex_raw_hazard         (id_mul_launch_ex_raw_hazard),
        .mul_forward_rs1_data             (mul_fwd_rs1_data),
        .mul_forward_rs2_data             (mul_fwd_rs2_data),
        .architectural_forward_rs1_data   (fwd_rs1_data),
        .architectural_forward_rs2_data   (fwd_rs2_data),
        .muldiv_done                      (muldiv_done)
    );
`endif

    // LoongArch 模块负责特权寄存器和陷阱语义。
    loongarch_priv_unit u_isa_priv_unit (
        .clk                (clk),
        .rst_n              (rst_n),
        .ex_valid           (ex_valid),
        .ex_ready_go        (ex_ready_go),
        .ex_priv_commit_ready(ex_priv_commit_ready),
        .mem_allowin        (mem_allowin_control),
        .mem_branch_flush   (mem_branch_flush),
        .ex_redirect_fire   (ex_redirect_fire),
        .ex_pc              (ex_pc),
        .ex_inst            (ex_inst),
        // 特权操作只有在更老的后端 token 排空后才进入 EX，因此其寄存操作数
        // 不会携带 WB 修复标签。让通用 repair MUX 远离每一条 CSR 写数据路径。
        .ex_src0_data       (ex_rs1_data),
        .ex_src1_data       (ex_rs2_data),
        .ex_priv_op         (ex_priv_op),
        .ex_priv_uses_imm   (ex_priv_uses_imm),
        .ex_priv_cmd        (ex_priv_cmd),
        .ex_priv_addr       (ex_priv_addr),
        .ex_priv_imm        (ex_priv_imm),
        .ex_exception       (ex_exception),
        .ex_mem_read_en     (ex_mem_read_en),
        .ex_mem_write_en    (ex_mem_write_en),
        .ex_mem_size        (ex_mem_size),
        .ex_mem_addr        (alu_addr),
        .ex_mem_addr_low    (ex_lsu_align_low),
        .ex_s1_valid        (ex_s1_valid),
        .ex_s1_mem_read_en  (ex_s1_mem_read_en),
        .ex_s1_mem_write_en (ex_s1_mem_write_en),
        .ex_s1_mem_size     (ex_s1_mem_size),
        .ex_s1_mem_addr     (alu_s1_addr),
        .ex_s1_mem_addr_low (ex_s1_lsu_align_low),
        .timer_irq_pending  (timer_irq_pending),
        .timer_irq_take     (timer_irq_take),
        .timer_irq_mepc     (id_pc),
        .ex_priv_flow       (ex_priv_flow),
        .ex_priv_redirect   (ex_priv_redirect),
        .ex_priv_target     (ex_priv_target),
        .ex_priv_trap       (ex_priv_trap),
        .ex_priv_wait_older (ex_priv_wait_older),
        .ex_s1_addr_replay  (ex_s1_addr_replay),
        .timer_irq_request  (timer_irq_request),
        .timer_irq_redirect (timer_irq_redirect),
        .timer_irq_target   (timer_irq_target),
        .ex_priv_rdata      (ex_priv_rdata),
        .debug_excp_valid   (debug_excp_valid),
        .debug_ertn         (debug_ertn),
        .debug_intr_no      (debug_intr_no),
        .debug_cause        (debug_cause),
        .debug_exception_pc (debug_exception_pc),
        .debug_exception_inst(debug_exception_inst),
        .debug_priv_state   (debug_priv_state)
    );

    // Slot0 branch_unit 检查预测正确性；Slot1 重定向由 ex_stage_ctrl 处理，
    // 因为它有独立的年轻槽位优先级。
    branch_unit u_branch_unit (
        .target_pc        (ex_control_target),
        .src0_data        (ex_rs1_data_repair),
        .src1_data        (ex_rs2_data_repair),
        .control_flow     (ex_control_flow),
        .branch_op        (ex_branch_op),
        .ex_valid         (ex_valid),
        .predicted_taken  (ex_pred_taken),
        .predicted_target (ex_pred_target),
        .branch_flush     (branch_flush),
        .actual_taken     (actual_taken),
        .actual_target    (actual_target)
    );

    // ==================== Load/store 单元 ====================

    // 同组策略在 ID 阶段筛选 store-data 旁路；需要时在 EX 选择并屏蔽年轻
    // Slot1 请求。
    dual_issue_lsu_ctrl u_dual_issue_lsu_ctrl (
        .id_slot1_valid                 (id_s1_valid),
        .id_slot0_alu_only              (id_s0_alu_only),
        .id_slot0_reg_write_en          (dec_reg_write_en),
        .id_slot0_rd                    (id_rd_addr),
        .id_slot1_mem_write_en          (dec1_mem_write_en),
        .id_slot1_rs1                   (id_s1_rs1_addr),
        .id_slot1_rs2                   (id_s1_rs2_addr),
        .id_slot0_to_slot1_store_bypass (id_s0_alu_store_data_bypass),
        .ex_slot1_valid                 (ex_s1_valid),
        .ex_slot1_mem_read_en           (ex_s1_mem_read_en),
        .ex_slot1_mem_write_en          (ex_s1_mem_write_en),
        .ex_slot0_branch_redirect       (branch_flush),
        .ex_slot0_priv_trap             (ex_priv_trap),
        .ex_slot1_addr_replay           (ex_s1_addr_replay),
        .ex_slot1_lsu_select            (ex_s1_lsu_select_raw),
        .ex_slot1_side_effect_kill      (ex_s1_side_effect_kill),
        .ex_slot0_store_bypass_q        (ex_s0_store_data_bypass_q),
        .ex_slot0_alu_result            (alu_result),
        .ex_slot1_rs2_data              (ex_s1_rs2_data_repair),
        .ex_slot1_store_data            (ex_s1_store_data_raw)
    );

    // 数据格式化与请求仲裁独立：它准备两个 EX store 候选和共享的 MEM load 结果。
    lsu_data_format #(
        .CACHE_RDATA_FORMATTED(CACHE_RDATA_FORMATTED)
    ) u_lsu_data_format (
        .ex_slot0_valid             (ex_valid),
        .ex_slot0_kill              (ex_priv_trap),
        .ex_slot0_store             (ex_mem_write_en),
        .ex_slot0_addr_low          (ex_lsu_align_low),
        .ex_slot0_mem_size          (ex_mem_size),
        .ex_slot0_store_data        (ex_rs2_data_repair),
        .ex_slot0_store_wea         (dram_wea),
        .ex_slot1_valid             (ex_s1_valid),
        .ex_slot1_kill              (ex_s1_side_effect_kill),
        .ex_slot1_store             (ex_s1_mem_write_en),
        .ex_slot1_addr_low          (ex_s1_lsu_align_low),
        .ex_slot1_mem_size          (ex_s1_mem_size),
        .ex_slot1_store_data        (ex_s1_store_data_raw),
        .ex_slot1_store_wea         (dram_wea_s1),
        .mem_load_en                (mem_selected_load_en),
        .mem_load_addr_low          (mem_selected_load_addr_low),
        .mem_load_size              (mem_selected_load_size),
        .mem_load_unsigned          (mem_selected_load_unsigned),
        .mem_load_data              (mem_load_data),
        .mem_load_data_ex           (mem_load_data_ex),
        .mem_load_result            (mem_load_data_ext),
        .mem_load_repair_result     (mem_load_data_ext_ex)
    );

    // 请求路由选择实际发射槽位，将可缓存访问送往 DCache，将未缓存访问送往
    // MMIO，并返回原始 MEM 字。
    memory_access_unit #(
        .CACHE_ADDR_BASE  (CACHE_ADDR_BASE),
        .CACHE_ADDR_MASK  (CACHE_ADDR_MASK),
        .AXI_UNCACHED_DATA(AXI_UNCACHED_DATA)
    ) u_memory_access_unit (
        .ex_valid            (ex_valid),
        .ex_mem_read_en      (ex_mem_read_en & ~ex_priv_trap),
        .ex_mem_write_en     (ex_mem_write_en & ~ex_priv_trap),
        .ex_alu_addr         (alu_addr),
        .ex_lookup_addr      (ex_lsu_addr_low),
        .ex_mem_size         (ex_mem_size),
        .ex_mem_unsigned     (ex_mem_unsigned),
        .ex_store_wea        (dram_wea),
        .ex_store_data       (ex_rs2_data_repair),
        .ex_s1_lsu_select    (ex_s1_lsu_select_raw),
        .ex_s1_side_effect_kill(ex_s1_side_effect_kill),
        .ex_s1_mem_read_en   (ex_s1_mem_read_en),
        .ex_s1_mem_write_en  (ex_s1_mem_write_en),
        .ex_s1_alu_addr      (alu_s1_addr),
        .ex_s1_lookup_addr   (ex_s1_lsu_addr_low),
        .ex_s1_mem_size      (ex_s1_mem_size),
        .ex_s1_mem_unsigned  (ex_s1_mem_unsigned),
        .ex_s1_store_wea     (dram_wea_s1),
        .ex_s1_store_data    (ex_s1_store_data_raw),
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
        .mem_ready_go        (mem_ready_go),
        .mem_allowin         (mem_allowin_lsu),
        .mem_branch_flush    (mem_branch_flush),
        .cache_rdata         (cache_rdata),
        .cache_rdata_ex      (cache_rdata_ex),
        .mmio_rdata          (mmio_rdata),
        .dual_issue_count    (dual_issue_count),
        .is_cacheable        (is_cacheable),
        .is_cacheable_s1     (is_cacheable_s1),
        .mmio_st_ld_hazard   (mmio_st_ld_hazard),
        .cache_req           (cache_req),
        .cache_wr            (cache_wr),
        .cache_addr          (cache_addr),
        .cache_lookup_addr   (cache_lookup_addr),
        .cache_wea           (cache_wea),
        .cache_wdata         (cache_wdata),
        .cache_load_mask     (cache_load_mask),
        .cache_load_size     (cache_load_size),
        .cache_load_unsigned (cache_load_unsigned),
        .cache_uncached      (cache_uncached),
        .cache_flush         (cache_flush),
        .cache_pipeline_stall(cache_pipeline_stall),
        .mmio_addr           (mmio_addr),
        .mmio_wr_addr        (mmio_wr_addr),
        .mmio_wea            (mmio_wea),
        .mmio_wdata          (mmio_wdata),
        .mem_load_data       (mem_load_data),
        .mem_load_data_ex    (mem_load_data_ex),
        .mem_load_ready      (mem_load_ready)
    );

`ifndef SYNTHESIS
    lsu_consistency_monitor #(
        .AXI_UNCACHED_DATA (AXI_UNCACHED_DATA)
    ) u_lsu_consistency_monitor (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .ex_slot0_valid              (ex_valid),
        .ex_slot1_valid              (ex_s1_valid),
        .ex_slot0_payload            (ex_s0_payload),
        .ex_slot1_payload            (ex_s1_payload),
        .ex_slot0_repair             (ex_s0_repair_q),
        .ex_slot1_repair             (ex_s1_repair_q),
        .ex_slot0_branch_flush       (branch_flush),
        .ex_slot0_priv_trap          (ex_priv_trap),
        .ex_slot1_addr_replay        (ex_s1_addr_replay),
        .ex_slot0_lsu_addr_low       (ex_lsu_addr_low),
        .ex_slot1_lsu_addr_low       (ex_s1_lsu_addr_low),
        .ex_slot0_align_addr_low     (ex_lsu_align_low),
        .ex_slot1_align_addr_low     (ex_s1_lsu_align_low),
        .ex_slot0_alu_addr           (alu_addr),
        .ex_slot1_alu_addr           (alu_s1_addr),
        .ex_slot0_is_cacheable       (is_cacheable),
        .ex_slot1_is_cacheable       (is_cacheable_s1),
        .ex_slot0_store_data_bypass  (ex_s0_store_data_bypass_q),
        .ex_slot1_store_data         (ex_s1_store_data_raw),
        .ex_slot0_alu_result         (alu_result),
        .mem_branch_flush            (mem_branch_flush),
        .cache_req                   (cache_req),
        .mmio_store_load_hazard      (mmio_st_ld_hazard),
        .mem_slot0_payload           (mem_s0_payload),
        .mem_slot1_payload           (mem_s1_payload)
    );
`endif

    // ==================== EX/MEM ====================

    ex_mem_payload_builder u_ex_mem_payload_builder (
        .redirect_valid  (ex_registered_branch_flush),
        .redirect_source (ex_registered_redirect_source),
        .redirect_actual_taken(ex_registered_redirect_actual_taken),
        .s0_alu_result   (ex_pipe_alu_result),
        .s0_pc           (ex_pc),
        .s0_inst         (ex_inst),
        .s0_pc_plus_4    (ex_pc_plus_4),
        .s0_target_clear_mask(ex_target_clear_mask),
        .s0_priv_target  (ex_priv_target),
        .s0_rd           (ex_rd),
        .s0_reg_write_en (ex_reg_write_en & ~ex_priv_trap),
        .s0_wb_sel       (ex_wb_sel),
        .s0_is_mul       (ex_is_muldiv & ~ex_muldiv_op[2]),
        .s0_mem_read_en  (ex_mem_read_en & ~ex_priv_trap),
        .s0_mem_write_en (ex_mem_write_en & ~ex_priv_trap),
        .s0_mem_size     (ex_mem_size),
        .s0_mem_unsigned (ex_mem_unsigned),
        .s0_store_wea    (dram_wea & {4{~ex_priv_trap}}),
        .s0_store_data   (ex_rs2_data_repair),
        .s0_is_cacheable (is_cacheable),
        .s0_exception    (ex_priv_trap),
        .s0_csr_rstat    (ex_is_priv_reg
                          & (ex_priv_addr[13:0] == 14'h005)
                          & ~ex_priv_trap),
        .s0_csr_data     (ex_priv_rdata),
        .s1_pc           (ex_s1_pc),
        .s1_inst         (ex_s1_inst),
        .s1_alu_result   (alu_s1_result),
        .s1_pc_plus_4    (ex_s1_pc_plus_4),
        .s1_target_clear_mask(ex_s1_target_clear_mask),
        .s1_rd           (ex_s1_rd),
        .s1_reg_write_en (ex_s1_reg_write_en & ~ex_s1_side_effect_kill),
        .s1_wb_sel       (ex_s1_wb_sel),
        .s1_mem_read_en  (ex_s1_mem_read_en & ~ex_s1_side_effect_kill),
        .s1_mem_write_en (ex_s1_mem_write_en & ~ex_s1_side_effect_kill),
        .s1_mem_size     (ex_s1_mem_size),
        .s1_mem_unsigned (ex_s1_mem_unsigned),
        .s1_store_wea    (dram_wea_s1 & {4{~ex_s1_side_effect_kill}}),
        .s1_store_data   (ex_s1_store_data_raw),
        .s1_is_cacheable (is_cacheable_s1),
        .redirect        (ex_mem_redirect),
        .slot0_payload   (ex_mem_s0_payload),
        .slot1_payload   (ex_mem_s1_payload)
    );

    ex_mem_reg u_ex_mem_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .ex_valid         (ex_valid),
        .ex_ready_go      (ex_ready_go),
        .mem_allowin      (mem_allowin),
        .mem_valid        (mem_valid),
        .mem_ready_go     (mem_ready_go),
        .wb_allowin       (wb_allowin),
        .ex_redirect      (ex_mem_redirect),
        .mem_redirect     (mem_redirect),
        .ex_payload       (ex_mem_s0_payload),
        .mem_payload      (mem_s0_payload),
        .mem_hazard_valid (mem_hazard_valid),
        .mem_hazard_reg_write(mem_hazard_reg_write),
        .mem_hazard_is_load(mem_hazard_is_load),
        .mem_hazard_is_mul(mem_hazard_is_mul),
        .mem_hazard_rd    (mem_hazard_rd),
        .mem_fwd_s0_rd    (mem_fwd_s0_rd),
        .mem_fwd_s1_rd    (mem_fwd_s1_rd),
        .mem_hazard_wb_sel(mem_hazard_wb_sel)
    );

    ex_mem_reg_s1 u_ex_mem_reg_s1 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .ex_s1_valid         (ex_s1_valid),
        .ex_ready_go         (ex_ready_go),
        .mem_allowin         (mem_allowin_pipe),
        .ex_branch_flush     (branch_flush | ex_priv_trap
                              | ex_s1_addr_replay),
        .mem_branch_flush    (mem_branch_flush),
        .mem_s1_valid        (mem_s1_valid),
        .ex_payload          (ex_mem_s1_payload),
        .mem_payload         (mem_s1_payload),
        .mem_s1_hazard_valid (mem_s1_hazard_valid),
        .mem_s1_hazard_is_load(mem_s1_hazard_is_load),
        .mem_s1_hazard_rd    (mem_s1_hazard_rd)
    );

    redirect_target_select u_redirect_target_select (
        .redirect     (mem_redirect),
        .slot0_payload(mem_s0_payload),
        .slot1_payload(mem_s1_payload),
        .target       (mem_branch_target)
    );

`ifndef SYNTHESIS
    redirect_consistency_monitor u_redirect_consistency_monitor (
        .clk                            (clk),
        .rst_n                          (rst_n),
        .ex_redirect_valid              (ex_registered_branch_flush),
        .ex_redirect_source             (ex_registered_redirect_source),
        .ex_redirect_actual_taken       (
            ex_registered_redirect_actual_taken),
        .ex_priv_flow                   (ex_priv_flow),
        .ex_priv_target                 (ex_priv_target),
        .ex_slot0_branch_flush          (branch_flush),
        .ex_slot0_actual_taken          (actual_taken),
        .ex_slot0_control_target        (ex_control_target),
        .ex_slot0_pc_plus_4             (ex_pc_plus_4),
        .ex_slot0_valid                 (ex_valid),
        .ex_slot1_valid                 (ex_s1_valid),
        .ex_slot1_addr_replay           (ex_s1_addr_replay),
        .ex_slot1_pc                    (ex_s1_pc),
        .ex_slot1_actual_taken          (ex_s1_actual_taken),
        .ex_slot1_control_target        (ex_s1_branch_target),
        .ex_slot1_pc_plus_4             (ex_s1_pc_plus_4),
        .ex_slot0_mem_alu_candidate     (ex_pipe_alu_result),
        .ex_slot0_target_clear_mask     (ex_target_clear_mask),
        .ex_slot1_mem_alu_candidate     (alu_s1_result),
        .ex_slot1_target_clear_mask     (ex_s1_target_clear_mask),
        .mem_redirect                   (mem_redirect),
        .mem_redirect_target            (mem_branch_target)
    );
`endif

    // ==================== MEM/WB ====================

    mem_wb_payload_builder u_mem_wb_payload_builder (
        .s0_alu_result   (mem_wb_alu_result),
        .s0_pc           (mem_pc),
        .s0_inst         (mem_inst),
        .s0_pc_plus_4    (mem_pc_plus_4),
        .s0_rd           (mem_rd),
        .s0_reg_write_en (mem_reg_write_en),
        .s0_wb_sel       (mem_wb_sel),
        .s0_is_load      (mem_mem_read_en),
        .s0_load_data    (mem_load_data_ext),
        .s0_is_store     (mem_mem_write_en),
        .s0_mem_size     (mem_mem_size),
        .s0_mem_unsigned (mem_mem_unsigned),
        .s0_mem_addr     (mem_alu_result),
        .s0_store_data   (mem_store_data),
        .s0_exception    (mem_exception),
        .s0_csr_rstat    (mem_csr_rstat),
        .s0_csr_data     (mem_csr_data),
        .s1_pc           (mem_s1_pc),
        .s1_inst         (mem_s1_inst),
        .s1_alu_result   (mem_s1_alu_result),
        .s1_pc_plus_4    (mem_s1_pc_plus_4),
        .s1_rd           (mem_s1_rd),
        .s1_reg_write_en (mem_s1_reg_write_en),
        .s1_wb_sel       (mem_s1_wb_sel),
        .s1_is_load      (mem_s1_mem_read_en),
        .s1_is_store     (mem_s1_mem_write_en),
        .s1_mem_size     (mem_s1_mem_size),
        .s1_mem_unsigned (mem_s1_mem_unsigned),
        .s1_mem_addr     (mem_s1_alu_result),
        .s1_store_data   (mem_s1_store_data),
        .slot0_payload   (mem_wb_s0_payload),
        .slot1_payload   (mem_wb_s1_payload)
    );

    mem_wb_reg u_mem_wb_reg (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_valid      (mem_valid),
        .mem_ready_go   (mem_ready_go),
        .wb_allowin     (wb_allowin),
        .wb_valid       (wb_valid),
        .mem_load_valid (mem_load_valid),
        .mem_load_data_ex(mem_load_data_ext_ex),
        .mem_payload    (mem_wb_s0_payload),
        .wb_payload     (wb_s0_payload),
        .wb_load_data_ex_s0(wb_load_data_ex_s0),
        .wb_load_data_ex_s1(wb_load_data_ex_s1)
    );

    mem_wb_reg_s1 u_mem_wb_reg_s1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .mem_s1_valid  (mem_s1_valid),
        .mem_ready_go  (mem_ready_go),
        .wb_allowin    (wb_allowin),
        .mem_payload   (mem_wb_s1_payload),
        .wb_s1_valid   (wb_s1_valid),
        .wb_payload    (wb_s1_payload)
    );

    // ==================== WB 阶段 ====================

    wb_mux u_wb_mux (
        .wb_alu_result (wb_alu_result),
        .wb_load_data  (wb_load_data),
        .wb_pc_plus_4  (wb_pc_plus_4),
        .wb_sel        (wb_wb_sel),
        .wb_write_data (wb_write_data)
    );

    wb_mux u_wb_mux_s1 (
        .wb_alu_result (wb_s1_alu_result),
        .wb_load_data  (wb_load_data),
        .wb_pc_plus_4  (wb_s1_pc_plus_4),
        .wb_sel        (wb_s1_wb_sel),
        .wb_write_data (wb_s1_write_data)
    );

    commit_debug_adapter u_commit_debug_adapter (
        .wb_slot0_valid       (wb_valid),
        .wb_slot0_pc          (wb_s0_payload.pc),
        .wb_slot0_inst        (wb_s0_payload.inst),
        .wb_slot0_rd          (wb_s0_payload.rd),
        .wb_slot0_reg_write   (wb_s0_payload.reg_write_en),
        .wb_slot0_write_data  (wb_write_data),
        .wb_slot0_is_load     (wb_s0_payload.is_load),
        .wb_slot0_is_store    (wb_s0_payload.is_store),
        .wb_slot0_mem_size    (wb_s0_payload.mem_size),
        .wb_slot0_mem_unsigned(wb_s0_payload.mem_unsigned),
        .wb_slot0_mem_addr    (wb_s0_payload.mem_addr),
        .wb_slot0_store_data  (wb_s0_payload.store_data),
        .wb_slot0_exception   (wb_s0_payload.exception),
        .wb_slot0_csr_rstat   (wb_s0_payload.csr_rstat),
        .wb_slot0_csr_data    (wb_s0_payload.csr_data),
        .wb_slot1_valid       (wb_s1_valid),
        .wb_slot1_pc          (wb_s1_payload.pc),
        .wb_slot1_inst        (wb_s1_payload.inst),
        .wb_slot1_rd          (wb_s1_payload.rd),
        .wb_slot1_reg_write   (wb_s1_payload.reg_write_en),
        .wb_slot1_write_data  (wb_s1_write_data),
        .wb_slot1_is_load     (wb_s1_payload.is_load),
        .wb_slot1_is_store    (wb_s1_payload.is_store),
        .wb_slot1_mem_size    (wb_s1_payload.mem_size),
        .wb_slot1_mem_unsigned(wb_s1_payload.mem_unsigned),
        .wb_slot1_mem_addr    (wb_s1_payload.mem_addr),
        .wb_slot1_store_data  (wb_s1_payload.store_data),
        .debug0_wb_valid      (debug0_wb_valid),
        .debug0_wb_pc         (debug0_wb_pc),
        .debug0_wb_rf_wen     (debug0_wb_rf_wen),
        .debug0_wb_rf_wnum    (debug0_wb_rf_wnum),
        .debug0_wb_rf_wdata   (debug0_wb_rf_wdata),
        .debug0_wb_inst       (debug0_wb_inst),
        .debug0_wb_exception  (debug0_wb_exception),
        .debug0_wb_mem_read   (debug0_wb_mem_read),
        .debug0_wb_mem_write  (debug0_wb_mem_write),
        .debug0_wb_mem_size   (debug0_wb_mem_size),
        .debug0_wb_mem_unsigned(debug0_wb_mem_unsigned),
        .debug0_wb_mem_addr   (debug0_wb_mem_addr),
        .debug0_wb_store_data (debug0_wb_store_data),
        .debug0_wb_csr_rstat  (debug0_wb_csr_rstat),
        .debug0_wb_csr_data   (debug0_wb_csr_data),
        .debug1_wb_valid      (debug1_wb_valid),
        .debug1_wb_pc         (debug1_wb_pc),
        .debug1_wb_rf_wen     (debug1_wb_rf_wen),
        .debug1_wb_rf_wnum    (debug1_wb_rf_wnum),
        .debug1_wb_rf_wdata   (debug1_wb_rf_wdata),
        .debug1_wb_inst       (debug1_wb_inst),
        .debug1_wb_mem_read   (debug1_wb_mem_read),
        .debug1_wb_mem_write  (debug1_wb_mem_write),
        .debug1_wb_mem_size   (debug1_wb_mem_size),
        .debug1_wb_mem_unsigned(debug1_wb_mem_unsigned),
        .debug1_wb_mem_addr   (debug1_wb_mem_addr),
        .debug1_wb_store_data (debug1_wb_store_data)
    );

endmodule

`ifdef CPU_TOP_ABTB_OBSERVE
`undef CPU_TOP_ABTB_OBSERVE
`endif
