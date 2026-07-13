// ============================================================
// Module: frontend_abtb
// "a" means ahead
// "btb" means branch target buffer
// Description: Two-bank, two-way ahead BTB for one 64-bit fetch block.
// Domain: frontend.
//   - bank0 describes block_pc
//   - bank1 describes block_pc + 4
//   - both banks are read combinationally and in parallel
//   - only one confirmed CFI update(not two) can be written per cycle

// Direction and ret ins'state&direction are intentionally outside this module.
// ============================================================

module frontend_abtb (
    input  logic        clk,
    input  logic        rst_n,

    // Stage-1 lookup. lookup_valid also qualifies LRU updates.
    input  logic        lookup_valid,
    input  logic [31:0] predict_pc, // pred PC + sequential PC

    // Future PHT/RAS result inputs. J type instruction's directions are generated locally from the stored CFI type.
    input  logic        bank0_branch_taken,
    input  logic        bank1_branch_taken,
    input  logic        bank0_ret_valid,
    input  logic [31:0] bank0_ret_target,
    input  logic        bank1_ret_valid,
    input  logic [31:0] bank1_ret_target,

    // Parallel per-bank lookup metadata.
    output logic        bank0_eligible, // if predict_pc[2] is 1, bank0 is not eligible for prediction
    output logic        bank0_lookup_hit, // if(pred_tag == bank0_tag && bank0_valid)
    output logic        bank0_hit, // if(lookup_valid && bank0_lookup_hit)
    output logic        bank0_way, // ~pred_pc[3]
    output logic [ 1:0] bank0_cfi_type, // JAL, JALR, BRANCH, RET
    output logic [31:0] bank0_abtb_pred_target, // from ABTB RAM, before RET replacement
    output logic        bank0_pred_taken,
    output logic [31:0] bank0_final_pred_target, // if RET, from RAS; else from ABTB RAM

    output logic        bank1_eligible,
    output logic        bank1_lookup_hit,
    output logic        bank1_hit,
    output logic        bank1_way, // pred_pc[3]
    output logic [ 1:0] bank1_cfi_type,
    output logic [31:0] bank1_abtb_pred_target,
    output logic        bank1_pred_taken,
    output logic [31:0] bank1_final_pred_target,

    // Program-order selection. bank0 wins when both candidates are taken.
    output logic        pred_taken,
    output logic        pred_bank,
    output logic [ 1:0] pred_cfi_type,
    output logic [31:0] pred_target,
    output logic [31:0] pred_next_pc, // if pred_taken is 1, pred_next_pc = pred_target; else pred_next_pc = sequential_next_pc

    // Confirmed update port.
    // A hit uses bank/way metadata carried from prediction to update
    // unhit update will be allocated by valid/LRU.
    input  logic        update_valid,
    input  logic        update_hit,
    // !These metadata may become stale after an intervening replacement;
    // !now we choose to use the stale metadata to update, but it will cause misprediction if the stale metadata is wrong.
    input  logic        update_way,
    input  logic [31:0] update_pc,
    input  logic [ 1:0] update_cfi_type,
    input  logic [31:0] update_target
);

    localparam int SETS = 16;
    localparam int SET_IDX_W = 4;
    // The implemented IROM is 16 KB(64*2048bits) at one fixed base address, so PC[13:7] uniquely identifies the remaining block address after set selection.
    localparam int TAG_W = 7;

    // Preserve the current predictor type encoding for later integration.
    localparam logic [1:0] TYPE_JAL    = 2'b00;
    localparam logic [1:0] TYPE_CALL   = 2'b01;
    localparam logic [1:0] TYPE_BRANCH = 2'b10;
    localparam logic [1:0] TYPE_RET    = 2'b11;

    localparam int PAYLOAD_W = TAG_W + 2 + 32; // tag(7) + cfi_type(2) + target(32) = 41 bit
    localparam int TYPE_MSB = 33;
    localparam int TYPE_LSB = 32;

    // Valid bits are reset explicitly. Payloads have no reset so Vivado can
    // infer shallow distributed RAM; invalid payload contents are never used.
    logic bank0_way0_valid [0:SETS-1];
    logic bank0_way1_valid [0:SETS-1];
    logic bank1_way0_valid [0:SETS-1];
    logic bank1_way1_valid [0:SETS-1];

    // 16(set) * 41(entry) bit
    // tag(7) + cfi_type(2) + target(32) = 41 bit
    (* ram_style = "distributed" *)
    logic [PAYLOAD_W-1:0] bank0_way0_payload [0:SETS-1];
    (* ram_style = "distributed" *)
    logic [PAYLOAD_W-1:0] bank0_way1_payload [0:SETS-1];
    (* ram_style = "distributed" *)
    logic [PAYLOAD_W-1:0] bank1_way0_payload [0:SETS-1];
    (* ram_style = "distributed" *)
    logic [PAYLOAD_W-1:0] bank1_way1_payload [0:SETS-1];

    // Value is the way to replace next when both ways are valid.
    logic bank0_lru [0:SETS-1];
    logic bank1_lru [0:SETS-1];

    wire [31:0] pred_lookup_block_pc = {predict_pc[31:3], 3'b000};
    wire [SET_IDX_W-1:0] pred_lookup_set = pred_lookup_block_pc[6:3];
    wire [TAG_W-1:0] pred_lookup_tag = pred_lookup_block_pc[13:7];

    wire [PAYLOAD_W-1:0] bank0_way0_lookup_payload =
        bank0_way0_payload[pred_lookup_set];
    wire [PAYLOAD_W-1:0] bank0_way1_lookup_payload =
        bank0_way1_payload[pred_lookup_set];
    wire [PAYLOAD_W-1:0] bank1_way0_lookup_payload =
        bank1_way0_payload[pred_lookup_set];
    wire [PAYLOAD_W-1:0] bank1_way1_lookup_payload =
        bank1_way1_payload[pred_lookup_set];

    // TAG
    wire [TAG_W-1:0] bank0_way0_lookup_tag =
        bank0_way0_lookup_payload[PAYLOAD_W-1 -: TAG_W];
    wire [TAG_W-1:0] bank0_way1_lookup_tag =
        bank0_way1_lookup_payload[PAYLOAD_W-1 -: TAG_W];
    wire [TAG_W-1:0] bank1_way0_lookup_tag =
        bank1_way0_lookup_payload[PAYLOAD_W-1 -: TAG_W];
    wire [TAG_W-1:0] bank1_way1_lookup_tag =
        bank1_way1_lookup_payload[PAYLOAD_W-1 -: TAG_W];

    // TYPE
    wire [1:0] bank0_way0_lookup_type =
        bank0_way0_lookup_payload[TYPE_MSB:TYPE_LSB];
    wire [1:0] bank0_way1_lookup_type =
        bank0_way1_lookup_payload[TYPE_MSB:TYPE_LSB];
    wire [1:0] bank1_way0_lookup_type =
        bank1_way0_lookup_payload[TYPE_MSB:TYPE_LSB];
    wire [1:0] bank1_way1_lookup_type =
        bank1_way1_lookup_payload[TYPE_MSB:TYPE_LSB];

    // TARGET
    wire [31:0] bank0_way0_stored_target = bank0_way0_lookup_payload[31:0];
    wire [31:0] bank0_way1_stored_target = bank0_way1_lookup_payload[31:0];
    wire [31:0] bank1_way0_stored_target = bank1_way0_lookup_payload[31:0];
    wire [31:0] bank1_way1_stored_target = bank1_way1_lookup_payload[31:0];

    wire bank0_way0_match = bank0_way0_valid[pred_lookup_set]
                          && (bank0_way0_lookup_tag == pred_lookup_tag);
    wire bank0_way1_match = bank0_way1_valid[pred_lookup_set]
                          && (bank0_way1_lookup_tag == pred_lookup_tag);
    wire bank1_way0_match = bank1_way0_valid[pred_lookup_set]
                          && (bank1_way0_lookup_tag == pred_lookup_tag);
    wire bank1_way1_match = bank1_way1_valid[pred_lookup_set]
                          && (bank1_way1_lookup_tag == pred_lookup_tag);

    wire bank0_way0_is_direct = !bank0_way0_lookup_type[1];
    wire bank0_way1_is_direct = !bank0_way1_lookup_type[1];
    wire bank1_way0_is_direct = !bank1_way0_lookup_type[1];
    wire bank1_way1_is_direct = !bank1_way1_lookup_type[1];

    wire bank0_way0_is_branch = bank0_way0_lookup_type == TYPE_BRANCH;
    wire bank0_way1_is_branch = bank0_way1_lookup_type == TYPE_BRANCH;
    wire bank1_way0_is_branch = bank1_way0_lookup_type == TYPE_BRANCH;
    wire bank1_way1_is_branch = bank1_way1_lookup_type == TYPE_BRANCH;

    wire bank0_way0_is_ret = bank0_way0_lookup_type == TYPE_RET;
    wire bank0_way1_is_ret = bank0_way1_lookup_type == TYPE_RET;
    wire bank1_way0_is_ret = bank1_way0_lookup_type == TYPE_RET;
    wire bank1_way1_is_ret = bank1_way1_lookup_type == TYPE_RET;

    wire bank0_way0_taken_candidate =
        bank0_way0_is_direct
        || (bank0_way0_is_branch && bank0_branch_taken)
        || (bank0_way0_is_ret && bank0_ret_valid);
    wire bank0_way1_taken_candidate =
        bank0_way1_is_direct
        || (bank0_way1_is_branch && bank0_branch_taken)
        || (bank0_way1_is_ret && bank0_ret_valid);
    wire bank1_way0_taken_candidate =
        bank1_way0_is_direct
        || (bank1_way0_is_branch && bank1_branch_taken)
        || (bank1_way0_is_ret && bank1_ret_valid);
    wire bank1_way1_taken_candidate =
        bank1_way1_is_direct
        || (bank1_way1_is_branch && bank1_branch_taken)
        || (bank1_way1_is_ret && bank1_ret_valid);

    // if the stored CFI is a RET, the predicted target is replaced by the RAS result.
    // else the predicted target is the stored target in the ABTB RAM.
    wire [31:0] bank0_way0_pred_target_candidate =
        bank0_way0_is_ret ? bank0_ret_target : bank0_way0_stored_target;
    wire [31:0] bank0_way1_pred_target_candidate =
        bank0_way1_is_ret ? bank0_ret_target : bank0_way1_stored_target;
    wire [31:0] bank1_way0_pred_target_candidate =
        bank1_way0_is_ret ? bank1_ret_target : bank1_way0_stored_target;
    wire [31:0] bank1_way1_pred_target_candidate =
        bank1_way1_is_ret ? bank1_ret_target : bank1_way1_stored_target;

    // way0 has priority if corrupted or stale training leaves duplicate tags.
    wire bank0_way1_selected = !bank0_way0_match && bank0_way1_match;
    wire bank1_way1_selected = !bank1_way0_match && bank1_way1_match;

    wire bank0_any_match = bank0_way0_match || bank0_way1_match;
    wire bank1_any_match = bank1_way0_match || bank1_way1_match;

    wire bank0_selected_taken_candidate =
        (bank0_way0_match && bank0_way0_taken_candidate)
        || (bank0_way1_selected && bank0_way1_taken_candidate);
    wire bank1_selected_taken_candidate =
        (bank1_way0_match && bank1_way0_taken_candidate)
        || (bank1_way1_selected && bank1_way1_taken_candidate);

    wire [31:0] bank0_selected_pred_target_candidate =
        bank0_way0_match ? bank0_way0_pred_target_candidate
                         : bank0_way1_pred_target_candidate;
    wire [31:0] bank1_selected_pred_target_candidate =
        bank1_way0_match ? bank1_way0_pred_target_candidate
                         : bank1_way1_pred_target_candidate;

    wire [31:0] sequential_next_pc =
        predict_pc + (predict_pc[2] ? 32'd4 : 32'd8);

    // Combine tag-hit, CFI type, PHT direction, and optional ras return targets
    // into per-bank predictions, then choose the earliest taken bank.
    always_comb begin
        bank0_eligible = lookup_valid && !predict_pc[2];
        bank0_lookup_hit = !predict_pc[2] && bank0_any_match;
        bank0_hit = lookup_valid && bank0_lookup_hit;
        bank0_way = bank0_way1_selected;
        bank0_cfi_type = 2'd0;
        bank0_abtb_pred_target = 32'd0;

        if (bank0_way0_match) begin
            bank0_cfi_type = bank0_way0_lookup_type;
            bank0_abtb_pred_target = bank0_way0_stored_target;
        end else if (bank0_way1_selected) begin
            bank0_cfi_type = bank0_way1_lookup_type;
            bank0_abtb_pred_target = bank0_way1_stored_target;
        end

        bank1_eligible = lookup_valid;
        bank1_lookup_hit = bank1_any_match;
        bank1_hit = lookup_valid && bank1_lookup_hit;
        bank1_way = bank1_way1_selected;
        bank1_cfi_type = 2'd0;
        bank1_abtb_pred_target = 32'd0;

        if (bank1_way0_match) begin
            bank1_cfi_type = bank1_way0_lookup_type;
            bank1_abtb_pred_target = bank1_way0_stored_target;
        end else if (bank1_way1_selected) begin
            bank1_cfi_type = bank1_way1_lookup_type;
            bank1_abtb_pred_target = bank1_way1_stored_target;
        end

        bank0_pred_taken =
            bank0_eligible && bank0_selected_taken_candidate;
        bank0_final_pred_target = bank0_abtb_pred_target;
        if (bank0_hit) begin
            bank0_final_pred_target = bank0_selected_pred_target_candidate;
        end

        bank1_pred_taken =
            bank1_eligible && bank1_selected_taken_candidate;
        bank1_final_pred_target = bank1_abtb_pred_target;
        if (bank1_hit) begin
            bank1_final_pred_target = bank1_selected_pred_target_candidate;
        end

        pred_taken = bank0_pred_taken || bank1_pred_taken;
        pred_bank = bank1_pred_taken && !bank0_pred_taken;
        pred_cfi_type = 2'd0;
        pred_target = 32'd0;
        pred_next_pc = sequential_next_pc;

        if (bank0_pred_taken) begin
            pred_cfi_type = bank0_cfi_type;
            pred_target = bank0_selected_pred_target_candidate;
            pred_next_pc = bank0_selected_pred_target_candidate;
        end else if (bank1_pred_taken) begin
            pred_cfi_type = bank1_cfi_type;
            pred_target = bank1_selected_pred_target_candidate;
            pred_next_pc = bank1_selected_pred_target_candidate;
        end
    end

    wire update_bank = update_pc[2];
    wire [31:0] update_block_pc = {update_pc[31:3], 3'b000};
    wire [SET_IDX_W-1:0] update_set = update_block_pc[6:3];
    wire [TAG_W-1:0] update_tag = update_block_pc[13:7];

    logic update_alloc_way;

    // Miss allocation first fills invalid ways, then falls back to pseudo-LRU.
    always_comb begin
        update_alloc_way = 1'b0;
        if (!update_bank) begin
            if (!bank0_way0_valid[update_set])
                update_alloc_way = 1'b0;
            else if (!bank0_way1_valid[update_set])
                update_alloc_way = 1'b1;
            else
                update_alloc_way = bank0_lru[update_set];
        end else begin
            if (!bank1_way0_valid[update_set])
                update_alloc_way = 1'b0;
            else if (!bank1_way1_valid[update_set])
                update_alloc_way = 1'b1;
            else
                update_alloc_way = bank1_lru[update_set];
        end
    end

    wire update_selected_way = update_hit ? update_way : update_alloc_way;

    integer set_i;
    // Valid bits and LRU state are explicit registers; payload RAM is written
    // separately to keep reset from blocking distributed RAM inference.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (set_i = 0; set_i < SETS; set_i = set_i + 1) begin
                bank0_way0_valid[set_i] <= 1'b0;
                bank0_way1_valid[set_i] <= 1'b0;
                bank1_way0_valid[set_i] <= 1'b0;
                bank1_way1_valid[set_i] <= 1'b0;
                bank0_lru[set_i] <= 1'b0;
                bank1_lru[set_i] <= 1'b0;
            end
        end else begin
            if (lookup_valid && !predict_pc[2] && bank0_hit)
                bank0_lru[pred_lookup_set] <= !bank0_way;

            if (update_valid && !update_bank) begin
                if (!update_selected_way)
                    bank0_way0_valid[update_set] <= 1'b1;
                else
                    bank0_way1_valid[update_set] <= 1'b1;
                bank0_lru[update_set] <= !update_selected_way;
            end

            if (lookup_valid && bank1_hit && !bank0_pred_taken)
                bank1_lru[pred_lookup_set] <= !bank1_way;

            if (update_valid && update_bank) begin
                if (!update_selected_way)
                    bank1_way0_valid[update_set] <= 1'b1;
                else
                    bank1_way1_valid[update_set] <= 1'b1;
                bank1_lru[update_set] <= !update_selected_way;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (update_valid && !update_bank && !update_selected_way)
            bank0_way0_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (update_valid && !update_bank && update_selected_way)
            bank0_way1_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (update_valid && update_bank && !update_selected_way)
            bank1_way0_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (update_valid && update_bank && update_selected_way)
            bank1_way1_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
    end

endmodule
