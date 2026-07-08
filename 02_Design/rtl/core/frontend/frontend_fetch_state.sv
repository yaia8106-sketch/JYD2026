// ============================================================
// Module: frontend_fetch_state
// Description: BP0 PC/epoch, accepted F0 metadata, and outstanding count.
// Domain: frontend.
// All outputs in this module are clock-edge state; prediction and packet
// construction remain combinational in frontend_ftq.
// ============================================================

module frontend_fetch_state
    import cpu_defs::*;
#(
    parameter int FTQ_PTR_W = 3,
    parameter bit WIDE_ABTB_META = 1'b0,
    parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       redirect_valid,
    input  logic [31:0]                redirect_target,

    input  logic                       accept,
    input  logic [ 1:0]                accept_base_mask,
    input  frontend_steer_result_t     accept_steer,
    input  frontend_f0_bank_meta_t     accept_bank0_meta,
    input  frontend_f0_bank_meta_t     accept_bank1_meta,
    input  frontend_abtb_meta_t        accept_abtb_bank0_meta,
    input  frontend_abtb_meta_t        accept_abtb_bank1_meta,

    output logic [31:0]                current_pc,
    output logic [ 1:0]                frontend_epoch,
    output frontend_f0_state_t         f0_state,
    output frontend_abtb_meta_t        f0_abtb_bank0_meta,
    output frontend_abtb_meta_t        f0_abtb_bank1_meta,
    output logic [FTQ_PTR_W:0]         outstanding_count
);

    logic f0_abtb_bank0_hit_r;
    logic f0_abtb_bank0_way_r;
    logic f0_abtb_bank1_hit_r;
    logic f0_abtb_bank1_way_r;

    assign f0_abtb_bank0_meta.hit = f0_abtb_bank0_hit_r;
    assign f0_abtb_bank0_meta.way = f0_abtb_bank0_way_r;
    assign f0_abtb_bank1_meta.hit = f0_abtb_bank1_hit_r;
    assign f0_abtb_bank1_meta.way = f0_abtb_bank1_way_r;

    // BP0 PC state advances on accepted predictions and is reset immediately
    // by backend redirects. The epoch marks outstanding F0 responses.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_pc <= RESET_PC;
            frontend_epoch <= 2'd0;
        end else if (redirect_valid) begin
            current_pc <= redirect_target;
            frontend_epoch <= frontend_epoch + 2'd1;
        end else if (accept) begin
            current_pc <= accept_steer.next_pc;
        end
    end

    // F0 metadata is the one-cycle-delayed packet context paired with the IROM
    // response. Redirects invalidate it by changing the epoch and clearing valid.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            f0_state.valid <= 1'b0;
            f0_state.epoch <= 2'd0;
            f0_state.start_pc <= 32'd0;
            f0_state.base_mask <= 2'd0;
            f0_state.steer <= '0;
            f0_state.bank0_meta.branch_owned <= 1'b0;
            f0_state.bank0_meta.pht_index <= 8'd0;
            f0_state.bank0_meta.pht_counter <= 2'b01;
            f0_state.bank1_meta.branch_owned <= 1'b0;
            f0_state.bank1_meta.pht_index <= 8'd0;
            f0_state.bank1_meta.pht_counter <= 2'b01;
            f0_abtb_bank0_hit_r <= 1'b0;
            f0_abtb_bank0_way_r <= 1'b0;
            f0_abtb_bank1_hit_r <= 1'b0;
            f0_abtb_bank1_way_r <= 1'b0;
        end else if (redirect_valid) begin
            f0_state.valid <= 1'b0;
        end else begin
            f0_state.valid <= accept;
            if (accept) begin
                f0_state.epoch <= frontend_epoch;
                f0_state.start_pc <= current_pc;
                f0_state.base_mask <= accept_base_mask;
                f0_state.steer.taken <= accept_steer.taken;
                f0_state.steer.source_abtb <= accept_steer.source_abtb;
                f0_state.steer.bank <= accept_steer.bank;
                f0_state.steer.cfi_type <= accept_steer.cfi_type;
                f0_state.steer.target <= accept_steer.target;
                f0_state.steer.next_pc <= accept_steer.next_pc;
                f0_state.bank0_meta <= accept_bank0_meta;
                f0_state.bank1_meta <= accept_bank1_meta;
                f0_abtb_bank0_hit_r <= accept_abtb_bank0_meta.hit;
                f0_abtb_bank0_way_r <= accept_abtb_bank0_meta.way;
                f0_abtb_bank1_hit_r <= accept_abtb_bank1_meta.hit;
                f0_abtb_bank1_way_r <= accept_abtb_bank1_meta.way;
            end
        end
    end

    // Outstanding count tracks accepted BP0 requests minus returned F0 packets.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            outstanding_count <= '0;
        end else if (redirect_valid) begin
            outstanding_count <= '0;
        end else begin
            case ({accept, f0_state.valid})
                2'b10: outstanding_count <=
                    outstanding_count + {{FTQ_PTR_W{1'b0}}, 1'b1};
                2'b01: outstanding_count <=
                    outstanding_count - {{FTQ_PTR_W{1'b0}}, 1'b1};
                default: outstanding_count <= outstanding_count;
            endcase
        end
    end

    generate
        // Wide metadata is only needed for observation/debug builds; functional
        // prediction uses hit/way plus normal carried prediction fields.
        if (WIDE_ABTB_META) begin : g_wide_abtb_meta
            logic [ 1:0] bank0_cfi_type_r;
            logic [31:0] bank0_target_r;
            logic        bank0_pred_taken_r;
            logic [31:0] bank0_pred_target_r;
            logic [ 1:0] bank1_cfi_type_r;
            logic [31:0] bank1_target_r;
            logic        bank1_pred_taken_r;
            logic [31:0] bank1_pred_target_r;

            assign f0_abtb_bank0_meta.cfi_type = bank0_cfi_type_r;
            assign f0_abtb_bank0_meta.target = bank0_target_r;
            assign f0_abtb_bank0_meta.pred_taken = bank0_pred_taken_r;
            assign f0_abtb_bank0_meta.pred_target = bank0_pred_target_r;
            assign f0_abtb_bank1_meta.cfi_type = bank1_cfi_type_r;
            assign f0_abtb_bank1_meta.target = bank1_target_r;
            assign f0_abtb_bank1_meta.pred_taken = bank1_pred_taken_r;
            assign f0_abtb_bank1_meta.pred_target = bank1_pred_target_r;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    bank0_cfi_type_r <= 2'd0;
                    bank0_target_r <= 32'd0;
                    bank0_pred_taken_r <= 1'b0;
                    bank0_pred_target_r <= 32'd0;
                    bank1_cfi_type_r <= 2'd0;
                    bank1_target_r <= 32'd0;
                    bank1_pred_taken_r <= 1'b0;
                    bank1_pred_target_r <= 32'd0;
                end else if (!redirect_valid && accept) begin
                    bank0_cfi_type_r <= accept_abtb_bank0_meta.cfi_type;
                    bank0_target_r <= accept_abtb_bank0_meta.target;
                    bank0_pred_taken_r <= accept_abtb_bank0_meta.pred_taken;
                    bank0_pred_target_r <= accept_abtb_bank0_meta.pred_target;
                    bank1_cfi_type_r <= accept_abtb_bank1_meta.cfi_type;
                    bank1_target_r <= accept_abtb_bank1_meta.target;
                    bank1_pred_taken_r <= accept_abtb_bank1_meta.pred_taken;
                    bank1_pred_target_r <= accept_abtb_bank1_meta.pred_target;
                end
            end
        end else begin : g_narrow_abtb_meta
            assign f0_abtb_bank0_meta.cfi_type = 2'd0;
            assign f0_abtb_bank0_meta.target = 32'd0;
            assign f0_abtb_bank0_meta.pred_taken = 1'b0;
            assign f0_abtb_bank0_meta.pred_target = 32'd0;
            assign f0_abtb_bank1_meta.cfi_type = 2'd0;
            assign f0_abtb_bank1_meta.target = 32'd0;
            assign f0_abtb_bank1_meta.pred_taken = 1'b0;
            assign f0_abtb_bank1_meta.pred_target = 32'd0;
        end
    endgenerate

endmodule
