// ============================================================
// 中文说明：保存 slot0 的 MEM/WB 流水状态、最终访存数据和写回信息。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：保存 slot0 的 MEM/WB 握手状态和结构化 payload。
// ============================================================

module mem_wb_reg
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    // 流水线握手信号
    input  logic          mem_valid,
    input  logic          mem_ready_go,
    output logic          wb_allowin,
    output logic          wb_valid,

    // 只有共享 LSU 完成 load 时，load 数据寄存器才更新。
    input  logic          mem_load_valid,
    // 给远端 EX 修复副本使用的物理独立 DCache 最终选择路径。
    input  logic [31:0]   mem_load_data_ex,

    // 需要保存的流水线 payload
    input  mem_wb_slot0_t mem_payload,
    output mem_wb_slot0_t wb_payload,

    // EX 阶段 load 数据修复使用的消费者局部副本。当前发射策略每对
    // 指令最多允许一条 LSU，因此无论生产者来自哪个 slot，两个副本
    // 都保存同一个已完成的 load 结果。
    (* keep = "true" *) output logic [31:0] wb_load_data_ex_s0,
    (* keep = "true" *) output logic [31:0] wb_load_data_ex_s1
);

    wire wb_ready_go = 1'b1;
    assign wb_allowin = !wb_valid || wb_ready_go;

    always_ff @(posedge clk) begin
        if (mem_load_valid && mem_ready_go) begin
            wb_load_data_ex_s0 <= mem_load_data_ex;
            wb_load_data_ex_s1 <= mem_load_data_ex;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            wb_valid <= 1'b0;
        else if (wb_allowin)
            wb_valid <= mem_valid & mem_ready_go;
    end

    always_ff @(posedge clk) begin
        if (wb_allowin) begin
            wb_payload.pc           <= mem_payload.pc;
            wb_payload.inst         <= mem_payload.inst;
            wb_payload.alu_result   <= mem_payload.alu_result;
            wb_payload.pc_plus_4    <= mem_payload.pc_plus_4;
            wb_payload.rd           <= mem_payload.rd;
            wb_payload.reg_write_en <= mem_payload.reg_write_en;
            wb_payload.wb_sel       <= mem_payload.wb_sel;
            wb_payload.is_load      <= mem_payload.is_load;
            wb_payload.is_store     <= mem_payload.is_store;
            wb_payload.mem_size     <= mem_payload.mem_size;
            wb_payload.mem_unsigned <= mem_payload.mem_unsigned;
            wb_payload.mem_addr     <= mem_payload.mem_addr;
            wb_payload.store_data   <= mem_payload.store_data;
            wb_payload.exception    <= mem_payload.exception;
            wb_payload.csr_rstat    <= mem_payload.csr_rstat;
            wb_payload.csr_data     <= mem_payload.csr_data;

            // 非 load 指令保留上一次完成的 load 数据，供 WB 修复路径使用。
            if (mem_load_valid & mem_ready_go)
                wb_payload.load_data <= mem_payload.load_data;
        end
    end

endmodule
