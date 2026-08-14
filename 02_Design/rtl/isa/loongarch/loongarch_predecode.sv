// ============================================================
// 中文说明：在 ICache refill 或前端取指阶段提取 LoongArch 指令类别和配对属性。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：loongarch_predecode。
// 说明：为取指和配对策略提供浅层 LA32R 指令分类。
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
    wire inst_cpucfg = (op17 == 17'd0) && (inst[14:10] == 5'd27);
    wire is_privileged = inst_csr | inst_syscall | inst_ertn | inst_break
                       | inst_counter | inst_cpucfg;
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

    // 让末级配对控制与完整合法性归约相互独立。下面每个集合都是该输出
    // 必须限制的类别补集，因此 IROM -> FQ 路径不必先经过“全部合法”判断，
    // 再串行添加例外类别。
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
                           | inst_csr | inst_counter | inst_cpucfg;
        decoded.uses_src0 = is_alu_rr | is_alu_imm | is_muldiv
                          | is_load | is_store | is_conditional | inst_jirl
                          | inst_csrwr | inst_csrxchg | inst_cpucfg;
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
        // 特权重定向由自身元数据串行化，不能训练或占用普通分支预测器 CFI 路径。
        decoded.is_cfi = is_conditional | is_direct | inst_jirl;

        decoded.lane_mask = slot1_allowed ? 2'b11 : 2'b01;
        decoded.block_younger = ~younger_allowed;
        decoded.serializing = ~nonserializing_legal;
    end

endmodule

// 只有 ICache refill block 完成时才生成精确元数据。
// 打包的 7 位记录在物理上拆分到 RAMB36 parity 和缩短 tag LUTRAM，
// 但在到达 F0 前会重新拼接。
module loongarch_icache_predecode
    import cpu_defs::*;
