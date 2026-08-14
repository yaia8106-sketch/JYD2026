// ============================================================
// 中文说明：决定双发射组中的访存指令是否允许进入 LSU，并处理同周期访存冲突。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：dual_issue_lsu_ctrl。
// 说明：在两个发射槽之间协调唯一的 LSU。
// 所属单元：load/store。
// ID 决定 Slot0 ALU 结果是否供同组 Slot1 store 使用；EX 选择实际的 LSU
// 槽位，并在更老的 Slot0 重定向或陷阱时屏蔽年轻 Slot1 的副作用。
// ============================================================

module dual_issue_lsu_ctrl (
    // ID 阶段同组 store-data 旁路条件。
    input  logic        id_slot1_valid,
    input  logic        id_slot0_alu_only,
    input  logic        id_slot0_reg_write_en,
    input  logic [4:0]  id_slot0_rd,
    input  logic        id_slot1_mem_write_en,
    input  logic [4:0]  id_slot1_rs1,
    input  logic [4:0]  id_slot1_rs2,
    output logic        id_slot0_to_slot1_store_bypass,

    // EX 阶段的槽位选择和年轻指令副作用屏蔽。
    input  logic        ex_slot1_valid,
    input  logic        ex_slot1_mem_read_en,
    input  logic        ex_slot1_mem_write_en,
    input  logic        ex_slot0_branch_redirect,
    input  logic        ex_slot0_priv_trap,
    input  logic        ex_slot1_addr_replay,
    output logic        ex_slot1_lsu_select,
    output logic        ex_slot1_side_effect_kill,

    // 旁路决定与 ID/EX 一起寄存；EX 中只保留数据 MUX，寄存器比较不会进入
    // ALU-to-store-data 数据路径。
    input  logic        ex_slot0_store_bypass_q,
    input  logic [31:0] ex_slot0_alu_result,
    input  logic [31:0] ex_slot1_rs2_data,
    output logic [31:0] ex_slot1_store_data
);

    assign id_slot0_to_slot1_store_bypass = id_slot1_valid
        & id_slot0_alu_only
        & id_slot1_mem_write_en
        & id_slot0_reg_write_en
        & (id_slot0_rd != 5'd0)
        & (id_slot1_rs2 == id_slot0_rd)
        & (id_slot1_rs1 != id_slot0_rd);

    assign ex_slot1_lsu_select = ex_slot1_valid
        & (ex_slot1_mem_read_en | ex_slot1_mem_write_en);
    assign ex_slot1_side_effect_kill = ex_slot0_branch_redirect
                                     | ex_slot0_priv_trap
                                     | ex_slot1_addr_replay;

    assign ex_slot1_store_data = ex_slot0_store_bypass_q
                               ? ex_slot0_alu_result
                               : ex_slot1_rs2_data;

endmodule
