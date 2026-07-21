// ============================================================
// Package: loongarch_defs
// Description: LA32R ordinary integer encodings and field helpers.
// Source: LoongArch32 Reduced Manual V1.04, Appendix B.
// ============================================================

package loongarch_defs;

    // Register-register and shift-immediate encodings use inst[31:15].
    localparam logic [16:0] LA_OP_ADD_W   = {6'h00, 4'h0, 2'h1, 5'h00};
    localparam logic [16:0] LA_OP_SUB_W   = {6'h00, 4'h0, 2'h1, 5'h02};
    localparam logic [16:0] LA_OP_SLT     = {6'h00, 4'h0, 2'h1, 5'h04};
    localparam logic [16:0] LA_OP_SLTU    = {6'h00, 4'h0, 2'h1, 5'h05};
    localparam logic [16:0] LA_OP_NOR     = {6'h00, 4'h0, 2'h1, 5'h08};
    localparam logic [16:0] LA_OP_AND     = {6'h00, 4'h0, 2'h1, 5'h09};
    localparam logic [16:0] LA_OP_OR      = {6'h00, 4'h0, 2'h1, 5'h0a};
    localparam logic [16:0] LA_OP_XOR     = {6'h00, 4'h0, 2'h1, 5'h0b};
    localparam logic [16:0] LA_OP_SLL_W   = {6'h00, 4'h0, 2'h1, 5'h0e};
    localparam logic [16:0] LA_OP_SRL_W   = {6'h00, 4'h0, 2'h1, 5'h0f};
    localparam logic [16:0] LA_OP_SRA_W   = {6'h00, 4'h0, 2'h1, 5'h10};
    localparam logic [16:0] LA_OP_MUL_W   = {6'h00, 4'h0, 2'h1, 5'h18};
    localparam logic [16:0] LA_OP_MULH_W  = {6'h00, 4'h0, 2'h1, 5'h19};
    localparam logic [16:0] LA_OP_MULH_WU = {6'h00, 4'h0, 2'h1, 5'h1a};
    localparam logic [16:0] LA_OP_DIV_W   = {6'h00, 4'h0, 2'h2, 5'h00};
    localparam logic [16:0] LA_OP_MOD_W   = {6'h00, 4'h0, 2'h2, 5'h01};
    localparam logic [16:0] LA_OP_DIV_WU  = {6'h00, 4'h0, 2'h2, 5'h02};
    localparam logic [16:0] LA_OP_MOD_WU  = {6'h00, 4'h0, 2'h2, 5'h03};
    localparam logic [16:0] LA_OP_SLLI_W  = {6'h00, 4'h1, 2'h0, 5'h01};
    localparam logic [16:0] LA_OP_SRLI_W  = {6'h00, 4'h1, 2'h0, 5'h09};
    localparam logic [16:0] LA_OP_SRAI_W  = {6'h00, 4'h1, 2'h0, 5'h11};

    // Twelve-bit immediate and ordinary load/store encodings use inst[31:22].
    localparam logic [9:0] LA_OP_SLTI    = {6'h00, 4'h8};
    localparam logic [9:0] LA_OP_SLTUI   = {6'h00, 4'h9};
    localparam logic [9:0] LA_OP_ADDI_W  = {6'h00, 4'ha};
    localparam logic [9:0] LA_OP_ANDI    = {6'h00, 4'hd};
    localparam logic [9:0] LA_OP_ORI     = {6'h00, 4'he};
    localparam logic [9:0] LA_OP_XORI    = {6'h00, 4'hf};
    localparam logic [9:0] LA_OP_LD_B    = {6'h0a, 4'h0};
    localparam logic [9:0] LA_OP_LD_H    = {6'h0a, 4'h1};
    localparam logic [9:0] LA_OP_LD_W    = {6'h0a, 4'h2};
    localparam logic [9:0] LA_OP_ST_B    = {6'h0a, 4'h4};
    localparam logic [9:0] LA_OP_ST_H    = {6'h0a, 4'h5};
    localparam logic [9:0] LA_OP_ST_W    = {6'h0a, 4'h6};
    localparam logic [9:0] LA_OP_LD_BU   = {6'h0a, 4'h8};
    localparam logic [9:0] LA_OP_LD_HU   = {6'h0a, 4'h9};

    // Upper-immediate encodings use inst[31:25].
    localparam logic [6:0] LA_OP_LU12I_W   = {6'h05, 1'b0};
    localparam logic [6:0] LA_OP_PCADDU12I = {6'h07, 1'b0};

    // Control-flow encodings use inst[31:26].
    localparam logic [5:0] LA_OP_JIRL = 6'h13;
    localparam logic [5:0] LA_OP_B    = 6'h14;
    localparam logic [5:0] LA_OP_BL   = 6'h15;
    localparam logic [5:0] LA_OP_BEQ  = 6'h16;
    localparam logic [5:0] LA_OP_BNE  = 6'h17;
    localparam logic [5:0] LA_OP_BLT  = 6'h18;
    localparam logic [5:0] LA_OP_BGE  = 6'h19;
    localparam logic [5:0] LA_OP_BLTU = 6'h1a;
    localparam logic [5:0] LA_OP_BGEU = 6'h1b;

    function automatic logic [31:0] la_imm_si12(
        input logic [31:0] inst
    );
        la_imm_si12 = {{20{inst[21]}}, inst[21:10]};
    endfunction

    function automatic logic [31:0] la_imm_ui12(
        input logic [31:0] inst
    );
        la_imm_ui12 = {20'd0, inst[21:10]};
    endfunction

    function automatic logic [31:0] la_imm_ui5(
        input logic [31:0] inst
    );
        la_imm_ui5 = {27'd0, inst[14:10]};
    endfunction

    function automatic logic [31:0] la_imm_si16_shift2(
        input logic [31:0] inst
    );
        la_imm_si16_shift2 = {{14{inst[25]}}, inst[25:10], 2'b00};
    endfunction

    function automatic logic [31:0] la_imm_si20_shift12(
        input logic [31:0] inst
    );
        la_imm_si20_shift12 = {inst[24:5], 12'b0};
    endfunction

    function automatic logic [31:0] la_imm_si26_shift2(
        input logic [31:0] inst
    );
        la_imm_si26_shift2 = {{4{inst[9]}}, inst[9:0],
                              inst[25:10], 2'b00};
    endfunction

endpackage
