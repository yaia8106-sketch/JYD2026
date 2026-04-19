// ============================================================
// Module: next_pc_mux
// Description: Next PC selection (pure combinational)
//   With branch prediction: next_pc = bp_taken ? bp_target : pc + 4
// ============================================================

module next_pc_mux (
    input  logic [31:0] pc,
    input  logic        bp_taken,
    input  logic [31:0] bp_target,
    output logic [31:0] next_pc
);

    assign next_pc = bp_taken ? bp_target : (pc + 32'd4);

endmodule
