`ifndef SYNTHESIS
// 中文说明：在仿真中检查控制流重定向的来源、目标和生效时机是否一致。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// ============================================================
// 模块：redirect_consistency_monitor。
// 说明：仅在仿真中参考并检查 EX 到 MEM 的重定向边界。
// 所属部分：observe。
// ============================================================

module redirect_consistency_monitor
    import cpu_defs::*;
(
    input logic             clk,
    input logic             rst_n,
    input logic             ex_redirect_valid,
    input redirect_source_t ex_redirect_source,
    input logic             ex_redirect_actual_taken,
    input logic             ex_priv_flow,
    input logic [31:0]      ex_priv_target,
    input logic             ex_slot0_branch_flush,
    input logic             ex_slot0_actual_taken,
    input logic [31:0]      ex_slot0_control_target,
    input logic [31:0]      ex_slot0_pc_plus_4,
    input logic             ex_slot0_valid,
    input logic             ex_slot1_valid,
    input logic             ex_slot1_addr_replay,
    input logic [31:0]      ex_slot1_pc,
    input logic             ex_slot1_actual_taken,
    input logic [31:0]      ex_slot1_control_target,
    input logic [31:0]      ex_slot1_pc_plus_4,
    input logic [31:0]      ex_slot0_mem_alu_candidate,
    input logic [1:0]       ex_slot0_target_clear_mask,
    input logic [31:0]      ex_slot1_mem_alu_candidate,
    input logic [1:0]       ex_slot1_target_clear_mask,
    input redirect_t        mem_redirect,
    input logic [31:0]      mem_redirect_target
);

    wire [31:0] ex_redirect_target_reference =
        ex_priv_flow ? ex_priv_target :
        (ex_slot0_branch_flush & ~ex_priv_flow)
            ? (ex_slot0_actual_taken
               ? ex_slot0_control_target : ex_slot0_pc_plus_4) :
        (ex_slot0_valid & ex_slot1_valid & ex_slot1_addr_replay)
            ? ex_slot1_pc :
        ex_slot1_actual_taken
            ? ex_slot1_control_target : ex_slot1_pc_plus_4;

    logic        redirect_reference_valid_q;
    logic [31:0] redirect_reference_target_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            redirect_reference_valid_q <= 1'b0;
        end else begin
            if (mem_redirect.valid !== redirect_reference_valid_q)
                $fatal(1, "Registered redirect valid changed latency");
            if (redirect_reference_valid_q
                && (mem_redirect_target !== redirect_reference_target_q))
                $fatal(1, "MEM redirect target differs from EX reference");

            redirect_reference_valid_q <= ex_redirect_valid;
            if (ex_redirect_valid)
                redirect_reference_target_q <= ex_redirect_target_reference;

            if (ex_redirect_valid
                && (ex_redirect_source == REDIRECT_S0_CONTROL)
                && ex_redirect_actual_taken
                && ((ex_slot0_mem_alu_candidate
                     & ~{30'd0, ex_slot0_target_clear_mask})
                    !== ex_slot0_control_target))
                $fatal(1, "Slot0 EX/MEM ALU candidate differs from CFI target");
            if (ex_redirect_valid
                && (ex_redirect_source == REDIRECT_S1_CONTROL)
                && ex_redirect_actual_taken
                && ((ex_slot1_mem_alu_candidate
                     & ~{30'd0, ex_slot1_target_clear_mask})
                    !== ex_slot1_control_target))
                $fatal(1, "Slot1 EX/MEM ALU candidate differs from CFI target");
        end
    end

endmodule
`endif
