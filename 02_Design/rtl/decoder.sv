// ============================================================
// Module: decoder
// Description: RV32I instruction decoder (pure combinational)
// Spec: 02_Design/spec/decoder_spec.md
// Style: packed constant LUT + funct3/funct7 passthrough
// ============================================================

module decoder
    import cpu_defs::*;
(
    input  logic [31:0] inst,

    output logic [ 3:0] alu_op,
    output logic [ 1:0] alu_src1_sel,
    output logic        alu_src2_sel,
    output logic        reg_write_en,
    output logic [ 1:0] wb_sel,
    output logic        mem_read_en,
    output logic        mem_write_en,
    output logic [ 1:0] mem_size,
    output logic        mem_unsigned,
    output logic        is_branch,
    output logic [ 2:0] branch_cond,
    output logic        is_jal,
    output logic        is_jalr,
    output logic [ 2:0] imm_type
);

    // ---- Field extraction ----
    wire [6:0] opcode  = inst[6:0];
    wire [2:0] funct3  = inst[14:12];
    wire       funct7_5 = inst[30];

    // ================================================================
    // Packed control word (opcode-dependent, constant per instruction type)
    // ================================================================
    //
    // Bit layout:
    //   [13:12] alu_src1_sel    00=rs1, 01=PC, 10=zero
    //   [11]    alu_src2_sel    0=rs2, 1=imm
    //   [10]    reg_write_en
    //   [9:8]   wb_sel          00=ALU, 01=DRAM, 10=PC+4
    //   [7]     mem_read_en
    //   [6]     mem_write_en
    //   [5]     is_branch
    //   [4]     is_jal
    //   [3]     is_jalr
    //   [2:0]   imm_type
    //
    //                                     src1  src2  regW    wb   memR  memW  brch  jal   jalr  imm_type
    localparam logic [13:0] DEC_R_TYPE = {2'b00, 1'b0, 1'b1, 2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 3'b000};
    localparam logic [13:0] DEC_I_ALU  = {2'b00, 1'b1, 1'b1, 2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, IMM_I };
    localparam logic [13:0] DEC_LOAD   = {2'b00, 1'b1, 1'b1, 2'b01, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, IMM_I };
    localparam logic [13:0] DEC_STORE  = {2'b00, 1'b1, 1'b0, 2'b00, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, IMM_S };
    localparam logic [13:0] DEC_BRANCH = {2'b01, 1'b1, 1'b0, 2'b00, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, IMM_B };
    localparam logic [13:0] DEC_LUI    = {2'b10, 1'b1, 1'b1, 2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, IMM_U };
    localparam logic [13:0] DEC_AUIPC  = {2'b01, 1'b1, 1'b1, 2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, IMM_U };
    localparam logic [13:0] DEC_JAL    = {2'b01, 1'b1, 1'b1, 2'b10, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, IMM_J };
    localparam logic [13:0] DEC_JALR   = {2'b00, 1'b1, 1'b1, 2'b10, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, IMM_I };
    localparam logic [13:0] DEC_INVALID= {2'b00, 1'b0, 1'b0, 2'b00, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 3'b000};

    // ---- Opcode → control word LUT ----
    logic [13:0] ctrl_word;

    always_comb begin
        case (opcode)
            OP_R_TYPE: ctrl_word = DEC_R_TYPE;
            OP_I_ALU:  ctrl_word = DEC_I_ALU;
            OP_LOAD:   ctrl_word = DEC_LOAD;
            OP_STORE:  ctrl_word = DEC_STORE;
            OP_BRANCH: ctrl_word = DEC_BRANCH;
            OP_LUI:    ctrl_word = DEC_LUI;
            OP_AUIPC:  ctrl_word = DEC_AUIPC;
            OP_JAL:    ctrl_word = DEC_JAL;
            OP_JALR:   ctrl_word = DEC_JALR;
            default:   ctrl_word = DEC_INVALID;
        endcase
    end

    // ---- Unpack control word ----
    assign {alu_src1_sel, alu_src2_sel, reg_write_en, wb_sel,
            mem_read_en, mem_write_en, is_branch, is_jal, is_jalr,
            imm_type} = ctrl_word;

    // ================================================================
    // Signals that depend on funct3 / funct7 (not constant per opcode)
    // ================================================================

    // ---- alu_op: {funct7[5], funct3} passthrough ----
    // R-type: always use funct7[5]
    // I-type ALU: funct7[5] only for shifts (funct3 == 3'b101, distinguishes SRLI/SRAI)
    // Others: ALU_ADD (for address calc, LUI passthrough, etc.)
    wire is_alu_inst = (opcode == OP_R_TYPE) | (opcode == OP_I_ALU);
    wire use_funct7  = (opcode == OP_R_TYPE) | ((opcode == OP_I_ALU) & (funct3 == 3'b101));

    assign alu_op = is_alu_inst ? {use_funct7 & funct7_5, funct3} : ALU_ADD;

    // ---- funct3 passthrough (always valid, gated by downstream logic) ----
    assign mem_size     = funct3[1:0];
    assign mem_unsigned = funct3[2];
    assign branch_cond  = funct3;

endmodule
