// ============================================================
// 中文说明：从 ABTB 和顺序取指候选中选择当前取指阶段使用的预测结果。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：frontend_abtb_predict_select。
// 说明：将四个 ABTB way 的命中结果转换成一个按程序顺序排列的预测结果。
// 所属部分：前端分支预测。
//
// ABTB 表负责存储、tag 匹配、分配和训练；本组合模块只负责解释 CFI 类型，
// 并选择最早发生的跳转。明确这个边界可以让递归 next-PC 规则更容易阅读，
// 同时保持候选项并行计算结构不变。
// ============================================================

module frontend_abtb_predict_select (
    input  logic        lookup_valid,
    input  logic [31:0] predict_pc,

    input  logic        bank0_way0_match,
    input  logic        bank0_way1_match,
    input  logic [ 1:0] bank0_way0_type,
    input  logic [ 1:0] bank0_way1_type,
    input  logic [31:0] bank0_way0_target,
    input  logic [31:0] bank0_way1_target,
    input  logic        bank0_branch_taken,
    input  logic        bank0_ret_valid,
    input  logic [31:0] bank0_ret_target,

    input  logic        bank1_way0_match,
    input  logic        bank1_way1_match,
    input  logic [ 1:0] bank1_way0_type,
    input  logic [ 1:0] bank1_way1_type,
    input  logic [31:0] bank1_way0_target,
    input  logic [31:0] bank1_way1_target,
    input  logic        bank1_branch_taken,
    input  logic        bank1_ret_valid,
    input  logic [31:0] bank1_ret_target,

    output logic        bank0_eligible,
    output logic        bank0_lookup_hit,
    output logic        bank0_hit,
    output logic        bank0_way,
    output logic [ 1:0] bank0_cfi_type,
    output logic [31:0] bank0_abtb_pred_target,
    output logic        bank0_pred_taken,
    output logic [31:0] bank0_final_pred_target,

    output logic        bank1_eligible,
    output logic        bank1_lookup_hit,
    output logic        bank1_hit,
    output logic        bank1_way,
    output logic [ 1:0] bank1_cfi_type,
    output logic [31:0] bank1_abtb_pred_target,
    output logic        bank1_pred_taken,
    output logic [31:0] bank1_final_pred_target,

    output logic        pred_taken,
    output logic        pred_bank,
    output logic [ 1:0] pred_cfi_type,
    output logic [31:0] pred_target,
    output logic [31:0] pred_next_pc,
    output logic [31:0] pred_next_pc_early
);

    localparam logic [1:0] CFI_JAL    = 2'b00;
    localparam logic [1:0] CFI_CALL   = 2'b01;
    localparam logic [1:0] CFI_BRANCH = 2'b10;
    localparam logic [1:0] CFI_RET    = 2'b11;

    function automatic logic cfi_taken_candidate(
        input logic [1:0] cfi_type,
        input logic       branch_taken,
        input logic       ret_valid
    );
        cfi_taken_candidate = (cfi_type == CFI_JAL)
                            | (cfi_type == CFI_CALL)
                            | ((cfi_type == CFI_BRANCH) & branch_taken)
                            | ((cfi_type == CFI_RET) & ret_valid);
    endfunction

    function automatic logic [31:0] cfi_target_candidate(
        input logic [ 1:0] cfi_type,
        input logic [31:0] stored_target,
        input logic [31:0] ret_target
    );
        cfi_target_candidate = (cfi_type == CFI_RET)
                             ? ret_target : stored_target;
    endfunction

    function automatic logic [31:0] select_next_pc(
        input logic [ 1:0] select,
        input logic [31:0] bank0_target,
        input logic [31:0] bank1_target,
        input logic [31:0] sequential_pc
    );
        case (select)
            2'b10:   select_next_pc = bank0_target;
            2'b01:   select_next_pc = bank1_target;
            default: select_next_pc = sequential_pc;
        endcase
    endfunction

    wire bank0_way1_selected = ~bank0_way0_match & bank0_way1_match;
    wire bank1_way1_selected = ~bank1_way0_match & bank1_way1_match;
    wire bank0_any_match = bank0_way0_match | bank0_way1_match;
    wire bank1_any_match = bank1_way0_match | bank1_way1_match;

    wire bank0_way0_taken = cfi_taken_candidate(
        bank0_way0_type, bank0_branch_taken, bank0_ret_valid
    );
    wire bank0_way1_taken = cfi_taken_candidate(
        bank0_way1_type, bank0_branch_taken, bank0_ret_valid
    );
    wire bank1_way0_taken = cfi_taken_candidate(
        bank1_way0_type, bank1_branch_taken, bank1_ret_valid
    );
    wire bank1_way1_taken = cfi_taken_candidate(
        bank1_way1_type, bank1_branch_taken, bank1_ret_valid
    );

    wire [31:0] bank0_way0_final_target = cfi_target_candidate(
        bank0_way0_type, bank0_way0_target, bank0_ret_target
    );
    wire [31:0] bank0_way1_final_target = cfi_target_candidate(
        bank0_way1_type, bank0_way1_target, bank0_ret_target
    );
    wire [31:0] bank1_way0_final_target = cfi_target_candidate(
        bank1_way0_type, bank1_way0_target, bank1_ret_target
    );
    wire [31:0] bank1_way1_final_target = cfi_target_candidate(
        bank1_way1_type, bank1_way1_target, bank1_ret_target
    );

    wire bank0_selected_taken = (bank0_way0_match & bank0_way0_taken)
                               | (bank0_way1_selected & bank0_way1_taken);
    wire bank1_selected_taken = (bank1_way0_match & bank1_way0_taken)
                               | (bank1_way1_selected & bank1_way1_taken);
    wire [31:0] bank0_selected_final_target = bank0_way0_match
        ? bank0_way0_final_target : bank0_way1_final_target;
    wire [31:0] bank1_selected_final_target = bank1_way0_match
        ? bank1_way0_final_target : bank1_way1_final_target;
    wire [31:0] sequential_next_pc =
        predict_pc + (predict_pc[2] ? 32'd4 : 32'd8);

    always_comb begin
        bank0_eligible = lookup_valid & ~predict_pc[2];
        bank0_lookup_hit = ~predict_pc[2] & bank0_any_match;
        bank0_hit = lookup_valid & bank0_lookup_hit;
        bank0_way = bank0_way1_selected;
        bank0_cfi_type = bank0_way0_match ? bank0_way0_type
                       : bank0_way1_selected ? bank0_way1_type
                                            : 2'd0;
        bank0_abtb_pred_target = bank0_way0_match ? bank0_way0_target
                               : bank0_way1_selected ? bank0_way1_target
                                                    : 32'd0;
        bank0_pred_taken = bank0_eligible & bank0_selected_taken;
        bank0_final_pred_target = bank0_hit
            ? bank0_selected_final_target : bank0_abtb_pred_target;

        bank1_eligible = lookup_valid;
        bank1_lookup_hit = bank1_any_match;
        bank1_hit = lookup_valid & bank1_lookup_hit;
        bank1_way = bank1_way1_selected;
        bank1_cfi_type = bank1_way0_match ? bank1_way0_type
                       : bank1_way1_selected ? bank1_way1_type
                                            : 2'd0;
        bank1_abtb_pred_target = bank1_way0_match ? bank1_way0_target
                               : bank1_way1_selected ? bank1_way1_target
                                                    : 32'd0;
        bank1_pred_taken = bank1_eligible & bank1_selected_taken;
        bank1_final_pred_target = bank1_hit
            ? bank1_selected_final_target : bank1_abtb_pred_target;
    end

    // bank0 在程序顺序上更早，两个 bank 都预测跳转时由 bank0 优先。
    // 这里有意不加入 lookup_valid 条件；取指状态只在查询被接受时采样结果。
    wire bank0_selected = bank0_pred_taken;
    wire bank1_selected = bank1_pred_taken & ~bank0_pred_taken;
    wire [1:0] qualified_select = {bank0_selected, bank1_selected};
    wire bank0_selected_early = ~predict_pc[2] & bank0_selected_taken;
    wire bank1_selected_early = bank1_selected_taken
                              & ~bank0_selected_early;
    wire [1:0] early_select = {
        bank0_selected_early, bank1_selected_early
    };

    assign pred_taken = |qualified_select;
    assign pred_bank = bank1_selected;
    assign pred_cfi_type = bank0_selected ? bank0_cfi_type
                         : bank1_selected ? bank1_cfi_type
                                          : 2'd0;
    assign pred_target = select_next_pc(
        qualified_select,
        bank0_selected_final_target,
        bank1_selected_final_target,
        32'd0
    );
    assign pred_next_pc = select_next_pc(
        qualified_select,
        bank0_selected_final_target,
        bank1_selected_final_target,
        sequential_next_pc
    );
    assign pred_next_pc_early = select_next_pc(
        early_select,
        bank0_selected_final_target,
        bank1_selected_final_target,
        sequential_next_pc
    );

endmodule
