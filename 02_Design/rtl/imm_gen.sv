// ============================================================
// Module: imm_gen
// Description: Immediate generator for RV32I (5 formats)
// Spec: 02_Design/spec/imm_gen_spec.md
// Implementation: parallel AND-OR MUX, no case statement
// ============================================================

module imm_gen
    import cpu_defs::*;
(
    input  logic [31:0] inst,
    input  logic [ 2:0] imm_type,
    output logic [31:0] imm
);

    // ---- Parallel decode ----
    wire sel_i = (imm_type == IMM_I);
    wire sel_s = (imm_type == IMM_S);
    wire sel_b = (imm_type == IMM_B);
    wire sel_u = (imm_type == IMM_U);
    wire sel_j = (imm_type == IMM_J);

    // ---- Parallel immediate generation ----
    wire [31:0] imm_i = {{20{inst[31]}}, inst[31:20]};
    wire [31:0] imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] imm_u = {inst[31:12], 12'b0};
    wire [31:0] imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

    // ---- AND-OR MUX ----
    assign imm = ({32{sel_i}} & imm_i)
               | ({32{sel_s}} & imm_s)
               | ({32{sel_b}} & imm_b)
               | ({32{sel_u}} & imm_u)
               | ({32{sel_j}} & imm_j);

endmodule
