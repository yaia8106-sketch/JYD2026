// ============================================================
// Package: cpu_defs
// Description: 全局常量定义，供所有模块共享
// ============================================================

package cpu_defs;

    // ---- ALU 操作编码: {funct7[5], funct3} ----
    localparam logic [3:0] ALU_ADD  = 4'b0_000;
    localparam logic [3:0] ALU_SUB  = 4'b1_000;
    localparam logic [3:0] ALU_SLL  = 4'b0_001;
    localparam logic [3:0] ALU_SLT  = 4'b0_010;
    localparam logic [3:0] ALU_SLTU = 4'b0_011;
    localparam logic [3:0] ALU_XOR  = 4'b0_100;
    localparam logic [3:0] ALU_SRL  = 4'b0_101;
    localparam logic [3:0] ALU_SRA  = 4'b1_101;
    localparam logic [3:0] ALU_OR   = 4'b0_110;
    localparam logic [3:0] ALU_AND  = 4'b0_111;

    // ---- 立即数类型编码 ----
    localparam logic [2:0] IMM_I = 3'b000;
    localparam logic [2:0] IMM_S = 3'b001;
    localparam logic [2:0] IMM_B = 3'b010;
    localparam logic [2:0] IMM_U = 3'b011;
    localparam logic [2:0] IMM_J = 3'b100;

    // ---- RV32I opcode 编码 ----
    localparam logic [6:0] OP_R_TYPE = 7'b0110011;
    localparam logic [6:0] OP_I_ALU  = 7'b0010011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;

endpackage
