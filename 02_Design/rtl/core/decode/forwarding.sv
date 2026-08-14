// ============================================================
// 中文说明：根据各流水级的目的寄存器和结果状态，生成译码阶段的操作数前递选择及相关性信息。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：forwarding。
// 说明：生成操作数前递选择，并连接 load 相关性检测。
// 所属阶段：decode 和 issue。
// 规格说明：02_Design/spec/forwarding_spec.md。
// 实现方式：并行匹配、各流水级预选择，再使用编码的四路组 MUX。
// 产生链接地址的控制流指令选择 WB_NEXT_PC，因此前递必须返回链接地址，
// 不能返回独立计算出的控制流目标地址。
// ============================================================

module forwarding (
    // Slot0 ID 阶段。
    input  logic [ 4:0] id_rs1_addr,
    input  logic [ 4:0] id_rs2_addr,
    input  logic        id_rs1_used,
    input  logic        id_rs2_used,
    input  logic        id_s0_alu_only,
    input  logic        id_s0_conditional_control,
    input  logic        id_s0_mem_read,
    input  logic        id_s0_mem_write,
    input  logic        id_s0_is_mul,
    input  logic [31:0] id_s0_pc,
    input  logic [31:0] id_s0_imm,
    input  logic [ 1:0] id_s0_alu_src1_sel,
    input  logic        id_s0_alu_src2_sel,
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    // Slot1 ID 阶段。
    input  logic        id_s1_valid,
    input  logic [ 4:0] id_s1_rs1_addr,
    input  logic [ 4:0] id_s1_rs2_addr,
    input  logic        id_s1_rs1_used,
    input  logic        id_s1_rs2_used,
    input  logic        id_s1_repair_ok,
    input  logic [31:0] id_s1_pc,
    input  logic [31:0] id_s1_imm,
    input  logic [ 1:0] id_s1_alu_src1_sel,
    input  logic        id_s1_alu_src2_sel,
    input  logic [31:0] rf_s1_rs1_data,
    input  logic [31:0] rf_s1_rs2_data,

    // Slot0 EX 阶段。
    input  logic [31:0] ex_alu_result,
    input  logic        ex_fast_alu,
    input  logic [31:0] ex_fast_alu_result,
    input  logic [31:0] ex_pc_plus_4,   // EX 阶段预先计算的 PC+4
    input  logic [ 1:0] ex_wb_sel,      // 00=ALU, 01=DRAM, 10=PC+4

    // 物理局部的 Slot0 EX 元数据，供后向 hazard ready 判断。
    // 上面的操作数前递仍使用规范 EX payload。
    input  logic        ex_hazard_valid,
    input  logic        ex_hazard_reg_write,
    input  logic        ex_hazard_is_muldiv,
    input  logic        ex_hazard_mem_read,
    input  logic        ex_hazard_result_repair,
    input  logic [ 4:0] ex_hazard_rd,

    // Slot1 EX 阶段。
    input  logic [31:0] ex_s1_alu_result,
    input  logic [31:0] ex_s1_pc_plus_4,
    input  logic [ 1:0] ex_s1_wb_sel,

    // 物理局部的 Slot1 EX 元数据，供后向 hazard ready 判断。
    input  logic        ex_s1_hazard_valid,
    input  logic        ex_s1_hazard_reg_write,
    input  logic        ex_s1_hazard_mem_read,
    input  logic        ex_s1_hazard_result_repair,
    input  logic [ 4:0] ex_s1_hazard_rd,

    // Slot0 MEM 阶段。
    input  logic        mem_valid,
    input  logic        mem_reg_write,
    input  logic        mem_is_load,
    input  logic        mem_is_mul,
    input  logic [ 4:0] mem_rd,
    // 两份周期一致的 rd 副本分别终止在对应的 ID 槽位操作数簇中；
    // mem_rd 保持在本地，只用于 load-hazard 分类。
    input  logic [ 4:0] mem_fwd_s0_rd,
    input  logic [ 4:0] mem_fwd_s1_rd,
    input  logic [31:0] mem_alu_result,
    input  logic [31:0] mem_mul_result,
    input  logic [31:0] mem_pc_plus_4,  // 预先计算并在 EX/MEM 中寄存的 PC+4
    input  logic        mem_load_ready,
    input  logic [ 1:0] mem_wb_sel,     // 00=ALU, 01=DRAM, 10=PC+4

    // Slot1 MEM 阶段。
    input  logic        mem_s1_valid,
    input  logic        mem_s1_reg_write,
    input  logic        mem_s1_is_load,
    input  logic [ 4:0] mem_s1_rd,
    input  logic [31:0] mem_s1_alu_result,
    input  logic [31:0] mem_s1_pc_plus_4,
    input  logic [ 1:0] mem_s1_wb_sel,

    // Slot0 WB 阶段。
    input  logic        wb_valid,
    input  logic        wb_reg_write,
    input  logic [ 4:0] wb_rd,
    input  logic [31:0] wb_write_data,

    // Slot1 WB 阶段。
    input  logic        wb_s1_valid,
    input  logic        wb_s1_reg_write,
    input  logic [ 4:0] wb_s1_rd,
    input  logic [31:0] wb_s1_write_data,

    // 输出信号。
    output logic [31:0] id_rs1_data,
    output logic [31:0] id_rs2_data,
    output logic [31:0] id_s1_rs1_data,
    output logic [31:0] id_s1_rs2_data,
    output logic [31:0] id_s0_alu_src1,
    output logic [31:0] id_s0_alu_src2,
    output logic [31:0] id_s1_alu_src1,
    output logic [31:0] id_s1_alu_src2,
    output logic        id_rs1_wb_repair,
    output logic        id_rs2_wb_repair,
    output logic        id_rs1_wb_repair_s1,
    output logic        id_rs2_wb_repair_s1,
    output logic        id_s1_rs1_wb_repair,
    output logic        id_s1_rs2_wb_repair,
    output logic        id_s1_rs1_wb_repair_s1,
    output logic        id_s1_rs2_wb_repair_s1,
    output logic        id_ready_go,
    output logic        id_ready_go_if_mem_ready,
    output logic        id_ready_go_if_mem_wait,
    output logic        id_non_load_hazard,
    output logic        id_mul_launch_ex_raw_hazard
);

    // ================================================================
    //  前递值计算。
    //  EX/MEM 阶段 wb_sel==WB_NEXT_PC 时前递 PC+4。
    //  wb_sel==01 表示 load，数据尚未准备好，由停顿逻辑处理。
    //  控制流目标不再在 ID 中计算后，修复后的 EX 结果也可以作为前递源。
    // ================================================================
    wire [31:0] ex_fwd_val     = (ex_wb_sel == 2'b10)
                               ? ex_pc_plus_4 : ex_alu_result;
    wire mem_select_pc4 = mem_wb_sel == 2'b10;
    wire [31:0] mem_nonmul_fwd_val = mem_select_pc4
                                   ? mem_pc_plus_4 : mem_alu_result;
    wire [31:0] mem_s1_fwd_val = (mem_s1_wb_sel == 2'b10) ? mem_s1_pc_plus_4 : mem_s1_alu_result;

    // 选择编码与 32 位 payload 独立计算：00=EX，01=MEM，10=WB，11=寄存器堆。
    // 在六输入 LUT FPGA 上，各流水级先选好 S1/S0 数据后，四路 MUX 的每个
    // 输出位都可以映射到一个 LUT。
    function automatic logic [31:0] select_forward_group(
        input logic [ 1:0] group_select,
        input logic [31:0] ex_data,
        input logic [31:0] mem_data,
        input logic [31:0] wb_data,
        input logic [31:0] rf_data
    );
        case (group_select)
            2'b00: select_forward_group = ex_data;
            2'b01: select_forward_group = mem_data;
            2'b10: select_forward_group = wb_data;
            default: select_forward_group = rf_data;
        endcase
    endfunction

    // 将 EX 内部的两个选择折叠成一个适合 LUT 的四路选择：
    // 00=Slot1 ALU，01=Slot1 PC+4，10=Slot0 普通 ALU 快速路径，
    // 11=Slot0 特殊结果或 PC+4。
    // 最终的 EX/MEM/WB/RF 选择器保持不变，因此较老流水级路径不会增加
    // 一层数据 MUX。
    function automatic logic [31:0] select_ex_group_data(
        input logic [ 1:0] select,
        input logic [31:0] s1_alu_data,
        input logic [31:0] s1_pc4_data,
        input logic [31:0] s0_fast_data,
        input logic [31:0] s0_fallback_data
    );
        case (select)
            2'b00: select_ex_group_data = s1_alu_data;
            2'b01: select_ex_group_data = s1_pc4_data;
            2'b10: select_ex_group_data = s0_fast_data;
            default: select_ex_group_data = s0_fallback_data;
        endcase
    endfunction

    // Slot1 EX 是最年轻的产生者，因此始终优先于所有更老的前递源。
    // 在 32 位 payload 到达前，先编码互斥的立即数、S1-ALU、S1-PC+4 和
    // 更老源回退选择。这样每个结果位只需经过一个 LUT 大小的末级选择器，
    // 不必串过 EX 槽、流水级和立即数选择器。
    function automatic logic [31:0] select_s1_src2_fast(
        input logic [ 1:0] select,
        input logic [31:0] immediate_data,
        input logic [31:0] s1_alu_data,
        input logic [31:0] s1_pc4_data,
        input logic [31:0] older_fallback_data
    );
        case (select)
            2'b00:   select_s1_src2_fast = immediate_data;
            2'b01:   select_s1_src2_fast = s1_alu_data;
            2'b10:   select_s1_src2_fast = s1_pc4_data;
            default: select_s1_src2_fast = older_fallback_data;
        endcase
    endfunction

    function automatic logic [31:0] preselect_alu_src1(
        input logic [ 1:0] source_select,
        input logic [31:0] rs1_candidate,
        input logic [31:0] pc_candidate
    );
        case (source_select)
            2'b00:   preselect_alu_src1 = rs1_candidate;
            2'b01:   preselect_alu_src1 = pc_candidate;
            default: preselect_alu_src1 = 32'd0;
        endcase
    endfunction

    function automatic logic [31:0] preselect_alu_src2(
        input logic        source_select,
        input logic [31:0] rs2_candidate,
        input logic [31:0] imm_candidate
    );
        preselect_alu_src2 = source_select ? imm_candidate
                                           : rs2_candidate;
    endfunction

    // 为每个架构操作数保留一个显式逻辑锥。Vivado 可将其映射为四棵独立的
    // MUX 树，并保留时序优化实现所使用的 MUXF7/MUXF8 专用资源。
    // 重复结构是有意的：索引操作数数组会触发跨操作数提取，增加 ID/EX
    // 区域的布线压力。

    // ---------------- Slot0 源操作数 1 ----------------
    wire s0_rs1_s1_ex_hit = ex_s1_hazard_valid
        & ex_s1_hazard_reg_write & ~ex_s1_hazard_result_repair
        & (ex_s1_hazard_rd != 5'd0) & (ex_s1_hazard_rd == id_rs1_addr);
    wire s0_rs1_s0_ex_hit = ex_hazard_valid
        & ex_hazard_reg_write & ~ex_hazard_result_repair
        & (ex_hazard_rd != 5'd0) & (ex_hazard_rd == id_rs1_addr);
    wire s0_rs1_s1_mem_hit = mem_s1_valid & mem_s1_reg_write
        & ~mem_s1_is_load & (mem_s1_rd != 5'd0)
        & (mem_s1_rd == id_rs1_addr);
    wire s0_rs1_s0_mem_hit = mem_valid & mem_reg_write & ~mem_is_load
        & (mem_fwd_s0_rd != 5'd0) & (mem_fwd_s0_rd == id_rs1_addr);
    wire s0_rs1_s1_wb_hit = wb_s1_valid & wb_s1_reg_write
        & (wb_s1_rd != 5'd0) & (wb_s1_rd == id_rs1_addr);
    wire s0_rs1_s0_wb_hit = wb_valid & wb_reg_write
        & (wb_rd != 5'd0) & (wb_rd == id_rs1_addr);
    wire s0_rs1_ex_group_hit = s0_rs1_s1_ex_hit | s0_rs1_s0_ex_hit;
    wire s0_rs1_s0_mem_nonmul_hit = s0_rs1_s0_mem_hit
        & (~mem_is_mul | mem_select_pc4);
    wire s0_rs1_mem_group_hit = s0_rs1_s1_mem_hit
                              | s0_rs1_s0_mem_nonmul_hit;
    wire s0_rs1_wb_group_hit = s0_rs1_s1_wb_hit | s0_rs1_s0_wb_hit;
    wire s0_rs1_mem_mul_select = ~s0_rs1_ex_group_hit
        & ~s0_rs1_s1_mem_hit & s0_rs1_s0_mem_hit
        & mem_is_mul & ~mem_select_pc4;
    wire s0_rs1_wb_select_hit = s0_rs1_wb_group_hit
                              & ~s0_rs1_mem_mul_select;
    wire [1:0] s0_rs1_ex_data_select = s0_rs1_s1_ex_hit
        ? {1'b0, ex_s1_wb_sel == 2'b10}
        : {1'b1, ~ex_fast_alu};
    wire [31:0] s0_rs1_ex_group_data = select_ex_group_data(
        s0_rs1_ex_data_select, ex_s1_alu_result, ex_s1_pc_plus_4,
        ex_fast_alu_result, ex_fwd_val
    );
    wire [31:0] s0_rs1_mem_group_data = s0_rs1_s1_mem_hit
        ? mem_s1_fwd_val : mem_nonmul_fwd_val;
    wire [31:0] s0_rs1_wb_group_data = s0_rs1_s1_wb_hit
        ? wb_s1_write_data : wb_write_data;
    wire [31:0] s0_rs1_rf_or_mul_data = s0_rs1_mem_mul_select
        ? mem_mul_result : rf_rs1_data;
    wire [1:0] s0_rs1_group_select = {
        ~s0_rs1_ex_group_hit & ~s0_rs1_mem_group_hit,
        ~s0_rs1_ex_group_hit
            & (s0_rs1_mem_group_hit | ~s0_rs1_wb_select_hit)
    };
    assign id_rs1_data = select_forward_group(
        s0_rs1_group_select,
        s0_rs1_ex_group_data, s0_rs1_mem_group_data,
        s0_rs1_wb_group_data, s0_rs1_rf_or_mul_data
    );

    // ---------------- Slot0 源操作数 2 ----------------
    wire s0_rs2_s1_ex_hit = ex_s1_hazard_valid
        & ex_s1_hazard_reg_write & ~ex_s1_hazard_result_repair
        & (ex_s1_hazard_rd != 5'd0) & (ex_s1_hazard_rd == id_rs2_addr);
    wire s0_rs2_s0_ex_hit = ex_hazard_valid
        & ex_hazard_reg_write & ~ex_hazard_result_repair
        & (ex_hazard_rd != 5'd0) & (ex_hazard_rd == id_rs2_addr);
    wire s0_rs2_s1_mem_hit = mem_s1_valid & mem_s1_reg_write
        & ~mem_s1_is_load & (mem_s1_rd != 5'd0)
        & (mem_s1_rd == id_rs2_addr);
    wire s0_rs2_s0_mem_hit = mem_valid & mem_reg_write & ~mem_is_load
        & (mem_fwd_s0_rd != 5'd0) & (mem_fwd_s0_rd == id_rs2_addr);
    wire s0_rs2_s1_wb_hit = wb_s1_valid & wb_s1_reg_write
        & (wb_s1_rd != 5'd0) & (wb_s1_rd == id_rs2_addr);
    wire s0_rs2_s0_wb_hit = wb_valid & wb_reg_write
        & (wb_rd != 5'd0) & (wb_rd == id_rs2_addr);
    wire s0_rs2_ex_group_hit = s0_rs2_s1_ex_hit | s0_rs2_s0_ex_hit;
    wire s0_rs2_s0_mem_nonmul_hit = s0_rs2_s0_mem_hit
        & (~mem_is_mul | mem_select_pc4);
    wire s0_rs2_mem_group_hit = s0_rs2_s1_mem_hit
                              | s0_rs2_s0_mem_nonmul_hit;
    wire s0_rs2_wb_group_hit = s0_rs2_s1_wb_hit | s0_rs2_s0_wb_hit;
    wire s0_rs2_mem_mul_select = ~s0_rs2_ex_group_hit
        & ~s0_rs2_s1_mem_hit & s0_rs2_s0_mem_hit
        & mem_is_mul & ~mem_select_pc4;
    wire s0_rs2_wb_select_hit = s0_rs2_wb_group_hit
                              & ~s0_rs2_mem_mul_select;
    wire [1:0] s0_rs2_ex_data_select = s0_rs2_s1_ex_hit
        ? {1'b0, ex_s1_wb_sel == 2'b10}
        : {1'b1, ~ex_fast_alu};
    wire [31:0] s0_rs2_ex_group_data = select_ex_group_data(
        s0_rs2_ex_data_select, ex_s1_alu_result, ex_s1_pc_plus_4,
        ex_fast_alu_result, ex_fwd_val
    );
    wire [31:0] s0_rs2_mem_group_data = s0_rs2_s1_mem_hit
        ? mem_s1_fwd_val : mem_nonmul_fwd_val;
    wire [31:0] s0_rs2_wb_group_data = s0_rs2_s1_wb_hit
        ? wb_s1_write_data : wb_write_data;
    wire [31:0] s0_rs2_rf_or_mul_data = s0_rs2_mem_mul_select
        ? mem_mul_result : rf_rs2_data;
    wire [1:0] s0_rs2_group_select = {
        ~s0_rs2_ex_group_hit & ~s0_rs2_mem_group_hit,
        ~s0_rs2_ex_group_hit
            & (s0_rs2_mem_group_hit | ~s0_rs2_wb_select_hit)
    };
    assign id_rs2_data = select_forward_group(
        s0_rs2_group_select,
        s0_rs2_ex_group_data, s0_rs2_mem_group_data,
        s0_rs2_wb_group_data, s0_rs2_rf_or_mul_data
    );

    // ---------------- Slot1 源操作数 1 ----------------
    wire s1_rs1_s1_ex_hit = ex_s1_hazard_valid
        & ex_s1_hazard_reg_write & ~ex_s1_hazard_result_repair
        & (ex_s1_hazard_rd != 5'd0) & (ex_s1_hazard_rd == id_s1_rs1_addr);
    wire s1_rs1_s0_ex_hit = ex_hazard_valid
        & ex_hazard_reg_write & ~ex_hazard_result_repair
        & (ex_hazard_rd != 5'd0) & (ex_hazard_rd == id_s1_rs1_addr);
    wire s1_rs1_s1_mem_hit = mem_s1_valid & mem_s1_reg_write
        & ~mem_s1_is_load & (mem_s1_rd != 5'd0)
        & (mem_s1_rd == id_s1_rs1_addr);
    wire s1_rs1_s0_mem_hit = mem_valid & mem_reg_write & ~mem_is_load
        & (mem_fwd_s1_rd != 5'd0) & (mem_fwd_s1_rd == id_s1_rs1_addr);
    wire s1_rs1_s1_wb_hit = wb_s1_valid & wb_s1_reg_write
        & (wb_s1_rd != 5'd0) & (wb_s1_rd == id_s1_rs1_addr);
    wire s1_rs1_s0_wb_hit = wb_valid & wb_reg_write
        & (wb_rd != 5'd0) & (wb_rd == id_s1_rs1_addr);
    wire s1_rs1_ex_group_hit = s1_rs1_s1_ex_hit | s1_rs1_s0_ex_hit;
    wire s1_rs1_s0_mem_nonmul_hit = s1_rs1_s0_mem_hit
        & (~mem_is_mul | mem_select_pc4);
    wire s1_rs1_mem_group_hit = s1_rs1_s1_mem_hit
                              | s1_rs1_s0_mem_nonmul_hit;
    wire s1_rs1_wb_group_hit = s1_rs1_s1_wb_hit | s1_rs1_s0_wb_hit;
    wire s1_rs1_mem_mul_select = ~s1_rs1_ex_group_hit
        & ~s1_rs1_s1_mem_hit & s1_rs1_s0_mem_hit
        & mem_is_mul & ~mem_select_pc4;
    wire s1_rs1_wb_select_hit = s1_rs1_wb_group_hit
                              & ~s1_rs1_mem_mul_select;
    wire [1:0] s1_rs1_ex_data_select = s1_rs1_s1_ex_hit
        ? {1'b0, ex_s1_wb_sel == 2'b10}
        : {1'b1, ~ex_fast_alu};
    wire [31:0] s1_rs1_ex_group_data = select_ex_group_data(
        s1_rs1_ex_data_select, ex_s1_alu_result, ex_s1_pc_plus_4,
        ex_fast_alu_result, ex_fwd_val
    );
    wire [31:0] s1_rs1_mem_group_data = s1_rs1_s1_mem_hit
        ? mem_s1_fwd_val : mem_nonmul_fwd_val;
    wire [31:0] s1_rs1_wb_group_data = s1_rs1_s1_wb_hit
        ? wb_s1_write_data : wb_write_data;
    wire [31:0] s1_rs1_rf_or_mul_data = s1_rs1_mem_mul_select
        ? mem_mul_result : rf_s1_rs1_data;
    wire [1:0] s1_rs1_group_select = {
        ~s1_rs1_ex_group_hit & ~s1_rs1_mem_group_hit,
        ~s1_rs1_ex_group_hit
            & (s1_rs1_mem_group_hit | ~s1_rs1_wb_select_hit)
    };
    assign id_s1_rs1_data = select_forward_group(
        s1_rs1_group_select,
        s1_rs1_ex_group_data, s1_rs1_mem_group_data,
        s1_rs1_wb_group_data, s1_rs1_rf_or_mul_data
    );

    // ---------------- Slot1 源操作数 2 ----------------
    wire s1_rs2_s1_ex_hit = ex_s1_hazard_valid
        & ex_s1_hazard_reg_write & ~ex_s1_hazard_result_repair
        & (ex_s1_hazard_rd != 5'd0) & (ex_s1_hazard_rd == id_s1_rs2_addr);
    wire s1_rs2_s0_ex_hit = ex_hazard_valid
        & ex_hazard_reg_write & ~ex_hazard_result_repair
        & (ex_hazard_rd != 5'd0) & (ex_hazard_rd == id_s1_rs2_addr);
    wire s1_rs2_s1_mem_hit = mem_s1_valid & mem_s1_reg_write
        & ~mem_s1_is_load & (mem_s1_rd != 5'd0)
        & (mem_s1_rd == id_s1_rs2_addr);
    wire s1_rs2_s0_mem_hit = mem_valid & mem_reg_write & ~mem_is_load
        & (mem_fwd_s1_rd != 5'd0) & (mem_fwd_s1_rd == id_s1_rs2_addr);
    wire s1_rs2_s1_wb_hit = wb_s1_valid & wb_s1_reg_write
        & (wb_s1_rd != 5'd0) & (wb_s1_rd == id_s1_rs2_addr);
    wire s1_rs2_s0_wb_hit = wb_valid & wb_reg_write
        & (wb_rd != 5'd0) & (wb_rd == id_s1_rs2_addr);
    wire s1_rs2_ex_group_hit = s1_rs2_s1_ex_hit | s1_rs2_s0_ex_hit;
    wire s1_rs2_s0_mem_nonmul_hit = s1_rs2_s0_mem_hit
        & (~mem_is_mul | mem_select_pc4);
    wire s1_rs2_mem_group_hit = s1_rs2_s1_mem_hit
                              | s1_rs2_s0_mem_nonmul_hit;
    wire s1_rs2_wb_group_hit = s1_rs2_s1_wb_hit | s1_rs2_s0_wb_hit;
    wire s1_rs2_mem_mul_select = ~s1_rs2_ex_group_hit
        & ~s1_rs2_s1_mem_hit & s1_rs2_s0_mem_hit
        & mem_is_mul & ~mem_select_pc4;
    wire s1_rs2_wb_select_hit = s1_rs2_wb_group_hit
                              & ~s1_rs2_mem_mul_select;
    wire [1:0] s1_rs2_ex_data_select = s1_rs2_s1_ex_hit
        ? {1'b0, ex_s1_wb_sel == 2'b10}
        : {1'b1, ~ex_fast_alu};
    wire [31:0] s1_rs2_ex_group_data = select_ex_group_data(
        s1_rs2_ex_data_select, ex_s1_alu_result, ex_s1_pc_plus_4,
        ex_fast_alu_result, ex_fwd_val
    );
    wire [31:0] s1_rs2_mem_group_data = s1_rs2_s1_mem_hit
        ? mem_s1_fwd_val : mem_nonmul_fwd_val;
    wire [31:0] s1_rs2_wb_group_data = s1_rs2_s1_wb_hit
        ? wb_s1_write_data : wb_write_data;
    wire [31:0] s1_rs2_rf_or_mul_data = s1_rs2_mem_mul_select
        ? mem_mul_result : rf_s1_rs2_data;
    wire [1:0] s1_rs2_group_select = {
        ~s1_rs2_ex_group_hit & ~s1_rs2_mem_group_hit,
        ~s1_rs2_ex_group_hit
            & (s1_rs2_mem_group_hit | ~s1_rs2_wb_select_hit)
    };
    assign id_s1_rs2_data = select_forward_group(
        s1_rs2_group_select,
        s1_rs2_ex_group_data, s1_rs2_mem_group_data,
        s1_rs2_wb_group_data, s1_rs2_rf_or_mul_data
    );

    // ALU 源选择过去位于完整前递 MUX 之后，因此 MEM/EX 匹配控制在到达 ID/EX
    // 之前要依次经过组选择器和 alu_src MUX。现在对所有已经预选的 payload
    // 并行做源变换，再复用同一个末级组选择器。
    // 报告中的 Slot1 src2 逻辑锥使用 KEEP，防止综合把立即数项重新提取到
    // 前递 MUX 后面；其他源逻辑锥保留同样的表达式，但不强制复制。
    wire [31:0] s0_alu_src1_ex_candidate =
        preselect_alu_src1(id_s0_alu_src1_sel,
                           s0_rs1_ex_group_data, id_s0_pc);
    wire [31:0] s0_alu_src1_mem_candidate =
        preselect_alu_src1(id_s0_alu_src1_sel,
                           s0_rs1_mem_group_data, id_s0_pc);
    wire [31:0] s0_alu_src1_wb_candidate =
        preselect_alu_src1(id_s0_alu_src1_sel,
                           s0_rs1_wb_group_data, id_s0_pc);
    wire [31:0] s0_alu_src1_rf_candidate =
        preselect_alu_src1(id_s0_alu_src1_sel,
                           s0_rs1_rf_or_mul_data, id_s0_pc);

    wire [31:0] s0_alu_src2_ex_candidate =
        preselect_alu_src2(id_s0_alu_src2_sel,
                           s0_rs2_ex_group_data, id_s0_imm);
    wire [31:0] s0_alu_src2_mem_candidate =
        preselect_alu_src2(id_s0_alu_src2_sel,
                           s0_rs2_mem_group_data, id_s0_imm);
    wire [31:0] s0_alu_src2_wb_candidate =
        preselect_alu_src2(id_s0_alu_src2_sel,
                           s0_rs2_wb_group_data, id_s0_imm);
    wire [31:0] s0_alu_src2_rf_candidate =
        preselect_alu_src2(id_s0_alu_src2_sel,
                           s0_rs2_rf_or_mul_data, id_s0_imm);

    // 对时序关键的 Slot1 source1 结果，把最年轻的 Slot1 EX 产生者从完整的
    // 老源树中移出。它的结果和已经完成的老源回退值并行计算，EX 加法器/移位器
    // 之后只保留一个 LUT 大小的末级选择。
    wire s1_rs1_older_ex_hit = s1_rs1_s0_ex_hit;
    wire s1_rs1_older_mem_mul_select = !s1_rs1_older_ex_hit
        && !s1_rs1_s1_mem_hit && s1_rs1_s0_mem_hit && mem_is_mul
        && !mem_select_pc4;
    wire s1_rs1_older_wb_select_hit = s1_rs1_wb_group_hit
        && !s1_rs1_older_mem_mul_select;
    wire [1:0] s1_rs1_older_group_select = {
        ~s1_rs1_older_ex_hit & ~s1_rs1_mem_group_hit,
        ~s1_rs1_older_ex_hit
            & (s1_rs1_mem_group_hit | ~s1_rs1_older_wb_select_hit)
    };
    wire [31:0] s1_rs1_s0_ex_data = ex_fast_alu
        ? ex_fast_alu_result : ex_fwd_val;
    wire [31:0] s1_rs1_older_rf_or_mul_data =
        s1_rs1_older_mem_mul_select ? mem_mul_result : rf_s1_rs1_data;
    wire [31:0] s1_rs1_older_fallback = select_forward_group(
        s1_rs1_older_group_select,
        s1_rs1_s0_ex_data,
        s1_rs1_mem_group_data,
        s1_rs1_wb_group_data,
        s1_rs1_older_rf_or_mul_data
    );
    wire [31:0] s1_alu_src1_older_candidate = preselect_alu_src1(
        id_s1_alu_src1_sel, s1_rs1_older_fallback, id_s1_pc
    );

    // 构造不包含 Slot1 EX 的完整前递结果。只有 s1_rs2_s1_ex_hit 为低时才
    // 选择这个回退结果；保持其独立也能移除 S1 桶形移位器到老源树的所有
    // 静态数据路径。
    wire s1_rs2_older_ex_hit = s1_rs2_s0_ex_hit;
    wire s1_rs2_older_mem_mul_select = !s1_rs2_older_ex_hit
        && !s1_rs2_s1_mem_hit && s1_rs2_s0_mem_hit && mem_is_mul
        && !mem_select_pc4;
    wire s1_rs2_older_wb_select_hit = s1_rs2_wb_group_hit
        && !s1_rs2_older_mem_mul_select;
    wire [1:0] s1_rs2_older_group_select = {
        ~s1_rs2_older_ex_hit & ~s1_rs2_mem_group_hit,
        ~s1_rs2_older_ex_hit
            & (s1_rs2_mem_group_hit | ~s1_rs2_older_wb_select_hit)
    };
    wire [31:0] s1_rs2_s0_ex_data = ex_fast_alu
        ? ex_fast_alu_result : ex_fwd_val;
    wire [31:0] s1_rs2_older_rf_or_mul_data =
        s1_rs2_older_mem_mul_select ? mem_mul_result : rf_s1_rs2_data;
    wire [31:0] s1_rs2_older_fallback = select_forward_group(
        s1_rs2_older_group_select,
        s1_rs2_s0_ex_data,
        s1_rs2_mem_group_data,
        s1_rs2_wb_group_data,
        s1_rs2_older_rf_or_mul_data
    );

    // 选择编码刻意独立于所有 32 位结果数据：00=立即数，01=S1 ALU，
    // 10=S1 PC+4，11=更老的前递回退结果。
    wire [1:0] s1_alu_src2_fast_select = id_s1_alu_src2_sel
        ? 2'b00
        : s1_rs2_s1_ex_hit
            ? ((ex_s1_wb_sel == 2'b10) ? 2'b10 : 2'b01)
            : 2'b11;

    // 01=S1 ALU，10=S1 PC+4，11=预选的 PC/零/更老操作数。
    // PC/零操作数不是寄存器消费者，因此即使无效指令位恰好等于产生者 rd，
    // 也不会匹配 EX 产生者。
    wire [1:0] s1_alu_src1_fast_select =
        (id_s1_alu_src1_sel == 2'b00) && s1_rs1_s1_ex_hit
            ? ((ex_s1_wb_sel == 2'b10) ? 2'b10 : 2'b01)
            : 2'b11;

    assign id_s0_alu_src1 = select_forward_group(
        s0_rs1_group_select,
        s0_alu_src1_ex_candidate, s0_alu_src1_mem_candidate,
        s0_alu_src1_wb_candidate, s0_alu_src1_rf_candidate
    );
    assign id_s0_alu_src2 = select_forward_group(
        s0_rs2_group_select,
        s0_alu_src2_ex_candidate, s0_alu_src2_mem_candidate,
        s0_alu_src2_wb_candidate, s0_alu_src2_rf_candidate
    );
    assign id_s1_alu_src1 = select_s1_src2_fast(
        s1_alu_src1_fast_select,
        32'd0,
        ex_s1_alu_result,
        ex_s1_pc_plus_4,
        s1_alu_src1_older_candidate
    );
    assign id_s1_alu_src2 = select_s1_src2_fast(
        s1_alu_src2_fast_select,
        id_s1_imm,
        ex_s1_alu_result,
        ex_s1_pc_plus_4,
        s1_rs2_older_fallback
    );

    // ================================================================
    //  相关性策略接入。
    // ================================================================
    // repair 是一个“一拍后可用”的约定：消费者当前前进，下一拍在 EX 中
    // 用已经寄存的 load 结果替换操作数。条件分支只修复比较操作数；JIRL
    // 还用 rs1 计算重定向目标，因此必须等待。
    wire id_s0_repair_ok = id_s0_alu_only
                         | id_s0_conditional_control
                         | id_s0_mem_read
                         | id_s0_mem_write;

    // 这些信号有意保留在 forwarding 作用域内，因为性能统计和 Konata 监控器
    // 依赖既有的层次结构。
    wire id_s0_uses_ex_load;
    wire id_s1_uses_ex_load;
    wire id_s0_uses_s1_ex_load;
    wire id_s1_uses_s1_ex_load;
    wire id_s0_uses_mem_load;
    wire id_s1_uses_mem_load;
    wire id_s0_uses_s1_mem_load;
    wire id_s1_uses_s1_mem_load;
    wire load_in_ex;
    wire load_in_s1_ex;
    wire load_in_mem;
    wire load_in_s1_mem;
    wire load_use_hazard;
    wire repair_use_hazard;
    wire muldiv_use_hazard;
    wire mul_launch_ex_raw_hazard;
    assign id_mul_launch_ex_raw_hazard = mul_launch_ex_raw_hazard;

    issue_hazard_ctrl u_issue_hazard_ctrl (
        .id_rs1_addr                (id_rs1_addr),
        .id_rs2_addr                (id_rs2_addr),
        .id_rs1_used                (id_rs1_used),
        .id_rs2_used                (id_rs2_used),
        .id_s0_repair_ok            (id_s0_repair_ok),
        .id_s0_is_mul               (id_s0_is_mul),
        .id_s1_valid                (id_s1_valid),
        .id_s1_rs1_addr             (id_s1_rs1_addr),
        .id_s1_rs2_addr             (id_s1_rs2_addr),
        .id_s1_rs1_used             (id_s1_rs1_used),
        .id_s1_rs2_used             (id_s1_rs2_used),
        .id_s1_repair_ok            (id_s1_repair_ok),
        .ex_s0_valid                (ex_hazard_valid),
        .ex_s0_reg_write            (ex_hazard_reg_write),
        .ex_s0_is_muldiv            (ex_hazard_is_muldiv),
        .ex_s0_mem_read             (ex_hazard_mem_read),
        .ex_s0_result_repair        (ex_hazard_result_repair),
        .ex_s0_rd                   (ex_hazard_rd),
        .ex_s1_valid                (ex_s1_hazard_valid),
        .ex_s1_reg_write            (ex_s1_hazard_reg_write),
        .ex_s1_mem_read             (ex_s1_hazard_mem_read),
        .ex_s1_result_repair        (ex_s1_hazard_result_repair),
        .ex_s1_rd                   (ex_s1_hazard_rd),
        .mem_s0_valid               (mem_valid),
        .mem_s0_reg_write           (mem_reg_write),
        .mem_s0_is_load             (mem_is_load),
        .mem_s0_rd                  (mem_rd),
        .mem_s1_valid               (mem_s1_valid),
        .mem_s1_reg_write           (mem_s1_reg_write),
        .mem_s1_is_load             (mem_s1_is_load),
        .mem_s1_rd                  (mem_s1_rd),
        .mem_load_ready             (mem_load_ready),
        .s0_rs1_s1_ex_hit           (s0_rs1_s1_ex_hit),
        .s0_rs1_s0_ex_hit           (s0_rs1_s0_ex_hit),
        .s0_rs1_s1_mem_hit          (s0_rs1_s1_mem_hit),
        .s0_rs2_s1_ex_hit           (s0_rs2_s1_ex_hit),
        .s0_rs2_s0_ex_hit           (s0_rs2_s0_ex_hit),
        .s0_rs2_s1_mem_hit          (s0_rs2_s1_mem_hit),
        .s1_rs1_s1_ex_hit           (s1_rs1_s1_ex_hit),
        .s1_rs1_s0_ex_hit           (s1_rs1_s0_ex_hit),
        .s1_rs1_s1_mem_hit          (s1_rs1_s1_mem_hit),
        .s1_rs2_s1_ex_hit           (s1_rs2_s1_ex_hit),
        .s1_rs2_s0_ex_hit           (s1_rs2_s0_ex_hit),
        .s1_rs2_s1_mem_hit          (s1_rs2_s1_mem_hit),
        .id_rs1_wb_repair           (id_rs1_wb_repair),
        .id_rs2_wb_repair           (id_rs2_wb_repair),
        .id_rs1_wb_repair_s1        (id_rs1_wb_repair_s1),
        .id_rs2_wb_repair_s1        (id_rs2_wb_repair_s1),
        .id_s1_rs1_wb_repair        (id_s1_rs1_wb_repair),
        .id_s1_rs2_wb_repair        (id_s1_rs2_wb_repair),
        .id_s1_rs1_wb_repair_s1     (id_s1_rs1_wb_repair_s1),
        .id_s1_rs2_wb_repair_s1     (id_s1_rs2_wb_repair_s1),
        .id_ready_go                (id_ready_go),
        .id_ready_go_if_mem_ready   (id_ready_go_if_mem_ready),
        .id_ready_go_if_mem_wait    (id_ready_go_if_mem_wait),
        .id_non_load_hazard         (id_non_load_hazard),
        .id_s0_uses_ex_load         (id_s0_uses_ex_load),
        .id_s1_uses_ex_load         (id_s1_uses_ex_load),
        .id_s0_uses_s1_ex_load      (id_s0_uses_s1_ex_load),
        .id_s1_uses_s1_ex_load      (id_s1_uses_s1_ex_load),
        .id_s0_uses_mem_load        (id_s0_uses_mem_load),
        .id_s1_uses_mem_load        (id_s1_uses_mem_load),
        .id_s0_uses_s1_mem_load     (id_s0_uses_s1_mem_load),
        .id_s1_uses_s1_mem_load     (id_s1_uses_s1_mem_load),
        .load_in_ex                 (load_in_ex),
        .load_in_s1_ex              (load_in_s1_ex),
        .load_in_mem                (load_in_mem),
        .load_in_s1_mem             (load_in_s1_mem),
        .load_use_hazard            (load_use_hazard),
        .repair_use_hazard          (repair_use_hazard),
        .muldiv_use_hazard          (muldiv_use_hazard),
        .mul_launch_ex_raw_hazard   (mul_launch_ex_raw_hazard)
    );

    // 保留为具名兼容探针。EX 产生的控制流操作数现在使用普通前递并在 EX
    // 中解析；Slot1 的 WB 结果也可以前递。
    wire indirect_control_ex_wait_hazard = 1'b0;
    wire conditional_control_ex_wait_hazard = 1'b0;
    wire s1_wb_wait_hazard = 1'b0;

endmodule
