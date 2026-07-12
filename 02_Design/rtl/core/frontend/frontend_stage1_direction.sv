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
    // bank0
    output logic [ 7:0] bank0_index, // bank0_pc[9:2] ^ ghr
    output logic [ 1:0] bank0_counter, // pht[bank0_index]
    output logic        bank0_taken, // bank0_counter[1]
    // bank1
    output logic [ 7:0] bank1_index,
    output logic [ 1:0] bank1_counter,
    output logic        bank1_taken,

    // update metadata
    input  logic        update_valid,
    input  logic [ 7:0] update_index, // 定向PHT
    input  logic [ 1:0] update_counter, // 更新PHT内的2bit counter
    input  logic        update_actual_taken, // counter ++ when set as 1;else --

    output logic [ 7:0] committed_ghr
);

    localparam int PHT_ENTRIES = 256;

    // 哪个傻逼设计的
    // 我们在PHT的预测上，使用了两张一模一样的表来保证两个PC都能进行预测。
    // 但是，真他妈有这种情况吗？两条连续的跳转？哪个傻逼设计的RTL
    (* ram_style = "distributed" *)
    logic [1:0] pht [0:PHT_ENTRIES-1];
    logic [7:0] ghr;

    wire [31:0] block_pc = {predict_pc[31:3], 3'b000};
    wire [31:0] bank0_pc = block_pc;
    wire [31:0] bank1_pc = block_pc + 32'd4;

    assign lookup_ghr = ghr;
    assign committed_ghr = ghr;
    // bank0
    assign bank0_index = bank0_pc[9:2] ^ ghr;
    assign bank0_counter = pht[bank0_index];
    assign bank0_taken = bank0_counter[1];
    // bank1
    assign bank1_index = bank1_pc[9:2] ^ ghr;
    assign bank1_counter = pht[bank1_index];
    assign bank1_taken = bank1_counter[1];

    // counter的update逻辑
    wire [1:0] update_increment =
        (update_counter == 2'b11) ? 2'b11 : update_counter + 2'b01;
    wire [1:0] update_decrement =
        (update_counter == 2'b00) ? 2'b00 : update_counter - 2'b01;
    wire [1:0] update_next_counter =
        update_actual_taken ? update_increment : update_decrement;

    // FPGA 配置将每个计数器初始化为 weakly-not-taken(弱不跳转)。
    // 不要通过 rst_n 对该数组进行批量复位：这样做会将双读端口的PHT 综合成 512 个触发器加上深层读多路选择器，而非 LUTRAM。
    initial begin
        for (int pht_i = 0; pht_i < PHT_ENTRIES; pht_i = pht_i + 1)
            pht[pht_i] = 2'b01;
    end

    // ghr 更新逻辑
    always_ff @(posedge clk) begin
        if (!rst_n)
            ghr <= 8'd0;
        else if (update_valid)
            ghr <= {ghr[6:0], update_actual_taken};
    end

    // pht 更新逻辑
    always @(posedge clk) begin
        if (update_valid)
            pht[update_index] <= update_next_counter;
    end

endmodule
