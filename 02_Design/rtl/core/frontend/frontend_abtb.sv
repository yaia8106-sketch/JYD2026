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

module frontend_abtb #(
    parameter bit LOCAL_LOOKUP_INDEX = 1'b0,
    parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // The integrated frontend gives the ABTB the same redirect observed by
    // the canonical fetch-PC state.  Standalone users may leave local lookup
    // index state disabled and drive predict_pc directly as before.
    input  logic        redirect_valid,
    input  logic [31:0] redirect_target,

    // Stage-1 lookup. lookup_valid also qualifies LRU updates.
    input  logic        lookup_valid,
    input  logic [31:0] predict_pc, // 当前预测 PC；模块内部同时派生顺序 PC。

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
    // Same prediction without lookup_valid qualification. The frontend samples
    // it only on an accepted lookup, while keeping acceptance/backpressure out
    // of the recursive next-PC datapath.
    output logic [31:0] pred_next_pc_early,

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

    localparam int SETS = 32;
    localparam int SET_IDX_W = $clog2(SETS);
    // Competition traces need two more retained address bits than the former
    // PC[13:7] tag. With 32 sets, PC[7:3] selects the set and PC[16:8] is the
    // observed alias-free nine-bit tag.
    localparam int TAG_W = 9;

    // Preserve the current predictor type encoding for later integration.
    localparam logic [1:0] TYPE_JAL    = 2'b00;
    localparam logic [1:0] TYPE_CALL   = 2'b01;
    localparam logic [1:0] TYPE_BRANCH = 2'b10;
    localparam logic [1:0] TYPE_RET    = 2'b11;

    localparam int PAYLOAD_W = TAG_W + 2 + 32;
    localparam int TYPE_MSB = 33;
    localparam int TYPE_LSB = 32;

    // Lookup validity lives in one compact four-bit-wide LUTRAM.  This removes
    // the four resettable 32:1 FF muxes from the recursive next-PC path while
    // leaving the wide payload RAMs with only their normal update write port.
    // A separate non-critical mirror serves miss allocation.
    logic bank0_way0_alloc_valid [0:SETS-1];
    logic bank0_way1_alloc_valid [0:SETS-1];
    logic bank1_way0_alloc_valid [0:SETS-1];
    logic bank1_way1_alloc_valid [0:SETS-1];

    // Bit order is {bank1 way1, bank1 way0, bank0 way1, bank0 way0}.
    // Only this narrow memory is cleared after reset.  Clearing the 44-bit
    // payload memories made Vivado duplicate their LUTRAM implementation.
    (* ram_style = "distributed" *)
    logic [3:0] lookup_valid_mem [0:SETS-1];

    // Keep each bank/way payload as one compact logical memory. Predictor
    // training is registered before this module, so its write enable no
    // longer contains the backend resolve/allow chain that motivated the
    // former payload chunking experiment.
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
    wire [SET_IDX_W-1:0] canonical_lookup_set =
        pred_lookup_block_pc[3 +: SET_IDX_W];
    wire [TAG_W-1:0] pred_lookup_tag =
        pred_lookup_block_pc[3 + SET_IDX_W +: TAG_W];

    // PC[7:3] addresses every bit of five asynchronous LUTRAMs.  Driving all
    // of those address pins from the canonical fetch-PC register created the
    // remaining high-fanout recursive timing path.  In the integrated core,
    // keep five small, cycle-identical index states local to their memories.
    // Only the index is replicated: tags, targets and the architectural PC
    // remain single-copy state.
    wire [SET_IDX_W-1:0] bank0_way0_lookup_set;
    wire [SET_IDX_W-1:0] bank0_way1_lookup_set;
    wire [SET_IDX_W-1:0] bank1_way0_lookup_set;
    wire [SET_IDX_W-1:0] bank1_way1_lookup_set;
    wire [SET_IDX_W-1:0] valid_lookup_set;

    generate
        if (LOCAL_LOOKUP_INDEX) begin : g_local_lookup_index
            // KEEP is intentional and narrowly scoped: without it these five
            // equivalent state vectors collapse back into the original
            // high-fanout PC-index driver during synthesis.
            (* keep = "true" *) logic [SET_IDX_W-1:0] bank0_way0_set_q;
            (* keep = "true" *) logic [SET_IDX_W-1:0] bank0_way1_set_q;
            (* keep = "true" *) logic [SET_IDX_W-1:0] bank1_way0_set_q;
            (* keep = "true" *) logic [SET_IDX_W-1:0] bank1_way1_set_q;
            (* keep = "true" *) logic [SET_IDX_W-1:0] valid_set_q;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    bank0_way0_set_q <= RESET_PC[3 +: SET_IDX_W];
                    bank0_way1_set_q <= RESET_PC[3 +: SET_IDX_W];
                    bank1_way0_set_q <= RESET_PC[3 +: SET_IDX_W];
                    bank1_way1_set_q <= RESET_PC[3 +: SET_IDX_W];
                    valid_set_q <= RESET_PC[3 +: SET_IDX_W];
                end else if (redirect_valid) begin
                    bank0_way0_set_q <= redirect_target[3 +: SET_IDX_W];
                    bank0_way1_set_q <= redirect_target[3 +: SET_IDX_W];
                    bank1_way0_set_q <= redirect_target[3 +: SET_IDX_W];
                    bank1_way1_set_q <= redirect_target[3 +: SET_IDX_W];
                    valid_set_q <= redirect_target[3 +: SET_IDX_W];
                end else if (lookup_valid) begin
                    bank0_way0_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                    bank0_way1_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                    bank1_way0_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                    bank1_way1_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                    valid_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                end
            end

            assign bank0_way0_lookup_set = bank0_way0_set_q;
            assign bank0_way1_lookup_set = bank0_way1_set_q;
            assign bank1_way0_lookup_set = bank1_way0_set_q;
            assign bank1_way1_lookup_set = bank1_way1_set_q;
            assign valid_lookup_set = valid_set_q;