(
    input  logic [31:0]                  inst,
    output frontend_icache_predecode_t   metadata
);
    frontend_predecode_t decoded;

    wire [16:0] op17 = inst[31:15];
    wire inst_csr = inst[31:24] == 8'h04;
    wire inst_rdcntid = (op17 == 17'd0)
                       && (inst[14:10] == 5'd24)
                       && (inst[4:0] == 5'd0);
    wire inst_counter = ((op17 == 17'd0)
                         && (inst[14:10] == 5'd24)
                         && (inst[9:5] == 5'd0))
                      || ((op17 == 17'd0)
                          && (inst[14:10] == 5'd25)
                          && (inst[9:5] == 5'd0));
    wire inst_cpucfg = (op17 == 17'd0) && (inst[14:10] == 5'd27);

    loongarch_predecode u_predecode (
        .inst    (inst),
        .decoded (decoded)
    );

    always_comb begin
        metadata = '0;
        metadata.block_younger = decoded.block_younger;
        metadata.writes_dst = decoded.writes_dst;

        if (decoded.is_alu_type && decoded.uses_src0 && decoded.uses_src1)
            metadata.inst_kind = ICACHE_KIND_ALU_RR;
        else if (decoded.is_alu_type && decoded.uses_src0)
            metadata.inst_kind = ICACHE_KIND_ALU_IMM;
        else if (decoded.is_alu_type)
            metadata.inst_kind = ICACHE_KIND_UPPER_IMM;
        else if (decoded.is_load)
            metadata.inst_kind = ICACHE_KIND_LOAD;
        else if (decoded.is_store)
            metadata.inst_kind = ICACHE_KIND_STORE;
        else if (decoded.is_mul)
            metadata.inst_kind = ICACHE_KIND_MUL;
        else if (decoded.is_muldiv)
            metadata.inst_kind = ICACHE_KIND_DIVMOD;
        else if (decoded.is_conditional_branch)
            metadata.inst_kind = ICACHE_KIND_CONDITIONAL;
        else if (decoded.is_direct_jump && decoded.writes_dst)
            metadata.inst_kind = ICACHE_KIND_BRANCH_LINK;
        else if (decoded.is_direct_jump)
            metadata.inst_kind = ICACHE_KIND_BRANCH;
        else if (decoded.is_indirect_jump)
            metadata.inst_kind = ICACHE_KIND_JIRL;
        else if (inst_csr && (inst[9:5] == 5'd0))
            metadata.inst_kind = ICACHE_KIND_CSR_READ;
        else if (inst_csr && (inst[9:5] == 5'd1))
            metadata.inst_kind = ICACHE_KIND_CSR_WRITE;
        else if (inst_csr)
            metadata.inst_kind = ICACHE_KIND_CSR_EXCHANGE;
        else if (inst_rdcntid)
            metadata.inst_kind = ICACHE_KIND_COUNTER_ID;
        else if (inst_counter)
            metadata.inst_kind = ICACHE_KIND_COUNTER;
        else if (inst_cpucfg)
            metadata.inst_kind = ICACHE_KIND_CPUCFG;
        else if (decoded.is_privileged_flow && !decoded.is_illegal)
            metadata.inst_kind = ICACHE_KIND_PRIV_FLOW;
        else
            metadata.inst_kind = ICACHE_KIND_ILLEGAL;
    end
endmodule

// 将 refill 时的元数据展开为完整的前端调度视图。
// 每条支持或非法指令都有精确 kind 表示，因此 ICache BRAM 之后不再需要
// 对原始指令位进行 opcode 译码。
module loongarch_cached_predecode_expand
    import cpu_defs::*;
(
    input  logic [31:0]                 inst,
    input  frontend_icache_predecode_t  cached,
    input  logic                        pred_taken,
    output frontend_predecode_t         expanded,
    output frontend_pair_meta_t         pair_metadata
);
    logic kind_alu_rr;
    logic kind_alu_imm;
    logic kind_upper_imm;
    logic kind_load;
    logic kind_store;
    logic kind_mul;
    logic kind_divmod;
    logic kind_conditional;
    logic kind_branch;
    logic kind_branch_link;
    logic kind_jirl;
    logic kind_csr_read;
    logic kind_csr_write;
    logic kind_csr_exchange;
    logic kind_counter;
    logic kind_counter_id;
    logic kind_cpucfg;
    logic kind_priv_flow;
    logic kind_illegal;
    logic kind_csr;
    logic kind_direct;
    logic kind_muldiv;
    logic slot1_allowed;
    logic younger_allowed;

    always_comb begin
        kind_alu_rr = cached.inst_kind == ICACHE_KIND_ALU_RR;
        kind_alu_imm = cached.inst_kind == ICACHE_KIND_ALU_IMM;
        kind_upper_imm = cached.inst_kind == ICACHE_KIND_UPPER_IMM;
        kind_load = cached.inst_kind == ICACHE_KIND_LOAD;
        kind_store = cached.inst_kind == ICACHE_KIND_STORE;
        kind_mul = cached.inst_kind == ICACHE_KIND_MUL;
        kind_divmod = cached.inst_kind == ICACHE_KIND_DIVMOD;
        kind_conditional = cached.inst_kind == ICACHE_KIND_CONDITIONAL;
        kind_branch = cached.inst_kind == ICACHE_KIND_BRANCH;
        kind_branch_link = cached.inst_kind == ICACHE_KIND_BRANCH_LINK;
        kind_jirl = cached.inst_kind == ICACHE_KIND_JIRL;
        kind_csr_read = cached.inst_kind == ICACHE_KIND_CSR_READ;
        kind_csr_write = cached.inst_kind == ICACHE_KIND_CSR_WRITE;
        kind_csr_exchange = cached.inst_kind == ICACHE_KIND_CSR_EXCHANGE;
        kind_counter = cached.inst_kind == ICACHE_KIND_COUNTER;
        kind_counter_id = cached.inst_kind == ICACHE_KIND_COUNTER_ID;
        kind_cpucfg = cached.inst_kind == ICACHE_KIND_CPUCFG;
        kind_priv_flow = cached.inst_kind == ICACHE_KIND_PRIV_FLOW;
        kind_illegal = cached.inst_kind == ICACHE_KIND_ILLEGAL;

        kind_csr = kind_csr_read | kind_csr_write | kind_csr_exchange;
        kind_direct = kind_branch | kind_branch_link;
        kind_muldiv = kind_mul | kind_divmod;
        slot1_allowed = kind_alu_rr | kind_alu_imm | kind_upper_imm
                      | kind_load | kind_store | kind_conditional
                      | kind_direct | kind_jirl;
        younger_allowed = kind_alu_rr | kind_alu_imm | kind_upper_imm
                        | kind_mul | kind_load | kind_store
                        | kind_conditional | kind_direct;

        expanded = '0;
        expanded.is_conditional_branch = kind_conditional;
        expanded.is_direct_jump = kind_direct;
        expanded.is_indirect_jump = kind_jirl;
        expanded.is_privileged = kind_csr | kind_counter | kind_counter_id
                               | kind_cpucfg | kind_priv_flow;
        expanded.is_privileged_flow = kind_priv_flow | kind_illegal;
        expanded.is_illegal = kind_illegal;
        expanded.is_muldiv = kind_muldiv;
        expanded.is_mul = kind_mul;
        expanded.is_load = kind_load;
        expanded.is_store = kind_store;
        expanded.is_alu_type = kind_alu_rr | kind_alu_imm | kind_upper_imm;
        expanded.writes_dst = cached.writes_dst;
        expanded.uses_src0 = kind_alu_rr | kind_alu_imm | kind_muldiv
                           | kind_load | kind_store | kind_conditional
                           | kind_jirl | kind_csr_write
                           | kind_csr_exchange | kind_cpucfg;
        expanded.uses_src1 = kind_alu_rr | kind_muldiv | kind_store
                           | kind_conditional | kind_csr_exchange;
        expanded.src0_addr = kind_csr ? inst[4:0] : inst[9:5];
        expanded.src1_addr = kind_csr ? inst[9:5]
                           : (kind_store | kind_conditional)
                               ? inst[4:0] : inst[14:10];
        expanded.dst_addr = kind_branch_link ? 5'd1
                          : kind_counter_id ? inst[9:5] : inst[4:0];
        // 精确 kind 编码让末级 F0 控制可以直接取一位，同时继续使用具名
        // kind 谓词构造 payload 字段。
        expanded.is_jump =
            cached.inst_kind[ICACHE_KIND_STATIC_KILL_BIT];
        expanded.is_control = kind_conditional
                            | cached.inst_kind[
                                ICACHE_KIND_STATIC_KILL_BIT
                              ];
        expanded.is_lsu = kind_load | kind_store;
        expanded.is_cfi = kind_conditional | kind_direct | kind_jirl;
        expanded.lane_mask = {slot1_allowed, 1'b1};
        expanded.block_younger = cached.block_younger;
        expanded.serializing = ~(younger_allowed | kind_jirl);

        // 配对策略和完整 FQ 表项使用同一组精确 kind 谓词。
        // 在这里同时构造两种视图，使综合共享每次 5 位 kind 比较，
        // 不再保留第二个只为时序服务的译码器。
        pair_metadata = '0;
        pair_metadata.pred_taken = pred_taken;
        pair_metadata.force_single = cached.block_younger;
        pair_metadata.is_muldiv = kind_muldiv;
        pair_metadata.is_alu_type = kind_alu_rr
                                  | kind_alu_imm | kind_upper_imm;
        pair_metadata.is_lsu = kind_load | kind_store;
        pair_metadata.is_cfi = kind_conditional | kind_direct | kind_jirl;
        pair_metadata.writes_dst = cached.writes_dst;
        pair_metadata.uses_src0 = kind_alu_rr | kind_alu_imm | kind_muldiv
                                | kind_load | kind_store | kind_conditional
                                | kind_jirl | kind_csr_write
                                | kind_csr_exchange | kind_cpucfg;
        pair_metadata.uses_src1 = kind_alu_rr | kind_muldiv | kind_store
                                | kind_conditional | kind_csr_exchange;
        pair_metadata.src0_addr = kind_csr ? inst[4:0] : inst[9:5];
        pair_metadata.src1_addr = kind_csr ? inst[9:5]
                                : (kind_store | kind_conditional)
                                    ? inst[4:0] : inst[14:10];
        pair_metadata.dst_addr = kind_branch_link ? 5'd1
                               : kind_counter_id ? inst[9:5] : inst[4:0];
    end
endmodule

module loongarch_icache_block_predecode
    import cpu_defs::*;
(
    input  logic [63:0] block_data,
    output logic [13:0] block_metadata
);
    frontend_icache_predecode_t low_metadata;
    frontend_icache_predecode_t high_metadata;

    loongarch_icache_predecode u_low_predecode (
        .inst     (block_data[31:0]),
        .metadata (low_metadata)
    );

    loongarch_icache_predecode u_high_predecode (
        .inst     (block_data[63:32]),
        .metadata (high_metadata)
    );

    assign block_metadata = {high_metadata, low_metadata};
endmodule
