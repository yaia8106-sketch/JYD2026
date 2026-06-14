// ============================================================
// Module: frontend_stage1_direction
// Description: Non-speculative Stage-1 branch direction predictor.
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
    output logic [ 7:0] bank0_index,
    output logic [ 1:0] bank0_counter,
    output logic        bank0_taken,
    output logic [ 7:0] bank1_index,
    output logic [ 1:0] bank1_counter,
    output logic        bank1_taken,

    // update_valid must already include EX fire, architectural validity,
    // older-slot priority, and wrong-path suppression.
    input  logic        update_valid,
    input  logic [ 7:0] update_index,
    input  logic [ 1:0] update_counter,
    input  logic        update_actual_taken,

    output logic [ 7:0] committed_ghr
);

    localparam int PHT_ENTRIES = 256;

    // Keep one logical 256-entry table. Vivado may replicate the distributed
    // RAM to implement the two asynchronous read ports, but both replicas
    // share this single write source and therefore represent the same state.
    (* ram_style = "distributed" *)
    logic [1:0] pht [0:PHT_ENTRIES-1];
    logic [7:0] ghr;

    wire [31:0] block_pc = {predict_pc[31:3], 3'b000};
    wire [31:0] bank0_pc = block_pc;
    wire [31:0] bank1_pc = block_pc + 32'd4;

    assign lookup_ghr = ghr;
    assign committed_ghr = ghr;
    assign bank0_index = bank0_pc[9:2] ^ ghr;
    assign bank1_index = bank1_pc[9:2] ^ ghr;
    assign bank0_counter = pht[bank0_index];
    assign bank1_counter = pht[bank1_index];
    assign bank0_taken = bank0_counter[1];
    assign bank1_taken = bank1_counter[1];

    wire [1:0] update_increment =
        (update_counter == 2'b11) ? 2'b11 : update_counter + 2'b01;
    wire [1:0] update_decrement =
        (update_counter == 2'b00) ? 2'b00 : update_counter - 2'b01;
    wire [1:0] update_next_counter =
        update_actual_taken ? update_increment : update_decrement;

    // FPGA configuration initializes every counter to weakly-not-taken.
    // Do not bulk-reset this array through rst_n: doing so turns the two-read
    // PHT into 512 flip-flops plus deep read muxes instead of LUTRAM.
    initial begin
        for (int pht_i = 0; pht_i < PHT_ENTRIES; pht_i = pht_i + 1)
            pht[pht_i] = 2'b01;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ghr <= 8'd0;
        else if (update_valid)
            ghr <= {ghr[6:0], update_actual_taken};
    end

    always @(posedge clk) begin
        if (update_valid)
            pht[update_index] <= update_next_counter;
    end

endmodule
