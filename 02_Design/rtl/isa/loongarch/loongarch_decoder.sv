// ============================================================
// Module: loongarch_decoder
// Description: LA32R integer plus basic privileged decoder.
// ============================================================

module loongarch_decoder
    import cpu_defs::*;
    import loongarch_defs::*;
(
    input  logic [31:0] inst,
    output decoded_uop_t uop
);

    wire [16:0] op17 = inst[31:15];
    wire [ 9:0] op10 = inst[31:22];
    wire [ 6:0] op7  = inst[31:25];
    wire [ 5:0] op6  = inst[31:26];
    wire [ 4:0] rd = inst[4:0];
    wire [ 4:0] rj = inst[9:5];
    wire [ 4:0] rk = inst[14:10];

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

    // LoongArch keeps CSR addressing and operand roles entirely separate from
    // RISC-V: CSR index is inst[23:10], rd supplies the write value, and rj is
    // the CSRXCHG mask.  ERTN is an exact fixed encoding.
    wire inst_csr     = inst[31:24] == 8'h04;
    wire inst_csrrd   = inst_csr & (rj == 5'd0);
    wire inst_csrwr   = inst_csr & (rj == 5'd1);
    wire inst_csrxchg = inst_csr & (rj != 5'd0) & (rj != 5'd1);
    wire inst_syscall = op17 == {6'h00, 4'h0, 2'h2, 5'h16};
    wire inst_break   = op17 == {6'h00, 4'h0, 2'h2, 5'h14};
    wire inst_ertn    = inst == 32'h0648_3800;
    wire inst_rdcntvl = (op17 == 17'd0) && (rk == 5'd24)
                       && (rj == 5'd0);
    wire inst_rdcntid = (op17 == 17'd0) && (rk == 5'd24)
                       && (rd == 5'd0);
    wire inst_rdcntvh = (op17 == 17'd0) && (rk == 5'd25)
                       && (rj == 5'd0);
    wire inst_counter = inst_rdcntvl | inst_rdcntid | inst_rdcntvh;

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
    wire src1_is_rd = is_store | is_conditional;
    wire jirl_call = inst_jirl & (rd == 5'd1);
    wire jirl_return = inst_jirl & (rd == 5'd0) & (rj == 5'd1)
                     & (la_imm_si16_shift2(inst) == 32'd0);

    always_comb begin
        // Unsupported encodings are contained as side-effect-free illegal uops.
        uop = '0;
        uop.exec_unit = EXEC_NONE;
        uop.src0_addr = rj;
        uop.src1_addr = src1_is_rd ? rd : rk;
        uop.dst_addr = inst_bl ? 5'd1 : rd;
        uop.operand_a_sel = OPERAND_A_SRC0;
        uop.operand_b_sel = OPERAND_B_SRC1;
        uop.alu_op = ALU_ADD;
        uop.wb_src = WB_NONE;
        uop.mem_cmd = MEM_NONE;
        uop.mem_size = MEM_WORD;
        uop.control_flow = CF_NONE;
        uop.branch_op = BR_NONE;
        uop.target_base = TARGET_PC;
        uop.cfi_type = CFI_TYPE_JUMP;
        uop.priv_op = PRIV_NONE;
        uop.priv_cmd = PRIV_CMD_NONE;
        uop.muldiv_op = MULDIV_MUL;
        uop.exception = EXCEPTION_ILLEGAL;
        uop.lane_mask = 2'b01;
        uop.block_younger = 1'b1;
        uop.serializing = 1'b1;

        if (inst_counter) begin
            uop.exec_unit = EXEC_PRIV;
            uop.dst_addr = inst_rdcntid ? rj : rd;
            uop.dst_write = 1'b1;
            uop.wb_src = WB_EXEC;
            uop.priv_op = PRIV_COUNTER;
            uop.priv_addr = inst_rdcntid ? 16'hffff
                          : inst_rdcntvh ? 16'hfffe : 16'hfffd;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b01;
            uop.block_younger = 1'b1;
            uop.serializing = 1'b1;
        end else if (inst_csr) begin
            uop.exec_unit = EXEC_PRIV;
            uop.src0_addr = rd;
            uop.src1_addr = rj;
            uop.src0_used = inst_csrwr | inst_csrxchg;
            uop.src1_used = inst_csrxchg;
            uop.dst_addr = rd;
            uop.dst_write = 1'b1;
            uop.wb_src = WB_EXEC;
            uop.priv_op = PRIV_REG;
            uop.priv_cmd = inst_csrrd ? PRIV_CMD_NONE
                         : inst_csrwr ? PRIV_CMD_WRITE
                                      : PRIV_CMD_EXCHANGE;
            uop.priv_addr = {2'd0, inst[23:10]};
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b01;
            uop.block_younger = 1'b1;
            uop.serializing = 1'b1;
        end else if (inst_syscall) begin
            uop.exec_unit = EXEC_PRIV;
            uop.priv_op = PRIV_SYSCALL;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b01;
            uop.block_younger = 1'b1;
            uop.serializing = 1'b1;
        end else if (inst_ertn) begin
            uop.exec_unit = EXEC_PRIV;
            uop.priv_op = PRIV_RETURN;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b01;
            uop.block_younger = 1'b1;
            uop.serializing = 1'b1;
        end else if (inst_break) begin
            uop.exec_unit = EXEC_PRIV;
            uop.exception = EXCEPTION_BREAKPOINT;
            uop.lane_mask = 2'b01;
            uop.block_younger = 1'b1;
            uop.serializing = 1'b1;
        end else if (is_alu_rr) begin
            uop.exec_unit = EXEC_ALU;
            uop.src0_used = 1'b1;
            uop.src1_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.wb_src = WB_EXEC;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;

            if (inst_sub_w)
                uop.alu_op = ALU_SUB;
            else if (inst_slt)
                uop.alu_op = ALU_SLT;
            else if (inst_sltu)
                uop.alu_op = ALU_SLTU;
            else if (inst_nor)
                uop.alu_op = ALU_NOR;
            else if (inst_and)
                uop.alu_op = ALU_AND;
            else if (inst_or)
                uop.alu_op = ALU_OR;
            else if (inst_xor)
                uop.alu_op = ALU_XOR;
            else if (inst_sll_w)
                uop.alu_op = ALU_SLL;
            else if (inst_srl_w)
                uop.alu_op = ALU_SRL;
            else if (inst_sra_w)
                uop.alu_op = ALU_SRA;
        end else if (is_alu_imm) begin
            uop.exec_unit = EXEC_ALU;
            uop.src0_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.wb_src = WB_EXEC;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;

            if (is_shift_imm)
                uop.imm = la_imm_ui5(inst);
            else if (inst_andi | inst_ori | inst_xori)
                uop.imm = la_imm_ui12(inst);
            else
                uop.imm = la_imm_si12(inst);

            if (inst_slti)
                uop.alu_op = ALU_SLT;
            else if (inst_sltui)
                uop.alu_op = ALU_SLTU;
            else if (inst_andi)
                uop.alu_op = ALU_AND;
            else if (inst_ori)
                uop.alu_op = ALU_OR;
            else if (inst_xori)
                uop.alu_op = ALU_XOR;
            else if (inst_slli_w)
                uop.alu_op = ALU_SLL;
            else if (inst_srli_w)
                uop.alu_op = ALU_SRL;
            else if (inst_srai_w)
                uop.alu_op = ALU_SRA;
        end else if (is_upper_imm) begin
            uop.exec_unit = EXEC_ALU;
            uop.dst_write = 1'b1;
            uop.operand_a_sel = inst_pcaddu12i ? OPERAND_A_PC
                                               : OPERAND_A_ZERO;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = la_imm_si20_shift12(inst);
            uop.wb_src = WB_EXEC;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (is_muldiv) begin
            uop.exec_unit = EXEC_MULDIV;
            uop.src0_used = 1'b1;
            uop.src1_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.wb_src = WB_EXEC;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b01;
            uop.block_younger = is_divmod;
            uop.serializing = is_divmod;

            if (inst_mulh_w)
                uop.muldiv_op = MULDIV_MULH;
            else if (inst_mulh_wu)
                uop.muldiv_op = MULDIV_MULHU;
            else if (inst_div_w)
                uop.muldiv_op = MULDIV_DIV;
            else if (inst_div_wu)
                uop.muldiv_op = MULDIV_DIVU;
            else if (inst_mod_w)
                uop.muldiv_op = MULDIV_REM;
            else if (inst_mod_wu)
                uop.muldiv_op = MULDIV_REMU;
        end else if (is_load) begin
            uop.exec_unit = EXEC_LSU;
            uop.src0_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = la_imm_si12(inst);
            uop.wb_src = WB_LOAD;
            uop.mem_cmd = MEM_LOAD;
            uop.mem_size = (inst_ld_b | inst_ld_bu) ? MEM_BYTE
                          : (inst_ld_h | inst_ld_hu) ? MEM_HALF
                                                    : MEM_WORD;
            uop.mem_unsigned = inst_ld_bu | inst_ld_hu;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (is_store) begin
            uop.exec_unit = EXEC_LSU;
            uop.src0_used = 1'b1;
            uop.src1_used = 1'b1;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = la_imm_si12(inst);
            uop.mem_cmd = MEM_STORE;
            uop.mem_size = inst_st_b ? MEM_BYTE
                          : inst_st_h ? MEM_HALF
                                      : MEM_WORD;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (is_conditional) begin
            uop.exec_unit = EXEC_BRANCH;
            uop.src0_used = 1'b1;
            uop.src1_used = 1'b1;
            uop.operand_a_sel = OPERAND_A_PC;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = la_imm_si16_shift2(inst);
            uop.control_flow = CF_CONDITIONAL;
            uop.target_base = TARGET_PC;
            uop.cfi_update = 1'b1;
            uop.cfi_type = CFI_TYPE_BRANCH;
            uop.branch_op = inst_beq ? BR_EQ
                           : inst_bne ? BR_NE
                           : inst_blt ? BR_LT
                           : inst_bge ? BR_GE
                           : inst_bltu ? BR_LTU
                                       : BR_GEU;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (is_direct) begin
            uop.exec_unit = EXEC_BRANCH;
            uop.dst_write = inst_bl;
            uop.operand_a_sel = OPERAND_A_PC;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = la_imm_si26_shift2(inst);
            uop.wb_src = inst_bl ? WB_NEXT_PC : WB_NONE;
            uop.control_flow = CF_DIRECT;
            uop.branch_op = BR_ALWAYS;
            uop.target_base = TARGET_PC;
            uop.cfi_update = 1'b1;
            uop.cfi_type = inst_bl ? CFI_TYPE_CALL : CFI_TYPE_JUMP;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (inst_jirl) begin
            uop.exec_unit = EXEC_BRANCH;
            uop.src0_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = la_imm_si16_shift2(inst);
            uop.wb_src = WB_NEXT_PC;
            uop.control_flow = CF_INDIRECT;
            uop.branch_op = BR_ALWAYS;
            uop.target_base = TARGET_SRC0;
            // LA32R does not clear target bit 0; ADEF belongs to the later
            // exception phase.
            uop.target_clear_mask = 2'b00;
            uop.cfi_update = jirl_call | jirl_return;
            uop.cfi_type = jirl_return ? CFI_TYPE_RETURN
                          : jirl_call ? CFI_TYPE_CALL
                                      : CFI_TYPE_JUMP;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b1;
            uop.serializing = 1'b0;
        end

    end

endmodule

// The common core instantiates this selected implementation name. Filelists
// compile exactly one ISA adapter, so the core itself remains ISA-neutral.
module isa_decoder
    import cpu_defs::*;
(
    input  logic [31:0] inst,
    output decoded_uop_t uop
);
    loongarch_decoder u_impl (
        .inst (inst),
        .uop  (uop)
    );
endmodule
