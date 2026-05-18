// ============================================================
// Module: dual_issue_decider
// Description: Fast same-fetch-pair issue legality checks.
// ============================================================

module dual_issue_decider
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        if_valid,
    input  logic        id_flush,
    input  logic        id_allowin,
    input  logic        irom_held_valid,
    input  logic        if_skip_inst0,
    input  logic        if_skip_out,
    input  logic        if_buf_before_window,
    input  logic        if_sequential_fetch,
    input  logic [31:0] pc,
    input  logic [31:0] inst_buf,
    input  logic [31:0] inst_buf_pc,
    input  logic [31:0] if_pc_out,
    input  logic [31:0] irom_inst0,
    input  logic [31:0] irom_inst1,

    output logic        can_dual_fetch,
    output logic        can_dual_issue,
    output logic        inst_buf_valid_next,
    output logic        raw_pair_raw,
    output logic        raw_inst1_is_alu_type,
    output logic        raw_inst0_is_jump
);

    logic held_can_dual_r;

    wire [6:0] raw_inst0_opcode = irom_inst0[6:0];
    wire [6:0] raw_inst1_opcode = irom_inst1[6:0];
    wire [4:0] raw_inst0_rd     = irom_inst0[11:7];
    wire [4:0] raw_inst1_rs1    = irom_inst1[19:15];
    wire [4:0] raw_inst1_rs2    = irom_inst1[24:20];

    assign raw_inst1_is_alu_type = (raw_inst1_opcode == OP_R_TYPE)
                                 | (raw_inst1_opcode == OP_I_ALU)
                                 | (raw_inst1_opcode == OP_LUI)
                                 | (raw_inst1_opcode == OP_AUIPC);
    wire raw_inst1_is_branch = (raw_inst1_opcode == OP_BRANCH);
    wire raw_inst0_is_control = (raw_inst0_opcode == OP_BRANCH)
                              | (raw_inst0_opcode == OP_JAL)
                              | (raw_inst0_opcode == OP_JALR)
                              | (raw_inst0_opcode == OP_SYSTEM);
    wire raw_inst0_is_lsu = (raw_inst0_opcode == OP_LOAD)
                          | (raw_inst0_opcode == OP_STORE);
    assign raw_inst0_is_jump = (raw_inst0_opcode == OP_JAL)
                             | (raw_inst0_opcode == OP_JALR)
                             | (raw_inst0_opcode == OP_SYSTEM);
    wire raw_inst0_writes_rd = (raw_inst0_opcode == OP_R_TYPE)
                             | (raw_inst0_opcode == OP_I_ALU)
                             | (raw_inst0_opcode == OP_LOAD)
                             | (raw_inst0_opcode == OP_LUI)
                             | (raw_inst0_opcode == OP_AUIPC)
                             | raw_inst0_is_jump;
    wire raw_inst1_uses_rs1 = (raw_inst1_opcode == OP_R_TYPE)
                            | (raw_inst1_opcode == OP_I_ALU)
                            | raw_inst1_is_branch;
    wire raw_inst1_uses_rs2 = (raw_inst1_opcode == OP_R_TYPE)
                            | raw_inst1_is_branch;
    assign raw_pair_raw = raw_inst0_writes_rd & (raw_inst0_rd != 5'd0)
                        & ((raw_inst1_uses_rs1 & (raw_inst1_rs1 == raw_inst0_rd))
                         | (raw_inst1_uses_rs2 & (raw_inst1_rs2 == raw_inst0_rd)));
    wire raw_pair_can_dual = ~raw_pair_raw
                           & ((raw_inst1_is_alu_type & ~raw_inst0_is_jump)
                            | (raw_inst1_is_branch & ~raw_inst0_is_control & ~raw_inst0_is_lsu));
    wire raw_can_dual = if_valid
                      & ~if_skip_inst0
                      & (pc != 32'h7FFF_FFFC)
                      & if_sequential_fetch
                      & raw_pair_can_dual;

    wire [6:0] shifted_inst0_opcode = inst_buf[6:0];
    wire [6:0] shifted_inst1_opcode = irom_inst0[6:0];
    wire [4:0] shifted_inst0_rd     = inst_buf[11:7];
    wire [4:0] shifted_inst1_rs1    = irom_inst0[19:15];
    wire [4:0] shifted_inst1_rs2    = irom_inst0[24:20];

    wire shifted_inst1_is_alu_type = (shifted_inst1_opcode == OP_R_TYPE)
                                   | (shifted_inst1_opcode == OP_I_ALU)
                                   | (shifted_inst1_opcode == OP_LUI)
                                   | (shifted_inst1_opcode == OP_AUIPC);
    wire shifted_inst1_is_branch = (shifted_inst1_opcode == OP_BRANCH);
    wire shifted_inst0_is_control = (shifted_inst0_opcode == OP_BRANCH)
                                  | (shifted_inst0_opcode == OP_JAL)
                                  | (shifted_inst0_opcode == OP_JALR)
                                  | (shifted_inst0_opcode == OP_SYSTEM);
    wire shifted_inst0_is_lsu = (shifted_inst0_opcode == OP_LOAD)
                              | (shifted_inst0_opcode == OP_STORE);
    wire shifted_inst0_is_jump = (shifted_inst0_opcode == OP_JAL)
                               | (shifted_inst0_opcode == OP_JALR)
                               | (shifted_inst0_opcode == OP_SYSTEM);
    wire shifted_inst0_writes_rd = (shifted_inst0_opcode == OP_R_TYPE)
                                 | (shifted_inst0_opcode == OP_I_ALU)
                                 | (shifted_inst0_opcode == OP_LOAD)
                                 | (shifted_inst0_opcode == OP_LUI)
                                 | (shifted_inst0_opcode == OP_AUIPC)
                                 | shifted_inst0_is_jump;
    wire shifted_inst1_uses_rs1 = (shifted_inst1_opcode == OP_R_TYPE)
                                | (shifted_inst1_opcode == OP_I_ALU)
                                | shifted_inst1_is_branch;
    wire shifted_inst1_uses_rs2 = (shifted_inst1_opcode == OP_R_TYPE)
                                | shifted_inst1_is_branch;
    wire shifted_pair_raw = shifted_inst0_writes_rd & (shifted_inst0_rd != 5'd0)
                          & ((shifted_inst1_uses_rs1 & (shifted_inst1_rs1 == shifted_inst0_rd))
                           | (shifted_inst1_uses_rs2 & (shifted_inst1_rs2 == shifted_inst0_rd)));
    wire shifted_pair_can_dual = ~shifted_pair_raw
                               & ((shifted_inst1_is_alu_type & ~shifted_inst0_is_jump)
                                | (shifted_inst1_is_branch & ~shifted_inst0_is_control & ~shifted_inst0_is_lsu));
    wire shifted_can_dual = if_valid
                          & (inst_buf_pc != 32'h7FFF_FFFC)
                          & if_sequential_fetch
                          & shifted_pair_can_dual;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            held_can_dual_r <= 1'b0;
        else if (id_flush | id_allowin)
            held_can_dual_r <= 1'b0;
        else if (!irom_held_valid)
            held_can_dual_r <= if_buf_before_window ? shifted_can_dual : raw_can_dual;
    end

    assign can_dual_fetch = if_skip_out ? 1'b0 :
                            irom_held_valid ? held_can_dual_r :
                            if_buf_before_window ? shifted_can_dual : raw_can_dual;
    assign can_dual_issue = can_dual_fetch;

    wire inst_buf_store_base = (if_pc_out != 32'h7FFF_FFFC)
                             & ~if_skip_out
                             & if_sequential_fetch;
    wire inst_buf_valid_raw_next     = inst_buf_store_base & ~raw_pair_can_dual;
    wire inst_buf_valid_shifted_next = inst_buf_store_base & ~shifted_pair_can_dual;
    wire inst_buf_valid_held_next    = inst_buf_store_base & ~held_can_dual_r;
    assign inst_buf_valid_next = irom_held_valid ? inst_buf_valid_held_next :
                                 if_buf_before_window ? inst_buf_valid_shifted_next :
                                 inst_buf_valid_raw_next;

endmodule
