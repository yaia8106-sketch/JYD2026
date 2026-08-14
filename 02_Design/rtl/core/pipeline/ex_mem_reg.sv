// ============================================================
// 中文说明：保存 slot0 的 EX/MEM 流水状态、执行结果、访存信息和重定向信息。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：保存 slot0 的 EX/MEM 握手状态、payload 和重定向信息。
// ============================================================

module ex_mem_reg
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    // 流水线握手信号
    input  logic          ex_valid,
    input  logic          ex_ready_go,
    output logic          mem_allowin,
    output logic          mem_valid,
    input  logic          mem_ready_go,
    input  logic          wb_allowin,

    // 重定向信息独立于被 MEM 反压的 payload 寄存。
    input  redirect_t     ex_redirect,
    output redirect_t     mem_redirect,

    // 需要保存的流水线 payload
    input  ex_mem_slot0_t ex_payload,
    (* extract_enable = "yes", extract_reset = "no" *)
    output ex_mem_slot0_t mem_payload,

    // 给反向前递/相关性网络使用的物理独立窄字段副本。架构 payload
    // 仍然是唯一的数据来源；这些字段只是避免远端 rd 和控制位把完整
    // EX/MEM 存储簇拉到译码阶段。
    (* keep = "true" *)
    output logic          mem_hazard_valid,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic          mem_hazard_reg_write,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic          mem_hazard_is_load,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic          mem_hazard_is_mul,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic [4:0]    mem_hazard_rd,
    // 源寄存器地址副本把四个 ID 操作数比较路径分成两个布局/扇出簇。
    // 它们不包含架构状态，下面的检查会持续验证它们和标准副本一致。
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic [4:0]    mem_fwd_s0_rd,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic [4:0]    mem_fwd_s1_rd,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output wb_src_t       mem_hazard_wb_sel
);

    // 标准 valid/allow 规则：MEM 为空，或当前 payload 能前进到 WB 时，
    // MEM 才能接受新的 payload。
    assign mem_allowin = !mem_valid || (mem_ready_go & wb_allowin);

    // 已寄存的重定向只有在 MEM 可以前进时才会清除年轻的 EX 指令。
    // 缺失请求被停住时必须保持有效，直到访存完成。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_valid <= 1'b0;
            mem_hazard_valid <= 1'b0;
        end else if (mem_allowin) begin
            mem_valid <= ex_valid & ex_ready_go & ~mem_redirect.valid;
            mem_hazard_valid <= ex_valid & ex_ready_go
                              & ~mem_redirect.valid;
        end
    end

    // payload 没有独立生命周期，mem_valid 是它唯一的所有权标志。
    always_ff @(posedge clk) begin
        if (mem_allowin) begin
            mem_payload <= ex_payload;
            mem_hazard_reg_write <= ex_payload.reg_write_en;
            mem_hazard_is_load <= ex_payload.mem_read_en;
            mem_hazard_is_mul <= ex_payload.is_mul;
            mem_hazard_rd <= ex_payload.rd;
            mem_fwd_s0_rd <= ex_payload.rd;
            mem_fwd_s1_rd <= ex_payload.rd;
            mem_hazard_wb_sel <= ex_payload.wb_sel;
        end
    end

    // 重定向传播不能被 MEM 反压阻塞；即使 load 正在等待，前端重放也
    // 必须能看到控制流恢复请求。
    always_ff @(posedge clk) begin
        if (!rst_n)
            mem_redirect.valid <= 1'b0;
        else
            mem_redirect.valid <= ex_redirect.valid;
    end

    // redirect.valid 为 0 时，来源和方向对架构没有意义。把它们排除在
    // 复位之外，可以避免复位网进入宽 payload 触发器，这个边界只需复位
    // 三个窄控制位。
    always_ff @(posedge clk) begin
        mem_redirect.source <= ex_redirect.source;
        mem_redirect.actual_taken <= ex_redirect.actual_taken;
    end

`ifndef SYNTHESIS
    // 窄副本只用于帮助布局布线。持续检查它是否和 EX/MEM 遵守完全相同
    // 的接受、保持和冲刷周期约定。
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (mem_hazard_valid !== mem_valid)
                $fatal(1, "Slot 0 MEM hazard-valid mirror diverged from EX/MEM valid");
            if (mem_valid
                && ((mem_hazard_reg_write !== mem_payload.reg_write_en)
                    || (mem_hazard_is_load !== mem_payload.mem_read_en)
                    || (mem_hazard_is_mul !== mem_payload.is_mul)
                    || (mem_hazard_rd !== mem_payload.rd)
                    || (mem_fwd_s0_rd !== mem_payload.rd)
                    || (mem_fwd_s1_rd !== mem_payload.rd)
                    || (mem_hazard_wb_sel !== mem_payload.wb_sel)))
                $fatal(1, "Slot 0 MEM hazard metadata mirror diverged from EX/MEM payload");
        end
    end
`endif

endmodule
