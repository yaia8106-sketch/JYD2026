// ============================================================
// Module: next_pc_mux
// Description: Next PC selection (pure combinational)
// Currently: PC + 4 (no branch prediction)
// Future: add bp_taken / bp_target inputs
// ============================================================

module next_pc_mux (
    input  logic [31:0] pc,
    input  logic [31:0] next_pc_seq,    // pc + 4

    // ID stage redirection (Phase 1: JAL)
    input  logic        id_jump_taken,
    input  logic [31:0] id_jump_target,

    // EX stage redirection (Branch correction / JALR)
    input  logic        ex_branch_flush,
    input  logic [31:0] ex_branch_target,

    // Pipeline stall
    input  logic        if_allowin,

    output logic [31:0] irom_addr
);

    // Priority: EX Flush > ID Jump > Stall > Sequential
    assign irom_addr = ex_branch_flush ? ex_branch_target :
                       id_jump_taken   ? id_jump_target   :
                       !if_allowin     ? pc               :
                                         next_pc_seq;

endmodule
