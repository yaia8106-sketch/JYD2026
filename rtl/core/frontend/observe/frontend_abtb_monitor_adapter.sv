// ============================================================
// 中文说明：把前端 ABTB 内部信号转换成统一的观察接口。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：frontend_abtb_monitor_adapter。
// 说明：将 ABTB 观测元数据纯组合地打包成统一接口。
// 所属部分：前端观测。
// 这些输出只由 frontend_abtb_monitor 消费。
// ============================================================

module frontend_abtb_monitor_adapter
    import cpu_defs::*;
(
    input  logic                 bank0_hit,
    input  logic                 bank0_way,
    input  logic [ 1:0]          bank0_cfi_type,
    input  logic [31:0]          bank0_abtb_pred_target,
    input  logic                 bank0_pred_taken,
    input  logic [31:0]          bank0_final_pred_target,
    input  logic                 bank0_pht_taken,

    input  logic                 bank1_hit,
    input  logic                 bank1_way,
    input  logic [ 1:0]          bank1_cfi_type,
    input  logic [31:0]          bank1_abtb_pred_target,
    input  logic                 bank1_pred_taken,
    input  logic [31:0]          bank1_final_pred_target,
    input  logic                 bank1_pht_taken,

    input  logic                 shadow_pred_taken,
    input  logic                 shadow_pred_bank,
    input  logic [ 1:0]          shadow_pred_cfi_type,
    input  logic [31:0]          shadow_pred_target,
    input  logic [31:0]          shadow_pred_next_pc,

    input  logic                 steer_valid,
    input  logic                 steer_source_abtb,
    input  logic                 steer_branch_owned,
    input  logic                 steer_branch_owned_nt,
    input  logic                 steer_bank,

    output abtb_lookup_bank_t    bank0_lookup,
    output abtb_lookup_bank_t    bank1_lookup,
    output abtb_shadow_result_t  shadow_result,
    output stage1_steer_event_t  steer_event
);

    // 将顶层分散信号打包成结构化观测记录，但不让观测逻辑进入任何控制依赖。
    always_comb begin
        bank0_lookup = '0;
        bank0_lookup.hit = bank0_hit;
        bank0_lookup.way = bank0_way;
        bank0_lookup.cfi_type = bank0_cfi_type;
        bank0_lookup.target = bank0_abtb_pred_target;
        bank0_lookup.pred_taken = bank0_pred_taken;
        bank0_lookup.pred_target = bank0_final_pred_target;
        bank0_lookup.pht_taken = bank0_pht_taken;

        bank1_lookup = '0;
        bank1_lookup.hit = bank1_hit;
        bank1_lookup.way = bank1_way;
        bank1_lookup.cfi_type = bank1_cfi_type;
        bank1_lookup.target = bank1_abtb_pred_target;
        bank1_lookup.pred_taken = bank1_pred_taken;
        bank1_lookup.pred_target = bank1_final_pred_target;
        bank1_lookup.pht_taken = bank1_pht_taken;

        shadow_result = '0;
        shadow_result.pred_taken = shadow_pred_taken;
        shadow_result.pred_bank = shadow_pred_bank;
        shadow_result.pred_cfi_type = shadow_pred_cfi_type;
        shadow_result.pred_target = shadow_pred_target;
        shadow_result.pred_next_pc = shadow_pred_next_pc;

        steer_event = '0;
        steer_event.valid = steer_valid;
        steer_event.source_abtb = steer_source_abtb;
        steer_event.branch_owned = steer_branch_owned;
        steer_event.branch_owned_nt = steer_branch_owned_nt;
        steer_event.bank = steer_bank;
    end

endmodule
