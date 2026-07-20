// ============================================================
// Package: riscv_defs
// Description: RISC-V instruction encodings and field helpers.
// Domain: RISC-V ISA implementation only.
// ============================================================

package riscv_defs;

    localparam logic [6:0] OP_R_TYPE = 7'b0110011;
    localparam logic [6:0] OP_I_ALU  = 7'b0010011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_SYSTEM = 7'b1110011;
    localparam logic [6:0] OP_FENCE  = 7'b0001111;

    localparam logic [6:0] MULDIV_FUNCT7 = 7'b0000001;
    localparam logic [31:0] RISCV_ECALL = 32'h0000_0073;
    localparam logic [31:0] RISCV_EBREAK = 32'h0010_0073;
    localparam logic [31:0] RISCV_MRET = 32'h3020_0073;

    function automatic logic [31:0] imm_i(input logic [31:0] inst);
        imm_i = {{20{inst[31]}}, inst[31:20]};
    endfunction

    function automatic logic [31:0] imm_s(input logic [31:0] inst);
        imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    endfunction

    function automatic logic [31:0] imm_b(input logic [31:0] inst);
        imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25],
                 inst[11:8], 1'b0};
    endfunction

    function automatic logic [31:0] imm_u(input logic [31:0] inst);
        imm_u = {inst[31:12], 12'b0};
    endfunction

    function automatic logic [31:0] imm_j(input logic [31:0] inst);
        imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20],
                 inst[30:21], 1'b0};
    endfunction

    function automatic logic is_link_reg(input logic [4:0] reg_addr);
        is_link_reg = (reg_addr == 5'd1) | (reg_addr == 5'd5);
    endfunction

endpackage
