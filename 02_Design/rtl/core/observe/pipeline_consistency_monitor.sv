`ifndef SYNTHESIS
// ============================================================
// Module: pipeline_consistency_monitor
// Description: Simulation-only checks for pipeline timing mirrors and
//              stage-local copies used by forwarding and MulDiv control.
// Domain: observe.
// ============================================================

module pipeline_consistency_monitor
    import cpu_defs::*;
(
    input logic          clk,
    input logic          rst_n,

    input logic          id_slot0_valid,
    input logic          id_slot1_valid,
    input decoded_uop_t  id_slot0_uop,
    input decoded_uop_t  id_slot1_uop,
    input issue_hint_t   id_slot0_issue_hint,
    input issue_hint_t   id_slot1_issue_hint,
    input logic [4:0]    id_slot0_rf_rs1_addr,
    input logic [4:0]    id_slot0_rf_rs2_addr,
    input logic [4:0]    id_slot1_rf_rs1_addr,
    input logic [4:0]    id_slot1_rf_rs2_addr,
    input logic [4:0]    id_slot0_rs1_addr,
    input logic [4:0]    id_slot0_rs2_addr,
    input logic [4:0]    id_slot1_rs1_addr,
    input logic [4:0]    id_slot1_rs2_addr,
    input logic          id_to_ex_fire,
    input logic          id_mul_prestart,
    input logic          id_is_mul,
    input logic [31:0]   id_slot0_alu_src1,
    input logic [31:0]   id_slot0_alu_src2,
    input logic [31:0]   id_slot1_alu_src1,
    input logic [31:0]   id_slot1_alu_src2,
    input logic [31:0]   id_slot0_forward_rs1,
    input logic [31:0]   id_slot0_forward_rs2,
    input logic [31:0]   id_slot1_forward_rs1,
    input logic [31:0]   id_slot1_forward_rs2,
    input logic [31:0]   id_slot0_pc,
    input logic [31:0]   id_slot1_pc,

    input logic          ex_slot0_valid,
    input logic          ex_slot1_valid,
    input id_ex_slot0_t  ex_slot0_payload,
    input id_ex_slot1_t  ex_slot1_payload,
    input logic [3:0]    ex_slot0_repair,
    input logic [3:0]    ex_slot1_repair,
    input logic          ex_slot0_hazard_valid,
    input logic          ex_slot0_hazard_reg_write,
    input logic          ex_slot0_hazard_is_muldiv,
    input logic          ex_slot0_hazard_mem_read,
    input logic          ex_slot0_hazard_result_repair,
    input logic [4:0]    ex_slot0_hazard_rd,
    input logic          ex_slot1_hazard_valid,
    input logic          ex_slot1_hazard_reg_write,
    input logic          ex_slot1_hazard_mem_read,
    input logic          ex_slot1_hazard_result_repair,
    input logic [4:0]    ex_slot1_hazard_rd,
    input logic [4:0]    ex_slot1_fast_src2_low,
    input logic [31:0]   ex_slot0_fast_forward_result,
    input logic [31:0]   ex_slot1_fast_forward_result,
    input logic [31:0]   ex_slot0_alu_result,
    input logic [31:0]   ex_slot1_alu_result,

    input logic          mem_slot0_valid,
    input logic          mem_slot1_valid,
    input ex_mem_slot0_t mem_slot0_payload,
    input ex_mem_slot1_t mem_slot1_payload,
    input logic          mem_allowin,
    input logic          mem_allowin_lsu,
    input logic          mem_allowin_control,
    input logic          mem_allowin_pipe,

    input logic          mul_launch_ex_raw_hazard,
    input logic [31:0]   mul_forward_rs1_data,
    input logic [31:0]   mul_forward_rs2_data,
    input logic [31:0]   architectural_forward_rs1_data,
    input logic [31:0]   architectural_forward_rs2_data,
    input logic          muldiv_done
);

    function automatic issue_hint_t issue_hint_from_uop(
        input decoded_uop_t uop
    );
        begin
            issue_hint_from_uop = '0;
            issue_hint_from_uop.src0_used = uop.src0_used;
            issue_hint_from_uop.src1_used = uop.src1_used;
            issue_hint_from_uop.src0_addr = uop.src0_addr;
            issue_hint_from_uop.src1_addr = uop.src1_addr;
            issue_hint_from_uop.dst_write = uop.dst_write;
            issue_hint_from_uop.dst_addr = uop.dst_addr;
            issue_hint_from_uop.alu_only = uop.dst_write
                & (uop.exec_unit == EXEC_ALU) & (uop.wb_src == WB_EXEC);
            issue_hint_from_uop.conditional_control =
                uop.control_flow == CF_CONDITIONAL;
            issue_hint_from_uop.indirect_control =
                uop.control_flow == CF_INDIRECT;
            issue_hint_from_uop.mem_read = uop.mem_cmd == MEM_LOAD;
            issue_hint_from_uop.mem_write = uop.mem_cmd == MEM_STORE;
            issue_hint_from_uop.is_muldiv = uop.exec_unit == EXEC_MULDIV;
            issue_hint_from_uop.is_mul = (uop.exec_unit == EXEC_MULDIV)
                & (uop.muldiv_op <= MULDIV_MULHU);
            issue_hint_from_uop.serializing = uop.serializing;
        end
    endfunction

    wire issue_hint_t id_slot0_issue_hint_reference =
        issue_hint_from_uop(id_slot0_uop);
    wire issue_hint_t id_slot1_issue_hint_reference =
        issue_hint_from_uop(id_slot1_uop);
    wire [31:0] id_slot0_alu_src1_reference;
    wire [31:0] id_slot0_alu_src2_reference;
    wire [31:0] id_slot1_alu_src1_reference;
    wire [31:0] id_slot1_alu_src2_reference;

    alu_src_mux u_slot0_alu_src_reference (
        .rs1_data     (id_slot0_forward_rs1),
        .rs2_data     (id_slot0_forward_rs2),
        .pc           (id_slot0_pc),
        .imm          (id_slot0_uop.imm),
        .alu_src1_sel (id_slot0_uop.operand_a_sel),
        .alu_src2_sel (id_slot0_uop.operand_b_sel),
        .alu_src1     (id_slot0_alu_src1_reference),
        .alu_src2     (id_slot0_alu_src2_reference)
    );

    alu_src_mux u_slot1_alu_src_reference (
        .rs1_data     (id_slot1_forward_rs1),
        .rs2_data     (id_slot1_forward_rs2),
        .pc           (id_slot1_pc),
        .imm          (id_slot1_uop.imm),
        .alu_src1_sel (id_slot1_uop.operand_a_sel),
        .alu_src2_sel (id_slot1_uop.operand_b_sel),
        .alu_src1     (id_slot1_alu_src1_reference),
        .alu_src2     (id_slot1_alu_src2_reference)
    );

    wire ex_slot0_uses_priv_result =
        (ex_slot0_payload.priv_op == PRIV_REG)
        | (ex_slot0_payload.priv_op == PRIV_COUNTER)
        | (ex_slot0_payload.priv_op == PRIV_CPUCFG);
    wire ex_slot0_forward_reg_write =
        ex_slot0_payload.common.reg_write_en
        & ~ex_slot0_payload.common.mem_read_en
        & ~ex_slot0_payload.is_muldiv
        & ~ex_slot0_uses_priv_result;
    wire ex_slot1_forward_reg_write =
        ex_slot1_payload.common.reg_write_en
        & ~ex_slot1_payload.common.mem_read_en;
    wire ex_slot0_fast_alu_forward =
        ~ex_slot0_uses_priv_result
        & ~ex_slot0_payload.is_muldiv
        & (ex_slot0_payload.common.wb_sel != WB_NEXT_PC);

    always_ff @(posedge clk) begin
        if (rst_n && id_slot0_valid
                  && (id_slot0_issue_hint
                      !== id_slot0_issue_hint_reference))
            $fatal(1, "Slot-0 predecode issue hint disagrees with full decoder");
        if (rst_n && id_slot1_valid
                  && (id_slot1_issue_hint
                      !== id_slot1_issue_hint_reference))
            $fatal(1, "Slot-1 predecode issue hint disagrees with full decoder");
        if (rst_n && id_slot0_valid
                  && ((id_slot0_rf_rs1_addr !== id_slot0_rs1_addr)
                      || (id_slot0_rf_rs2_addr !== id_slot0_rs2_addr)))
            $fatal(1, "Slot-0 register-file address copies disagree with hazard metadata");
        if (rst_n && id_slot1_valid
                  && ((id_slot1_rf_rs1_addr !== id_slot1_rs1_addr)
                      || (id_slot1_rf_rs2_addr !== id_slot1_rs2_addr)))
            $fatal(1, "Slot-1 register-file address copies disagree with hazard metadata");

        if (rst_n && ex_slot0_valid
                  && (ex_slot0_repair !== {
                        ex_slot0_payload.common.alu_src2_wb_repair,
                        ex_slot0_payload.common.alu_src1_wb_repair,
                        ex_slot0_payload.common.rs2_wb_repair,
                        ex_slot0_payload.common.rs1_wb_repair
                      }))
            $fatal(1, "Slot-0 EX repair mirror disagrees with ID/EX");
        if (rst_n && ex_slot1_valid
                  && (ex_slot1_repair !== {
                        ex_slot1_payload.common.alu_src2_wb_repair,
                        ex_slot1_payload.common.alu_src1_wb_repair,
                        ex_slot1_payload.common.rs2_wb_repair,
                        ex_slot1_payload.common.rs1_wb_repair
                      }))
            $fatal(1, "Slot-1 EX repair mirror disagrees with ID/EX");
        if (rst_n && (ex_slot0_hazard_valid !== ex_slot0_valid))
            $fatal(1, "Slot-0 EX hazard-valid mirror disagrees with ID/EX");
        if (rst_n && ex_slot0_valid
                  && ((ex_slot0_hazard_reg_write
                       !== ex_slot0_forward_reg_write)
                      || (ex_slot0_hazard_is_muldiv
                          !== ex_slot0_payload.is_muldiv)
                      || (ex_slot0_hazard_mem_read
                          !== ex_slot0_payload.common.mem_read_en)
                      || (ex_slot0_hazard_result_repair
                          !== (ex_slot0_repair[2] | ex_slot0_repair[3]))
                      || (ex_slot0_hazard_rd
                          !== ex_slot0_payload.common.rd)))
            $fatal(1, "Slot-0 EX hazard metadata mirror disagrees with ID/EX");
        if (rst_n && (ex_slot1_hazard_valid !== ex_slot1_valid))
            $fatal(1, "Slot-1 EX hazard-valid mirror disagrees with ID/EX");
        if (rst_n && ex_slot1_valid
                  && ((ex_slot1_hazard_reg_write
                       !== ex_slot1_forward_reg_write)
                      || (ex_slot1_hazard_mem_read
                          !== ex_slot1_payload.common.mem_read_en)
                      || (ex_slot1_hazard_result_repair
                          !== (ex_slot1_repair[2] | ex_slot1_repair[3]))
                      || (ex_slot1_hazard_rd
                          !== ex_slot1_payload.common.rd)))
            $fatal(1, "Slot-1 EX hazard metadata mirror disagrees with ID/EX");
        if (rst_n && ex_slot1_valid
                  && (ex_slot1_fast_src2_low
                      !== ex_slot1_payload.common.alu_src2[4:0]))
            $fatal(1, "Slot-1 fast-forward shift mirror disagrees with ID/EX");

        if (rst_n
                  && ((mem_allowin_lsu !== mem_allowin)
                      || (mem_allowin_control !== mem_allowin)
                      || (mem_allowin_pipe !== mem_allowin)))
            $fatal(1, "MEM allowin functional-cluster copies diverged");
        if (rst_n && (id_mul_prestart !== (id_to_ex_fire & id_is_mul)))
            $fatal(1, "Timing-factored MUL prestart changed ID acceptance");
        if (rst_n && id_to_ex_fire
                  && ((id_slot0_alu_src1 !== id_slot0_alu_src1_reference)
                      || (id_slot0_alu_src2
                          !== id_slot0_alu_src2_reference)))
            $fatal(1, "Slot-0 parallel ALU source selection changed value");
        if (rst_n && id_to_ex_fire && id_slot1_valid
                  && ((id_slot1_alu_src1 !== id_slot1_alu_src1_reference)
                      || (id_slot1_alu_src2
                          !== id_slot1_alu_src2_reference)))
            $fatal(1, "Slot-1 parallel ALU source selection changed value");
        if (rst_n && ex_slot0_valid && ex_slot0_fast_alu_forward
                  && !(ex_slot0_repair[2] | ex_slot0_repair[3])
                  && (ex_slot0_fast_forward_result
                      !== ex_slot0_alu_result))
            $fatal(1, "Slot-0 fast EX ALU copy changed architectural value");
        if (rst_n && ex_slot1_valid
                  && !(ex_slot1_repair[2] | ex_slot1_repair[3])
                  && (ex_slot1_fast_forward_result
                      !== ex_slot1_alu_result))
            $fatal(1, "Slot-1 fast EX ALU copy changed architectural value");

        if (rst_n && ex_slot0_valid
                  && (ex_slot0_payload.common.control_flow != CF_NONE)
                  && (ex_slot0_payload.common.control_flow != CF_CONDITIONAL)
                  && (ex_slot0_repair[0] | ex_slot0_repair[1]))
            $fatal(1, "Slot-0 non-conditional control entered EX with WB repair");
        if (rst_n && ex_slot1_valid
                  && (ex_slot1_payload.common.control_flow != CF_NONE)
                  && (ex_slot1_payload.common.control_flow != CF_CONDITIONAL)
                  && (ex_slot1_repair[0] | ex_slot1_repair[1]))
            $fatal(1, "Slot-1 non-conditional control entered EX with WB repair");
        if (rst_n && ex_slot0_valid
                  && (ex_slot0_payload.common.control_flow == CF_CONDITIONAL)
                  && (ex_slot0_repair[2] | ex_slot0_repair[3]))
            $fatal(1, "Slot-0 conditional repair leaked into target operands");
        if (rst_n && ex_slot1_valid
                  && (ex_slot1_payload.common.control_flow == CF_CONDITIONAL)
                  && (ex_slot1_repair[2] | ex_slot1_repair[3]))
            $fatal(1, "Slot-1 conditional repair leaked into target operands");
        if (rst_n && ex_slot0_valid
                  && (ex_slot0_payload.priv_op != PRIV_NONE)
                  && (ex_slot0_repair[0] | ex_slot0_repair[1]))
            $fatal(1, "Serialized privileged operation entered EX with WB repair");
        if (rst_n && ex_slot0_valid && ex_slot1_valid
                  && (ex_slot0_payload.common.mem_read_en
                      | ex_slot0_payload.common.mem_write_en)
                  && (ex_slot1_payload.common.mem_read_en
                      | ex_slot1_payload.common.mem_write_en))
            $fatal(1, "Dual-issue pair contains two LSU instructions");
        if (rst_n && mem_slot0_valid && mem_slot1_valid
                  && mem_slot0_payload.mem_read_en
                  && mem_slot1_payload.mem_read_en)
            $fatal(1, "MEM contains two simultaneous load producers");

        if (rst_n && id_mul_prestart && mul_launch_ex_raw_hazard)
            $fatal(1, "MUL launched across an EX RAW interlock");
        if (rst_n && id_mul_prestart
                  && ((mul_forward_rs1_data
                       !== architectural_forward_rs1_data)
                      || (mul_forward_rs2_data
                          !== architectural_forward_rs2_data)))
            $fatal(1, "MUL forwarding copy disagrees with architectural forwarding");
        if (rst_n && ex_slot0_valid && ex_slot0_payload.is_muldiv
                  && !ex_slot0_payload.muldiv_op[2]
                  && (ex_slot0_repair[2] | ex_slot0_repair[3]))
            $fatal(1, "MUL entered EX with an unsupported WB-repair tag");
        if (rst_n && mem_slot0_valid && mem_slot0_payload.is_mul
                  && !muldiv_done)
            $fatal(1, "MEM MUL token is not aligned with registered result");
        if (rst_n && muldiv_done
                  && !((mem_slot0_valid && mem_slot0_payload.is_mul)
                       || (ex_slot0_valid
                           && ex_slot0_payload.is_muldiv)))
            $fatal(1, "Completed MulDiv result has no matching pipeline owner");
    end

endmodule
`endif
