// ============================================================
// Module: frontend_stage1_direction
// Description: Non-speculative Stage-1 branch direction predictor.
// Domain: frontend.
//   - 8-bit committed GHR
//   - 256-entry, 2-bit saturating-counter PHT
//   - two parallel combinational lookup ports for one 64-bit block
//   - one confirmed conditional-branch update per cycle
//
// The update index and counter are prediction-time metadata carried to EX.
// There is intentionally no write-to-read bypass or redirect recovery.
// ============================================================

module frontend_stage1_direction (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] predict_pc,
    output logic [ 7:0] lookup_ghr,
    // Bank 0 prediction metadata / bank0 预测元数据
    output logic [ 7:0] bank0_index, // bank0_pc[9:2] ^ ghr
    output logic [ 1:0] bank0_counter, // pht[bank0_index]
    output logic        bank0_taken, // bank0_counter[1]
    // Bank 1 prediction metadata / bank1 预测元数据
    output logic [ 7:0] bank1_index,
    output logic [ 1:0] bank1_counter,
    output logic        bank1_taken,

    // The update event is already qualified by EX fire, older-slot priority,
    // architectural validity and wrong-path suppression.
    // 更新事件已包含 EX 接收、老指令优先、架构有效和错误路径抑制条件。
    input  logic        update_valid,
    input  logic [ 7:0] update_index, // 定向PHT
    input  logic [ 1:0] update_counter, // 更新PHT内的2bit counter
    input  logic        update_actual_taken, // counter ++ when set as 1;else --

    output logic [ 7:0] committed_ghr
);

    localparam int PHT_ENTRIES = 256;

    // Keep one logical 256-entry table. Vivado may replicate this distributed
    // RAM to provide two asynchronous lookups, but both ports share one write
    // source and therefore represent the same predictor state.
    // 逻辑上只有一张 PHT；综合器可为双异步读口复制存储体，但两份共享写口。
    (* ram_style = "distributed" *)
    logic [1:0] pht [0:PHT_ENTRIES-1];
    logic [7:0] ghr;

    wire [31:0] block_pc = {predict_pc[31:3], 3'b000};
    wire [31:0] bank0_pc = block_pc;
    wire [31:0] bank1_pc = block_pc + 32'd4;

    assign lookup_ghr = ghr;
    assign committed_ghr = ghr;
    // Both lookup ports use the committed GHR and the two PCs in one fetch block.
    assign bank0_index = bank0_pc[9:2] ^ ghr;
    assign bank1_index = bank1_pc[9:2] ^ ghr;
    // Bank 0/1 read the same logical PHT through independent lookup ports.
    assign bank0_counter = pht[bank0_index];
    assign bank1_counter = pht[bank1_index];
    assign bank0_taken = bank0_counter[1];
    assign bank1_taken = bank1_counter[1];

    // Two-bit saturating-counter update / 2-bit 饱和计数器更新。
    wire [1:0] update_increment =
        (update_counter == 2'b11) ? 2'b11 : update_counter + 2'b01;
    wire [1:0] update_decrement =
        (update_counter == 2'b00) ? 2'b00 : update_counter - 2'b01;
    wire [1:0] update_next_counter =
        update_actual_taken ? update_increment : update_decrement;

    // FPGA configuration initializes every counter to weakly not-taken.
    // 不要通过 rst_n 批量复位 PHT，否则双读口 LUTRAM 会退化为触发器和深层读 mux。
    initial begin
        for (int pht_i = 0; pht_i < PHT_ENTRIES; pht_i = pht_i + 1)
            pht[pht_i] = 2'b01;
    end

    // Committed GHR update / committed GHR 更新。
    always_ff @(posedge clk) begin
        if (!rst_n)
            ghr <= 8'd0;
        else if (update_valid)
            ghr <= {ghr[6:0], update_actual_taken};
    end

    // PHT state update / PHT 状态更新。
    always @(posedge clk) begin
        if (update_valid)
            pht[update_index] <= update_next_counter;
    end

endmodule
