// ============================================================
// Module: branch_predictor
// Description: Front-end Predictor Center (BTB + BHT + RAS)
// Phase 2+: IF-stage prediction, EX-stage training
// Spec: 02_Design/spec/front_end_predictor_spec.md
// ============================================================

module branch_predictor (
    input  logic        clk,
    input  logic        rst_n,

    // --------------------------------------------------------
    // IF Stage (Query - Combinational, must be < 1ns)
    // --------------------------------------------------------
    input  logic [31:0] if_pc,           // 当前正在取指的 PC
    input  logic        if_allowin,      // IF stage 可流动（非阻塞时为 1）
    output logic        pred_taken,      // 预测是否跳转
    output logic [31:0] pred_target,     // 预测的目标地址

    // --------------------------------------------------------
    // ID Stage (RAS Management)
    // --------------------------------------------------------
    input  logic [31:0] id_pc,           // 用于计算返回地址 (PC+4)
    input  logic        id_is_call,      // 译码发现是 CALL
    input  logic        id_is_ret,       // 译码发现是 RET

    // --------------------------------------------------------
    // EX Stage (Update / Training - Sequential)
    // --------------------------------------------------------
    input  logic        update_en,       // 训练使能
    input  logic [31:0] ex_pc,           // 指令的原始 PC
    input  logic [31:0] ex_actual_target, // 实际跳转目标
    input  logic        ex_actual_taken,  // 实际是否跳转
    input  logic [ 1:0] ex_inst_type,     // 0:JAL, 1:B-type, 2:RET/JALR
    
    // EX Stage (Flush status)
    input  logic        ex_mispredict    // EX 级上报预测失败
);

    // ================================================================
    //  Parameters
    // ================================================================
    localparam BTB_DEPTH     = 32;
    localparam BTB_IDX_WIDTH = 5;        // log2(32)
    localparam BTB_TAG_WIDTH = 7;        // PC[13:7]

    localparam BHT_DEPTH     = 64;       // 64 entries, no tag needed
    localparam BHT_IDX_WIDTH = 6;        // log2(64)

    localparam RAS_DEPTH     = 4;
    localparam RAS_PTR_WIDTH = 2;        // log2(4)

    // BTB instruction types
    localparam [1:0] BP_JAL  = 2'd0;
    localparam [1:0] BP_BR   = 2'd1;
    localparam [1:0] BP_RET  = 2'd2;

    // ================================================================
    //  BTB Storage (LUTRAM / Register Array)
    // ================================================================
    logic                    btb_valid  [BTB_DEPTH-1:0];
    logic [BTB_TAG_WIDTH-1:0] btb_tag   [BTB_DEPTH-1:0];
    logic [1:0]              btb_type   [BTB_DEPTH-1:0];
    logic [31:0]             btb_target [BTB_DEPTH-1:0];

    // ================================================================
    //  BHT Storage (2-bit saturating counters, no tag)
    // ================================================================
    logic [1:0]              bht_counter [BHT_DEPTH-1:0];

    // ================================================================
    //  RAS Storage (4-entry circular LIFO)
    // ================================================================
    logic [31:0]             ras_stack  [RAS_DEPTH-1:0];
    logic [RAS_PTR_WIDTH-1:0] ras_top;

    // ================================================================
    //  IF Stage: Combinational Lookup (0-cycle)
    //  BTB and BHT lookups happen IN PARALLEL
    // ================================================================

    // --- BTB lookup ---
    wire [BTB_IDX_WIDTH-1:0] if_idx = if_pc[BTB_IDX_WIDTH+1 : 2];   // PC[6:2]
    wire [BTB_TAG_WIDTH-1:0] if_tag = if_pc[BTB_TAG_WIDTH+BTB_IDX_WIDTH+1 : BTB_IDX_WIDTH+2]; // PC[13:7]

    wire btb_hit       = btb_valid[if_idx] && (btb_tag[if_idx] == if_tag);
    wire [1:0] btb_hit_type = btb_type[if_idx];

    // --- BHT lookup (parallel with BTB) ---
    wire [BHT_IDX_WIDTH-1:0] if_bht_idx = if_pc[BHT_IDX_WIDTH+1 : 2]; // PC[7:2]
    wire bht_direction = bht_counter[if_bht_idx][1];  // MSB of 2-bit counter: 1=taken

    // --- Per-type prediction (only 1 extra AND gate on critical path) ---
    wire btb_pred_jal = btb_hit && (btb_hit_type == BP_JAL);
    wire btb_pred_br  = btb_hit && (btb_hit_type == BP_BR) && bht_direction;
    wire btb_pred_ret = btb_hit && (btb_hit_type == BP_RET);

    // --- RAS top-of-stack (async read) ---
    wire [31:0] ras_top_addr = ras_stack[ras_top];

    // --- Final prediction output ---
    // Gate with if_allowin: during stalls, pred_taken must be 0 to prevent
    // repeated RAS pops and incorrect PC redirection by next_pc_mux
    wire pred_taken_raw = btb_pred_jal | btb_pred_br | btb_pred_ret;
    // >>> DEBUG: Force prediction OFF to isolate FPGA issue <<<
    assign pred_taken  = 1'b0;  // pred_taken_raw & if_allowin;
    assign pred_target = btb_pred_ret ? ras_top_addr : btb_target[if_idx];

    // ================================================================
    //  RAS: Synchronous Push (ID stage) / Pointer Update
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ras_top <= '0;
        end else begin
            if (ex_mispredict && id_is_call) begin
                ras_top <= ras_top + 1'b1;
                ras_stack[ras_top + 1'b1] <= id_pc + 32'd4;
            end else if (id_is_call && btb_pred_ret) begin
                ras_stack[ras_top + 1'b1] <= id_pc + 32'd4;
                ras_top <= ras_top + 1'b1;
            end else if (id_is_call) begin
                ras_stack[ras_top + 1'b1] <= id_pc + 32'd4;
                ras_top <= ras_top + 1'b1;
            end else if (btb_pred_ret && !ex_mispredict && if_allowin) begin
                // Normal RET prediction: pop only when pipeline is flowing
                ras_top <= ras_top - 1'b1;
            end
        end
    end

    // ================================================================
    //  EX Stage: Synchronous Training (BTB + BHT Update)
    // ================================================================

    wire [BTB_IDX_WIDTH-1:0] ex_idx = ex_pc[BTB_IDX_WIDTH+1 : 2];
    wire [BTB_TAG_WIDTH-1:0] ex_tag = ex_pc[BTB_TAG_WIDTH+BTB_IDX_WIDTH+1 : BTB_IDX_WIDTH+2];
    wire [BHT_IDX_WIDTH-1:0] ex_bht_idx = ex_pc[BHT_IDX_WIDTH+1 : 2];

    // BTB update
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < BTB_DEPTH; i = i + 1) begin
                btb_valid[i] <= 1'b0;
            end
        end else if (update_en) begin
            btb_valid[ex_idx]  <= 1'b1;
            btb_tag[ex_idx]    <= ex_tag;
            btb_type[ex_idx]   <= ex_inst_type;
            btb_target[ex_idx] <= ex_actual_target;
        end
    end

    // BHT update: 2-bit saturating counter
    //   Taken: increment (saturate at 2'b11)
    //   Not taken: decrement (saturate at 2'b00)
    integer j;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < BHT_DEPTH; j = j + 1) begin
                bht_counter[j] <= 2'b01;  // weakly not-taken (cold start)
            end
        end else if (update_en && (ex_inst_type == BP_BR)) begin
            if (ex_actual_taken && bht_counter[ex_bht_idx] != 2'b11) begin
                bht_counter[ex_bht_idx] <= bht_counter[ex_bht_idx] + 1'b1;
            end else if (!ex_actual_taken && bht_counter[ex_bht_idx] != 2'b00) begin
                bht_counter[ex_bht_idx] <= bht_counter[ex_bht_idx] - 1'b1;
            end
        end
    end

endmodule
