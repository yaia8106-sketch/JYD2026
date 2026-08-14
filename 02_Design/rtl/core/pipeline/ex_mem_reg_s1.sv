// ============================================================
// 中文说明：保存 slot1 的 EX/MEM 流水状态，并处理年轻指令受到的冲刷。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：保存 slot1 的 EX/MEM 结构化 payload。
// ============================================================

module ex_mem_reg_s1
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    input  logic          ex_s1_valid,
    input  logic          ex_ready_go,
    input  logic          mem_allowin,
    input  logic          ex_branch_flush,
    input  logic          mem_branch_flush,

    input  ex_mem_slot1_t ex_payload,
    output logic          mem_s1_valid,
    (* extract_enable = "yes", extract_reset = "no" *)
    output ex_mem_slot1_t mem_payload,

    // 给反向 ID 相关性路径使用的物理独立窄副本。把这些字段从普通
    // MEM payload 中分离出来，能让它们靠近前递比较器，而不会移动
    // LSU/提交路径使用的同一份元数据。
    (* keep = "true" *)
    output logic          mem_s1_hazard_valid,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic          mem_s1_hazard_is_load,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic [4:0]    mem_s1_hazard_rd
);

    // slot1 比 slot0 更新，因此同周期 EX 缺失或更老指令的已寄存 MEM
    // 重定向都会使它失效。
    wire s1_flush = ex_branch_flush | mem_branch_flush;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_s1_valid <= 1'b0;
            mem_s1_hazard_valid <= 1'b0;
        end else if (mem_allowin) begin
            mem_s1_valid <= ex_s1_valid & ex_ready_go & ~s1_flush;
            mem_s1_hazard_valid <= ex_s1_valid & ex_ready_go & ~s1_flush;
        end
    end

    always_ff @(posedge clk) begin
        if (mem_allowin) begin
            mem_payload <= ex_payload;
            mem_s1_hazard_is_load <= ex_payload.mem_read_en;
            mem_s1_hazard_rd <= ex_payload.rd;
        end
    end

`ifndef SYNTHESIS
    // 这个副本只服务于物理实现。持续检查它和架构 EX/MEM payload 的
    // 周期约定完全一致。
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (mem_s1_hazard_valid !== mem_s1_valid)
                $fatal(1, "Slot 1 hazard-valid mirror diverged from EX/MEM valid");
            if (mem_s1_valid
                && ((mem_s1_hazard_is_load !== mem_payload.mem_read_en)
                    || (mem_s1_hazard_rd !== mem_payload.rd)))
                $fatal(1, "Slot 1 hazard metadata mirror diverged from EX/MEM payload");
        end
    end
`endif

endmodule
