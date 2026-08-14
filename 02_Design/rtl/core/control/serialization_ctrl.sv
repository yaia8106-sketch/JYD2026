// ============================================================
// 中文说明：识别需要串行执行的指令，并阻止更年轻的指令越过它们。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：serialization_ctrl。
// 说明：跟踪当前占用后端的唯一串行化指令；该位有效时，译码会阻止第二条
// 指令进入后端。
// ============================================================

module serialization_ctrl (
    input  logic clk,
    input  logic rst_n,
    input  logic id_issue_fire,
    input  logic id_issue_serializing,
    input  logic wb_slot0_valid,
    output logic serializing_inflight
);

    always_ff @(posedge clk) begin
        if (!rst_n)
            serializing_inflight <= 1'b0;
        else if (wb_slot0_valid)
            serializing_inflight <= 1'b0;
        else if (id_issue_fire && id_issue_serializing)
            serializing_inflight <= 1'b1;
    end

endmodule
