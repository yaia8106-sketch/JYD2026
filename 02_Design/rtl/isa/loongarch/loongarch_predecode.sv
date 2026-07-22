// ============================================================
// Module: loongarch_predecode
// Description: Shallow LA32R classification for fetch/pairing policy.
// ============================================================

module loongarch_predecode
    import cpu_defs::*;
    import loongarch_defs::*;
(
    input  logic [31:0]         inst,
    output frontend_predecode_t decoded
);

    wire [16:0] op17 = inst[31:15];
    wire [ 9:0] op10 = inst[31:22];
    wire [ 6:0] op7  = inst[31:25];
    wire [ 5:0] op6  = inst[31:26];

    wire inst_add_w   = op17 == LA_OP_ADD_W;
    wire inst_sub_w   = op17 == LA_OP_SUB_W;
    wire inst_slt     = op17 == LA_OP_SLT;
    wire inst_sltu    = op17 == LA_OP_SLTU;
    wire inst_nor     = op17 == LA_OP_NOR;
    wire inst_and     = op17 == LA_OP_AND;
    wire inst_or      = op17 == LA_OP_OR;
    wire inst_xor     = op17 == LA_OP_XOR;
    wire inst_sll_w   = op17 == LA_OP_SLL_W;
    wire inst_srl_w   = op17 == LA_OP_SRL_W;
    wire inst_sra_w   = op17 == LA_OP_SRA_W;
    wire inst_mul_w   = op17 == LA_OP_MUL_W;
    wire inst_mulh_w  = op17 == LA_OP_MULH_W;
    wire inst_mulh_wu = op17 == LA_OP_MULH_WU;
    wire inst_div_w   = op17 == LA_OP_DIV_W;
    wire inst_mod_w   = op17 == LA_OP_MOD_W;
    wire inst_div_wu  = op17 == LA_OP_DIV_WU;
    wire inst_mod_wu  = op17 == LA_OP_MOD_WU;
    wire inst_slli_w  = op17 == LA_OP_SLLI_W;
    wire inst_srli_w  = op17 == LA_OP_SRLI_W;
    wire inst_srai_w  = op17 == LA_OP_SRAI_W;

    wire inst_slti   = op10 == LA_OP_SLTI;
    wire inst_sltui  = op10 == LA_OP_SLTUI;
    wire inst_addi_w = op10 == LA_OP_ADDI_W;
    wire inst_andi   = op10 == LA_OP_ANDI;
    wire inst_ori    = op10 == LA_OP_ORI;
    wire inst_xori   = op10 == LA_OP_XORI;
    wire inst_ld_b   = op10 == LA_OP_LD_B;
    wire inst_ld_h   = op10 == LA_OP_LD_H;
    wire inst_ld_w   = op10 == LA_OP_LD_W;
    wire inst_st_b   = op10 == LA_OP_ST_B;
    wire inst_st_h   = op10 == LA_OP_ST_H;
    wire inst_st_w   = op10 == LA_OP_ST_W;
    wire inst_ld_bu  = op10 == LA_OP_LD_BU;
    wire inst_ld_hu  = op10 == LA_OP_LD_HU;

    wire inst_lu12i_w   = op7 == LA_OP_LU12I_W;
    wire inst_pcaddu12i = op7 == LA_OP_PCADDU12I;

    wire inst_jirl = op6 == LA_OP_JIRL;
    wire inst_b    = op6 == LA_OP_B;
    wire inst_bl   = op6 == LA_OP_BL;
    wire inst_beq  = op6 == LA_OP_BEQ;
    wire inst_bne  = op6 == LA_OP_BNE;
    wire inst_blt  = op6 == LA_OP_BLT;
    wire inst_bge  = op6 == LA_OP_BGE;
    wire inst_bltu = op6 == LA_OP_BLTU;
    wire inst_bgeu = op6 == LA_OP_BGEU;

    wire inst_csr     = inst[31:24] == 8'h04;
    wire inst_csrwr   = inst_csr & (inst[9:5] == 5'd1);
    wire inst_csrxchg = inst_csr & (inst[9:5] != 5'd0)
                                & (inst[9:5] != 5'd1);
    wire inst_syscall = op17 == {6'h00, 4'h0, 2'h2, 5'h16};
    wire inst_break   = op17 == {6'h00, 4'h0, 2'h2, 5'h14};
    wire inst_ertn    = inst == 32'h0648_3800;
    wire inst_rdcntvl = (op17 == 17'd0) && (inst[14:10] == 5'd24)
                       && (inst[9:5] == 5'd0);
    wire inst_rdcntid = (op17 == 17'd0) && (inst[14:10] == 5'd24)
                       && (inst[4:0] == 5'd0);
    wire inst_rdcntvh = (op17 == 17'd0) && (inst[14:10] == 5'd25)
                       && (inst[9:5] == 5'd0);
    wire inst_counter = inst_rdcntvl | inst_rdcntid | inst_rdcntvh;
    wire is_privileged = inst_csr | inst_syscall | inst_ertn | inst_break
                       | inst_counter;
    wire privileged_flow_encoding = inst_syscall | inst_ertn | inst_break;

    wire is_alu_rr = inst_add_w | inst_sub_w | inst_slt | inst_sltu
                   | inst_nor | inst_and | inst_or | inst_xor
                   | inst_sll_w | inst_srl_w | inst_sra_w;
    wire is_shift_imm = inst_slli_w | inst_srli_w | inst_srai_w;
    wire is_alu_imm = inst_slti | inst_sltui | inst_addi_w
                    | inst_andi | inst_ori | inst_xori | is_shift_imm;
    wire is_upper_imm = inst_lu12i_w | inst_pcaddu12i;
    wire is_mul = inst_mul_w | inst_mulh_w | inst_mulh_wu;
    wire is_divmod = inst_div_w | inst_mod_w | inst_div_wu | inst_mod_wu;
    wire is_muldiv = is_mul | is_divmod;
    wire is_load = inst_ld_b | inst_ld_h | inst_ld_w
                 | inst_ld_bu | inst_ld_hu;
    wire is_store = inst_st_b | inst_st_h | inst_st_w;
    wire is_conditional = inst_beq | inst_bne | inst_blt | inst_bge
                        | inst_bltu | inst_bgeu;
    wire is_direct = inst_b | inst_bl;
    wire instruction_legal = is_alu_rr | is_alu_imm | is_upper_imm
                           | is_muldiv | is_load | is_store
                           | is_conditional | is_direct | inst_jirl
                           | is_privileged | inst_break;
    wire instruction_illegal = ~instruction_legal;
    wire is_privileged_flow = privileged_flow_encoding
                            | instruction_illegal;
    wire uses_rd_as_src1 = is_store | is_conditional;

    // Keep the late pairing controls independent from the full legality
    // reduction.  Each set below is the exact complement of the classes that
    // must be restricted for that output, so the IROM -> FQ path does not
    // traverse "all legal" and then re-add exceptional classes serially.
    wire slot1_allowed = is_alu_rr | is_alu_imm | is_upper_imm
                       | is_load | is_store | is_conditional
                       | is_direct | inst_jirl;
    wire younger_allowed = is_alu_rr | is_alu_imm | is_upper_imm
                         | is_mul | is_load | is_store
                         | is_conditional | is_direct;
    wire nonserializing_legal = younger_allowed | inst_jirl;

    always_comb begin
        decoded = '0;

        decoded.is_conditional_branch = is_conditional;
        decoded.is_direct_jump = is_direct;
        decoded.is_indirect_jump = inst_jirl;
        decoded.is_privileged = is_privileged;
        decoded.is_privileged_flow = is_privileged_flow;
        decoded.is_illegal = instruction_illegal;
        decoded.is_muldiv = is_muldiv;
        decoded.is_mul = is_mul;
        decoded.is_load = is_load;
        decoded.is_store = is_store;
        decoded.is_alu_type = is_alu_rr | is_alu_imm | is_upper_imm;

        decoded.writes_dst = is_alu_rr | is_alu_imm | is_upper_imm
                           | is_muldiv | is_load | inst_bl | inst_jirl
                           | inst_csr | inst_counter;
        decoded.uses_src0 = is_alu_rr | is_alu_imm | is_muldiv
                          | is_load | is_store | is_conditional | inst_jirl
                          | inst_csrwr | inst_csrxchg;
        decoded.uses_src1 = is_alu_rr | is_muldiv
                          | is_store | is_conditional | inst_csrxchg;
        decoded.src0_addr = inst_csr ? inst[4:0] : inst[9:5];
        decoded.src1_addr = inst_csr ? inst[9:5]
                          : uses_rd_as_src1 ? inst[4:0] : inst[14:10];
        decoded.dst_addr = inst_bl ? 5'd1
                         : inst_rdcntid ? inst[9:5] : inst[4:0];

        decoded.is_jump = is_direct | inst_jirl | is_privileged_flow;
        decoded.is_control = is_conditional | is_direct | inst_jirl
                           | is_privileged_flow;
        decoded.is_lsu = is_load | is_store;
        // Privileged redirects are serialized by their own metadata and must
        // not train or occupy the ordinary branch-predictor CFI path.
        decoded.is_cfi = is_conditional | is_direct | inst_jirl;

        decoded.lane_mask = slot1_allowed ? 2'b11 : 2'b01;
        decoded.block_younger = ~younger_allowed;
        decoded.serializing = ~nonserializing_legal;
    end

endmodule

module isa_predecode
    import cpu_defs::*;
(
    input  logic [31:0]         inst,
    output frontend_predecode_t decoded
);
    loongarch_predecode u_impl (
        .inst    (inst),
        .decoded (decoded)
    );
endmodule