`ifndef SYNTHESIS
            always_ff @(posedge clk) begin
                if (rst_n
                    && ({bank0_way0_set_q, bank0_way1_set_q,
                         bank1_way0_set_q, bank1_way1_set_q, valid_set_q}
                        !== {5{canonical_lookup_set}}))
                    $fatal(1, "ABTB local lookup indices diverged from fetch PC");
            end
`endif
        end else begin : g_direct_lookup_index
            assign bank0_way0_lookup_set = canonical_lookup_set;
            assign bank0_way1_lookup_set = canonical_lookup_set;
            assign bank1_way0_lookup_set = canonical_lookup_set;
            assign bank1_way1_lookup_set = canonical_lookup_set;
            assign valid_lookup_set = canonical_lookup_set;
        end
    endgenerate

    wire [PAYLOAD_W-1:0] bank0_way0_lookup_payload =
        bank0_way0_payload[bank0_way0_lookup_set];
    wire [PAYLOAD_W-1:0] bank0_way1_lookup_payload =
        bank0_way1_payload[bank0_way1_lookup_set];
    wire [PAYLOAD_W-1:0] bank1_way0_lookup_payload =
        bank1_way0_payload[bank1_way0_lookup_set];
    wire [PAYLOAD_W-1:0] bank1_way1_lookup_payload =
        bank1_way1_payload[bank1_way1_lookup_set];

    logic clear_active;
    logic [SET_IDX_W-1:0] clear_set_q;
    wire abtb_ready = ~clear_active;

    wire [3:0] lookup_valid_vector = lookup_valid_mem[valid_lookup_set];
    wire bank0_way0_lookup_valid = lookup_valid_vector[0];
    wire bank0_way1_lookup_valid = lookup_valid_vector[1];
    wire bank1_way0_lookup_valid = lookup_valid_vector[2];
    wire bank1_way1_lookup_valid = lookup_valid_vector[3];

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

    wire bank0_way0_match = abtb_ready & bank0_way0_lookup_valid
                          && (bank0_way0_lookup_tag == pred_lookup_tag);
    wire bank0_way1_match = abtb_ready & bank0_way1_lookup_valid
                          && (bank0_way1_lookup_tag == pred_lookup_tag);
    wire bank1_way0_match = abtb_ready & bank1_way0_lookup_valid
                          && (bank1_way0_lookup_tag == pred_lookup_tag);
    wire bank1_way1_match = abtb_ready & bank1_way1_lookup_valid
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

    // Tag matches and direction candidates do not semantically depend on
    // lookup_valid. Compute the recursive PC choice from those raw candidates;
    // lookup_valid continues to qualify every externally visible hit/training
    // event below.
    wire bank0_pred_taken_early = !predict_pc[2]
                                & bank0_selected_taken_candidate;
    wire bank1_pred_taken_early = bank1_selected_taken_candidate;
    wire bank0_prediction_selected_early = bank0_pred_taken_early;
    wire bank1_prediction_selected_early = bank1_pred_taken_early
                                         & ~bank0_pred_taken_early;
    wire [1:0] prediction_select_early = {
        bank0_prediction_selected_early,
        bank1_prediction_selected_early
    };

    // Encode the mutually exclusive global steering decision before the
    // 32-bit targets arrive.  The wide next-PC path is then one final 3-way
    // selector local to the ABTB instead of being reconstructed in the FTQ.
    wire bank0_prediction_selected = bank0_pred_taken;
    wire bank1_prediction_selected = bank1_pred_taken
                                   & ~bank0_pred_taken;
    wire [1:0] prediction_select = {
        bank0_prediction_selected, bank1_prediction_selected
    };

    function automatic logic [31:0] select_pred_target(
        input logic [1:0] select,
        input logic [31:0] bank0_target,
        input logic [31:0] bank1_target
    );
        case (select)
            2'b10: select_pred_target = bank0_target;
            2'b01: select_pred_target = bank1_target;
            default: select_pred_target = 32'd0;
        endcase
    endfunction

    function automatic logic [31:0] select_pred_next_pc(
        input logic [1:0] select,
        input logic [31:0] bank0_target,
        input logic [31:0] bank1_target,
        input logic [31:0] sequential_pc
    );
        case (select)
            2'b10: select_pred_next_pc = bank0_target;
            2'b01: select_pred_next_pc = bank1_target;
            default: select_pred_next_pc = sequential_pc;
        endcase
    endfunction

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

    end

    assign pred_taken = |prediction_select;
    assign pred_bank = bank1_prediction_selected;
    assign pred_cfi_type = bank0_prediction_selected ? bank0_cfi_type
                         : bank1_prediction_selected ? bank1_cfi_type
                                                     : 2'd0;
    assign pred_target = select_pred_target(
        prediction_select,
        bank0_selected_pred_target_candidate,
        bank1_selected_pred_target_candidate
    );
    assign pred_next_pc = select_pred_next_pc(
        prediction_select,
        bank0_selected_pred_target_candidate,
        bank1_selected_pred_target_candidate,
        sequential_next_pc
    );
    assign pred_next_pc_early = select_pred_next_pc(
        prediction_select_early,
        bank0_selected_pred_target_candidate,
        bank1_selected_pred_target_candidate,
        sequential_next_pc
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && lookup_valid
                  && (pred_next_pc_early !== pred_next_pc))
            $error("Early ABTB next PC disagrees with qualified lookup");
        if (rst_n && clear_active
                  && (bank0_lookup_hit || bank1_lookup_hit || pred_taken))
            $fatal(1, "ABTB predicted before its LUTRAM valid clear completed");
        if (rst_n && abtb_ready
                  && ({bank1_way1_lookup_valid, bank1_way0_lookup_valid,
                       bank0_way1_lookup_valid, bank0_way0_lookup_valid}
                      !== {bank1_way1_alloc_valid[canonical_lookup_set],
                           bank1_way0_alloc_valid[canonical_lookup_set],
                           bank0_way1_alloc_valid[canonical_lookup_set],
                           bank0_way0_alloc_valid[canonical_lookup_set]}))
            $fatal(1, "ABTB LUTRAM valid bits disagree with allocation mirror");
    end
