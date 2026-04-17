// ============================================================
// Module: next_pc_mux
// Description: Next PC selection (pure combinational)
// Priority: EX Flush > ID Jump > IF Prediction > Stall > Sequential
// ============================================================

module next_pc_mux (
    input  logic [31:0] pc,
    input  logic [31:0] next_pc_seq,    // pc + 4

    // IF stage prediction (Phase 2+: BTB/RAS)
    input  logic        pred_taken,
    input  logic [31:0] pred_target,

    // ID stage redirection (Phase 1: JAL early resolution)
    input  logic        id_jump_taken,
    input  logic [31:0] id_jump_target,

    // EX stage redirection (Branch correction / JALR)
    input  logic        ex_branch_flush,
    input  logic [31:0] ex_branch_target,

    // Pipeline stall
    input  logic        if_allowin,

    output logic [31:0] irom_addr
);

    // Priority: EX Flush > ID Jump > IF Prediction > Stall > Sequential
    assign irom_addr = ex_branch_flush ? ex_branch_target :
                       id_jump_taken   ? id_jump_target   :
                       pred_taken      ? pred_target      :
                       !if_allowin     ? pc               :
                                         next_pc_seq;

endmodule
