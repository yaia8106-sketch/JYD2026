// ============================================================
// 中文说明：维护并查询一级方向预测器的历史状态，输出条件分支的 taken 或 not-taken 预测。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：frontend_stage1_direction。
// 说明：非投机的一级分支方向预测器。
// 所属阶段：frontend。
//   - 8 位已提交 GHR；
//   - 256 项、每项 2 位的饱和计数器 PHT；
//   - 为一个 64 位取指块提供两个并行组合查询端口；
//   - 每周期最多更新一条已经确认的条件分支。
// 更新索引和计数器是预测时产生、随流水线携带到 EX 的元数据；这里有意不做
// 写后读旁路，也不做重定向恢复。
// ============================================================

module frontend_stage1_direction (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] predict_pc,
    output logic [ 7:0] lookup_ghr,
    // bank0 预测元数据。
    output logic [ 7:0] bank0_index, // bank0_pc[9:2] ^ ghr
    output logic [ 1:0] bank0_counter, // pht[bank0_index] 的计数器
    output logic        bank0_taken, // bank0_counter[1]，1 表示跳转
    // bank1 预测元数据。
    output logic [ 7:0] bank1_index,
    output logic [ 1:0] bank1_counter,
    output logic        bank1_taken,

    // 更新事件已经由 EX 接收、老指令优先、架构有效和错误路径抑制条件筛选。
    input  logic        update_valid,
    input  logic [ 7:0] update_index, // 定向PHT
    input  logic [ 1:0] update_counter, // 更新PHT内的2bit counter
    input  logic        update_actual_taken, // 为 1 时计数器加一，否则减一

    output logic [ 7:0] committed_ghr
);

    localparam int PHT_ENTRIES = 256;

    // 逻辑上只保留一张 256 项 PHT。Vivado 可以为了提供两个异步查询口而
    // 复制分布式 RAM，但两个查询口共享同一个写入源，表示的是同一份预测状态。
    (* ram_style = "distributed" *)
    logic [1:0] pht [0:PHT_ENTRIES-1];
    logic [7:0] ghr;

    wire [31:0] block_pc = {predict_pc[31:3], 3'b000};
    wire [31:0] bank0_pc = block_pc;
    wire [31:0] bank1_pc = block_pc + 32'd4;

    assign lookup_ghr = ghr;
    assign committed_ghr = ghr;
    // 两个查询端口使用已提交 GHR，以及同一取指块中的两个 PC。
    assign bank0_index = bank0_pc[9:2] ^ ghr;
    assign bank1_index = bank1_pc[9:2] ^ ghr;
    // bank0/bank1 通过独立查询端口读取同一张逻辑 PHT。
    assign bank0_counter = pht[bank0_index];
    assign bank1_counter = pht[bank1_index];
    assign bank0_taken = bank0_counter[1];
    assign bank1_taken = bank1_counter[1];

    // 两位饱和计数器更新。
    wire [1:0] update_increment =
        (update_counter == 2'b11) ? 2'b11 : update_counter + 2'b01;
    wire [1:0] update_decrement =
        (update_counter == 2'b00) ? 2'b00 : update_counter - 2'b01;
    wire [1:0] update_next_counter =
        update_actual_taken ? update_increment : update_decrement;

    // FPGA 配置会把每个计数器初始化为弱不跳转。
    // 不要通过 rst_n 批量复位 PHT，否则双读口 LUTRAM 会退化为触发器和深层读 MUX。
    initial begin
        for (int pht_i = 0; pht_i < PHT_ENTRIES; pht_i = pht_i + 1)
            pht[pht_i] = 2'b01;
    end

    // 已提交 GHR 更新。
    always_ff @(posedge clk) begin
        if (!rst_n)
            ghr <= 8'd0;
        else if (update_valid)
            ghr <= {ghr[6:0], update_actual_taken};
    end

    // PHT 状态更新。
    always @(posedge clk) begin
        if (update_valid)
            pht[update_index] <= update_next_counter;
    end

endmodule
