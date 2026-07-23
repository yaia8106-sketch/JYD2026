// ============================================================
// Module: ex2_operand_select
// Description: Narrow late-operand substitution for the dual EX2 ALUs.
//
// ID has already identified the exact producer.  EX2 therefore performs no
// register-number comparisons and only selects among the three explicitly
// supported late sources.
// ============================================================

module ex2_operand_select
    import cpu_defs::*;
(
    input  logic [31:0] pair_s0_result,
    input  logic [31:0] mem_s0_result,
    input  logic [31:0] mem_s1_result,

    input  logic [31:0] s0_alu_src1,
    input  logic [31:0] s0_alu_src2,
    input  logic [31:0] s0_rs1_data,
    input  logic [31:0] s0_rs2_data,
    input  late_src_t   s0_alu_src1_late,
    input  late_src_t   s0_alu_src2_late,
    input  late_src_t   s0_rs1_late,
    input  late_src_t   s0_rs2_late,

    input  logic [31:0] s1_alu_src1,
    input  logic [31:0] s1_alu_src2,
    input  logic [31:0] s1_rs1_data,
    input  logic [31:0] s1_rs2_data,
    input  late_src_t   s1_alu_src1_late,
    input  late_src_t   s1_alu_src2_late,
    input  late_src_t   s1_rs1_late,
    input  late_src_t   s1_rs2_late,

    output logic [31:0] s0_alu_src1_final,
    output logic [31:0] s0_alu_src2_final,
    output logic [31:0] s0_rs1_final,
    output logic [31:0] s0_rs2_final,
    output logic [31:0] s1_alu_src1_final,
    output logic [31:0] s1_alu_src2_final,
    output logic [31:0] s1_rs1_final,
    output logic [31:0] s1_rs2_final
);

    function automatic logic [31:0] select_late(
        input late_src_t   source,
        input logic [31:0] original,
        input logic [31:0] pair_result,
        input logic [31:0] mem0_result,
        input logic [31:0] mem1_result
    );
        case (source)
            LATE_PAIR_S0: select_late = pair_result;
            LATE_MEM_S0:  select_late = mem0_result;
            LATE_MEM_S1:  select_late = mem1_result;
            default:      select_late = original;
        endcase
    endfunction

    // Slot 0 can never consume the younger same-pair source. Feeding its local
    // value into that unused selector entry keeps pair_s0_result confined to
    // Slot 1 instead of adding four unnecessary 32-bit fanout branches.
    assign s0_alu_src1_final = select_late(
        s0_alu_src1_late, s0_alu_src1,
        s0_alu_src1, mem_s0_result, mem_s1_result
    );
    assign s0_alu_src2_final = select_late(
        s0_alu_src2_late, s0_alu_src2,
        s0_alu_src2, mem_s0_result, mem_s1_result
    );
    assign s0_rs1_final = select_late(
        s0_rs1_late, s0_rs1_data,
        s0_rs1_data, mem_s0_result, mem_s1_result
    );
    assign s0_rs2_final = select_late(
        s0_rs2_late, s0_rs2_data,
        s0_rs2_data, mem_s0_result, mem_s1_result
    );

    assign s1_alu_src1_final = select_late(
        s1_alu_src1_late, s1_alu_src1,
        pair_s0_result, mem_s0_result, mem_s1_result
    );
    assign s1_alu_src2_final = select_late(
        s1_alu_src2_late, s1_alu_src2,
        pair_s0_result, mem_s0_result, mem_s1_result
    );
    assign s1_rs1_final = select_late(
        s1_rs1_late, s1_rs1_data,
        pair_s0_result, mem_s0_result, mem_s1_result
    );
    assign s1_rs2_final = select_late(
        s1_rs2_late, s1_rs2_data,
        pair_s0_result, mem_s0_result, mem_s1_result
    );

endmodule
