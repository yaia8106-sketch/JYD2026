// ============================================================
// Module: next_pc_mux
// Description: Next PC selection (pure combinational)
// Currently: PC + 4 (no branch prediction)
// Future: add bp_taken / bp_target inputs
// ============================================================

module next_pc_mux (
    input  logic [31:0] pc,
    output logic [31:0] next_pc
);

    assign next_pc = pc + 32'd4;

endmodule