`endif

    wire update_bank = update_pc[2];
    wire [31:0] update_block_pc = {update_pc[31:3], 3'b000};
    wire [SET_IDX_W-1:0] update_set =
        update_block_pc[3 +: SET_IDX_W];
    wire [TAG_W-1:0] update_tag =
        update_block_pc[3 + SET_IDX_W +: TAG_W];

    logic bank0_update_alloc_way;
    logic bank1_update_alloc_way;

    // Miss allocation first fills invalid ways, then falls back to pseudo-LRU.
    // Compute both banks in parallel. The former bank-first priority tree put
    // update_bank in front of allocation, hit selection, and the LUTRAM write
    // enable; only the final bank-valid gate actually depends on update_bank.
    always_comb begin
        if (!bank0_way0_alloc_valid[update_set])
            bank0_update_alloc_way = 1'b0;
        else if (!bank0_way1_alloc_valid[update_set])
            bank0_update_alloc_way = 1'b1;
        else
            bank0_update_alloc_way = bank0_lru[update_set];

        if (!bank1_way0_alloc_valid[update_set])
            bank1_update_alloc_way = 1'b0;
        else if (!bank1_way1_alloc_valid[update_set])
            bank1_update_alloc_way = 1'b1;
        else
            bank1_update_alloc_way = bank1_lru[update_set];
    end

    wire bank0_update_selected_way = update_hit ? update_way
                                                : bank0_update_alloc_way;
    wire bank1_update_selected_way = update_hit ? update_way
                                                : bank1_update_alloc_way;
    // Predictor training during the short reset-clear window is deliberately
    // ignored. It is speculative state only; architectural execution keeps
    // running sequentially and normal training resumes as soon as ready.
    wire bank0_update_fire = update_valid & abtb_ready & ~update_bank;
    wire bank1_update_fire = update_valid & abtb_ready &  update_bank;

    localparam logic [SET_IDX_W-1:0] LAST_SET = SETS - 1;
    wire clear_last_set = clear_set_q == LAST_SET;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            clear_active <= 1'b1;
            clear_set_q <= '0;
        end else if (clear_active) begin
            if (clear_last_set) begin
                clear_active <= 1'b0;
            end else
                clear_set_q <= clear_set_q
                    + {{(SET_IDX_W-1){1'b0}}, 1'b1};
        end
    end

    integer set_i;
    // This resettable mirror is used only by the update/allocation cluster.
    // The timing-critical lookup consumes the valid bit stored in LUTRAM.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (set_i = 0; set_i < SETS; set_i = set_i + 1) begin
                bank0_way0_alloc_valid[set_i] <= 1'b0;
                bank0_way1_alloc_valid[set_i] <= 1'b0;
                bank1_way0_alloc_valid[set_i] <= 1'b0;
                bank1_way1_alloc_valid[set_i] <= 1'b0;
            end
        end else begin
            if (bank0_update_fire) begin
                if (!bank0_update_selected_way)
                    bank0_way0_alloc_valid[update_set] <= 1'b1;
                else
                    bank0_way1_alloc_valid[update_set] <= 1'b1;
            end
            if (bank1_update_fire) begin
                if (!bank1_update_selected_way)
                    bank1_way0_alloc_valid[update_set] <= 1'b1;
                else
                    bank1_way1_alloc_valid[update_set] <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && abtb_ready) begin
            if (lookup_valid && !predict_pc[2] && bank0_hit)
                bank0_lru[canonical_lookup_set] <= !bank0_way;
            if (bank0_update_fire)
                bank0_lru[update_set] <= !bank0_update_selected_way;

            if (lookup_valid && bank1_hit && !bank0_pred_taken)
                bank1_lru[canonical_lookup_set] <= !bank1_way;
            if (bank1_update_fire)
                bank1_lru[update_set] <= !bank1_update_selected_way;
        end
    end

    wire [3:0] update_valid_vector = {
        bank1_way1_alloc_valid[update_set],
        bank1_way0_alloc_valid[update_set],
        bank0_way1_alloc_valid[update_set],
        bank0_way0_alloc_valid[update_set]
    } | (bank0_update_fire
            ? (bank0_update_selected_way ? 4'b0010 : 4'b0001)
            : 4'b0000)
      | (bank1_update_fire
            ? (bank1_update_selected_way ? 4'b1000 : 4'b0100)
            : 4'b0000);

    // Only the narrow lookup-valid LUTRAM is cleared, one set per cycle.
    // Prediction is masked until the last set is cleared.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (clear_active) begin
                lookup_valid_mem[clear_set_q] <= 4'b0000;
            end else if (bank0_update_fire || bank1_update_fire)
                lookup_valid_mem[update_set] <= update_valid_vector;
        end
    end

    // Wide payload contents are irrelevant until lookup_valid_mem says that
    // the corresponding way is valid, so these arrays intentionally have no
    // reset or background-clear write port.
    always_ff @(posedge clk) begin
        if (bank0_update_fire && !bank0_update_selected_way)
            bank0_way0_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (bank0_update_fire && bank0_update_selected_way)
            bank0_way1_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (bank1_update_fire && !bank1_update_selected_way)
            bank1_way0_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (bank1_update_fire && bank1_update_selected_way)
            bank1_way1_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
    end

endmodule
