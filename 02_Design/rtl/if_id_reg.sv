// ============================================================
// Module: if_id_reg
// Description: IF/ID pipeline register (stores PC + slot0/slot1 instructions + prediction)
// Spec: 02_Design/spec/if_id_reg_spec.md
// Note: Instruction captured from BRAM output in IF stage
// NLP: added bp_btb_type, removed bp_btb_way
// ============================================================

module if_id_reg (
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        if_valid,
    input  logic        if_ready_go,
    output logic        id_allowin,
    output logic        id_valid,
    input  logic        id_ready_go,
    input  logic        ex_allowin,

    // Flush
    input  logic        id_flush,

    // Data
    input  logic [31:0] if_pc,
    input  logic [31:0] if_inst,       // slot0 instruction, valid in IF stage
    input  logic [31:0] if_inst1,      // slot1 candidate instruction
    input  logic        if_s1_valid,   // slot1 issue valid (Phase 1: hardwired 0)
    output logic [31:0] id_pc,
    output logic [31:0] id_inst,       // registered instruction for ID stage
    output logic [31:0] id_inst1,      // registered slot1 candidate instruction
    output logic        id_s1_valid,   // registered slot1 issue valid

    // Branch prediction signals (IF → ID passthrough)
    input  logic        if_bp_taken,
    input  logic [31:0] if_bp_target,
    input  logic [ 7:0] if_bp_ghr_snap,
    input  logic        if_bp_btb_hit,
    input  logic [ 1:0] if_bp_btb_type,    // NLP: entry type for ID verification
    input  logic [ 1:0] if_bp_btb_bht,
    input  logic [ 1:0] if_bp_pht_cnt,
    input  logic [ 1:0] if_bp_sel_cnt,
    output logic        id_bp_taken,
    output logic [31:0] id_bp_target,
    output logic [ 7:0] id_bp_ghr_snap,
    output logic        id_bp_btb_hit,
    output logic [ 1:0] id_bp_btb_type,    // NLP: entry type for ID verification
    output logic [ 1:0] id_bp_btb_bht,
    output logic [ 1:0] id_bp_pht_cnt,
    output logic [ 1:0] id_bp_sel_cnt
);

    // ---- Handshake ----
    assign id_allowin = !id_valid || (id_ready_go & ex_allowin);

    // ---- Pipeline register ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_valid        <= 1'b0;
            id_pc           <= 32'd0;
            id_inst         <= 32'd0;
            id_inst1        <= 32'd0;
            id_s1_valid     <= 1'b0;
            id_bp_taken     <= 1'b0;
            id_bp_target    <= 32'd0;
            id_bp_ghr_snap  <= 8'd0;
            id_bp_btb_hit   <= 1'b0;
            id_bp_btb_type  <= 2'd0;
            id_bp_btb_bht   <= 2'd0;
            id_bp_pht_cnt   <= 2'd0;
            id_bp_sel_cnt   <= 2'd0;
        end else if (id_flush) begin
            id_valid        <= 1'b0;
            id_s1_valid     <= 1'b0;
        end else if (id_allowin) begin
            id_valid        <= if_valid & if_ready_go;
            id_pc           <= if_pc;
            id_inst         <= if_inst;
            id_inst1        <= if_inst1;
            id_s1_valid     <= if_valid & if_ready_go & if_s1_valid;
            id_bp_taken     <= if_bp_taken;
            id_bp_target    <= if_bp_target;
            id_bp_ghr_snap  <= if_bp_ghr_snap;
            id_bp_btb_hit   <= if_bp_btb_hit;
            id_bp_btb_type  <= if_bp_btb_type;
            id_bp_btb_bht   <= if_bp_btb_bht;
            id_bp_pht_cnt   <= if_bp_pht_cnt;
            id_bp_sel_cnt   <= if_bp_sel_cnt;
        end
    end

endmodule
