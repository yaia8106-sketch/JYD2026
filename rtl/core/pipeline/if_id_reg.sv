// ============================================================
// 中文说明：保存 IF/ID 阶段的取指结果和两个 slot 的有效状态。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：保存 IF/ID 握手状态和结构化 payload。
// ============================================================

module if_id_reg
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // 流水线握手信号
    input  logic        if_valid,
    input  logic        if_ready_go,
    input  logic        id_allowin,
    output logic        id_valid,

    // 冲刷信号
    input  logic        id_flush,

    // slot1 的有效位必须单独保存，因为一对指令共享同一个握手。
    input  logic           if_s1_valid,
    output logic           id_s1_valid,

    // 需要保存的流水线 payload
    input  if_id_payload_t if_payload,
    output if_id_payload_t id_payload,

    // 给四个高扇出寄存器堆读地址准备的物理独立副本。相关性和 ready
    // 逻辑继续使用 id_payload 的原始副本，避免 32x32 读选择器把反向
    // 控制簇拉向寄存器堆。
    output logic [4:0]     id_s0_rf_rs1_addr,
    output logic [4:0]     id_s0_rf_rs2_addr,
    output logic [4:0]     id_s1_rf_rs1_addr,
    output logic [4:0]     id_s1_rf_rs2_addr
);

    (* keep = "true" *) logic [4:0] id_s0_rf_rs1_addr_q;
    (* keep = "true" *) logic [4:0] id_s0_rf_rs2_addr_q;
    (* keep = "true" *) logic [4:0] id_s1_rf_rs1_addr_q;
    (* keep = "true" *) logic [4:0] id_s1_rf_rs2_addr_q;

    assign id_s0_rf_rs1_addr = id_s0_rf_rs1_addr_q;
    assign id_s0_rf_rs2_addr = id_s0_rf_rs2_addr_q;
    assign id_s1_rf_rs1_addr = id_s1_rf_rs1_addr_q;
    assign id_s1_rf_rs2_addr = id_s1_rf_rs2_addr_q;

    // valid 位负责复位和冲刷语义。两个 slot 都无效时 payload 会被忽略，
    // 因此复位和晚到的重定向都不需要连接到宽数据寄存器。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            id_valid    <= 1'b0;
            id_s1_valid <= 1'b0;
        end else if (id_flush) begin
            id_valid    <= 1'b0;
            id_s1_valid <= 1'b0;
        end else if (id_allowin) begin
            id_valid    <= if_valid & if_ready_go;
            id_s1_valid <= if_valid & if_ready_go & if_s1_valid;
        end
    end

    // id_allowin 只作为 payload 存储的时钟使能。同周期冲刷可能写入
    // 投机数据，但上面的 valid 逻辑会让这些数据不可见。
    always_ff @(posedge clk) begin
        if (id_allowin) begin
            id_payload <= if_payload;
            id_s0_rf_rs1_addr_q <=
                if_payload.slot0.issue_hint.src0_addr;
            id_s0_rf_rs2_addr_q <=
                if_payload.slot0.issue_hint.src1_addr;
            id_s1_rf_rs1_addr_q <=
                if_payload.slot1.issue_hint.src0_addr;
            id_s1_rf_rs2_addr_q <=
                if_payload.slot1.issue_hint.src1_addr;
        end
    end

endmodule
