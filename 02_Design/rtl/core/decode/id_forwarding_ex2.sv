// ============================================================
// Module: id_forwarding_ex2
// Description: ID-owned forwarding for the ID/EX1/EX2/MEM/WB pipeline.
//
// Every source register is searched once in ID.  A ready producer supplies its
// value here.  An EX1 producer whose result is deliberately allowed to arrive
// later supplies only a two-bit producer tag; EX2 consumes that tag without
// repeating any register-number comparison.
// ============================================================

module id_forwarding_ex2
    import cpu_defs::*;
(
    // ID Slot 0 consumer and ALU source selection.
    input  logic [ 4:0] id_s0_rs1,
    input  logic [ 4:0] id_s0_rs2,
    input  logic        id_s0_rs1_used,
    input  logic        id_s0_rs2_used,
    input  logic        id_s0_rs1_late_ok,
    input  logic        id_s0_rs2_late_ok,
    input  logic [31:0] id_s0_rf_rs1,
    input  logic [31:0] id_s0_rf_rs2,
    input  logic [31:0] id_s0_pc,
    input  logic [31:0] id_s0_imm,
    input  operand_a_sel_t id_s0_src1_sel,
    input  operand_b_sel_t id_s0_src2_sel,
    input  logic        id_s0_alu_only,
    input  logic        id_s0_is_mul,
    input  logic        id_s0_reg_write,
    input  logic [ 4:0] id_s0_rd,

    // ID Slot 1 consumer.
    input  logic        id_s1_valid,
    input  logic [ 4:0] id_s1_rs1,
    input  logic [ 4:0] id_s1_rs2,
    input  logic        id_s1_rs1_used,
    input  logic        id_s1_rs2_used,
    input  logic        id_s1_rs1_late_ok,
    input  logic        id_s1_rs2_late_ok,
    input  logic [31:0] id_s1_rf_rs1,
    input  logic [31:0] id_s1_rf_rs2,
    input  logic [31:0] id_s1_pc,
    input  logic [31:0] id_s1_imm,
    input  operand_a_sel_t id_s1_src1_sel,
    input  operand_b_sel_t id_s1_src2_sel,

    // EX1 producers. A non-ready producer may name the MEM slot in which its
    // final result will be available when this consumer reaches EX2.
    input  logic        ex1_s0_valid,
    input  logic        ex1_s0_reg_write,
    input  logic [ 4:0] ex1_s0_rd,
    input  logic        ex1_s0_result_ready,
    input  logic        ex1_s0_can_late,
    input  logic [31:0] ex1_s0_result,
    input  logic        ex1_s1_valid,
    input  logic        ex1_s1_reg_write,
    input  logic [ 4:0] ex1_s1_rd,
    input  logic        ex1_s1_result_ready,
    input  logic        ex1_s1_can_late,
    input  logic [31:0] ex1_s1_result,

    // EX2 producers have their final ALU/load/special result this cycle.
    input  logic        ex2_s0_valid,
    input  logic        ex2_s0_reg_write,
    input  logic [ 4:0] ex2_s0_rd,
    input  logic        ex2_s0_result_ready,
    input  logic [31:0] ex2_s0_result,
    input  logic        ex2_s1_valid,
    input  logic        ex2_s1_reg_write,
    input  logic [ 4:0] ex2_s1_rd,
    input  logic        ex2_s1_result_ready,
    input  logic [31:0] ex2_s1_result,

    // Registered final results.
    input  logic        mem_s0_valid,
    input  logic        mem_s0_reg_write,
    input  logic [ 4:0] mem_s0_rd,
    input  logic [31:0] mem_s0_result,
    input  logic        mem_s1_valid,
    input  logic        mem_s1_reg_write,
    input  logic [ 4:0] mem_s1_rd,
    input  logic [31:0] mem_s1_result,
    input  logic        wb_s0_valid,
    input  logic        wb_s0_reg_write,
    input  logic [ 4:0] wb_s0_rd,
    input  logic [31:0] wb_s0_result,
    input  logic        wb_s1_valid,
    input  logic        wb_s1_reg_write,
    input  logic [ 4:0] wb_s1_rd,
    input  logic [31:0] wb_s1_result,

    output logic [31:0] id_s0_rs1_data,
    output logic [31:0] id_s0_rs2_data,
    output logic [31:0] id_s1_rs1_data,
    output logic [31:0] id_s1_rs2_data,
    output logic [31:0] id_s0_alu_src1,
    output logic [31:0] id_s0_alu_src2,
    output logic [31:0] id_s1_alu_src1,
    output logic [31:0] id_s1_alu_src2,
    output late_src_t   id_s0_rs1_late,
    output late_src_t   id_s0_rs2_late,
    output late_src_t   id_s1_rs1_late,
    output late_src_t   id_s1_rs2_late,
    output logic [31:0] id_mul_rs1_data,
    output logic [31:0] id_mul_rs2_data,
    output logic        id_ready_go
);

    function automatic logic producer_match(
        input logic       valid,
        input logic       reg_write,
        input logic [4:0] rd,
        input logic [4:0] rs
    );
        producer_match = valid & reg_write & (rd != 5'd0) & (rd == rs);
    endfunction

    // Four already-preselected groups fit a single LUT-sized data selector per
    // bit on the target FPGA.  Producer comparisons, per-stage Slot1/Slot0
    // choice and final age-group choice are therefore formed in parallel.
    function automatic logic [31:0] select_four_data(
        input logic [ 1:0] select,
        input logic [31:0] data0,
        input logic [31:0] data1,
        input logic [31:0] data2,
        input logic [31:0] data3
    );
        case (select)
            2'b00: select_four_data = data0;
            2'b01: select_four_data = data1;
            2'b10: select_four_data = data2;
            default: select_four_data = data3;
        endcase
    endfunction

    function automatic logic select_four_bit(
        input logic [1:0] select,
        input logic       bit0,
        input logic       bit1,
        input logic       bit2,
        input logic       bit3
    );
        case (select)
            2'b00: select_four_bit = bit0;
            2'b01: select_four_bit = bit1;
            2'b10: select_four_bit = bit2;
            default: select_four_bit = bit3;
        endcase
    endfunction

    function automatic late_src_t select_four_late(
        input logic [1:0] select,
        input late_src_t  late0,
        input late_src_t  late1,
        input late_src_t  late2,
        input late_src_t  late3
    );
        case (select)
            2'b00: select_four_late = late0;
            2'b01: select_four_late = late1;
            2'b10: select_four_late = late2;
            default: select_four_late = late3;
        endcase
    endfunction

    function automatic logic [31:0] preselect_alu_src1(
        input operand_a_sel_t source_select,
        input logic [31:0]    register_data,
        input logic [31:0]    pc_data
    );
        case (source_select)
            OPERAND_A_SRC0: preselect_alu_src1 = register_data;
            OPERAND_A_PC:   preselect_alu_src1 = pc_data;
            default:        preselect_alu_src1 = 32'd0;
        endcase
    endfunction

    function automatic logic [31:0] preselect_alu_src2(
        input operand_b_sel_t source_select,
        input logic [31:0]    register_data,
        input logic [31:0]    immediate_data
    );
        preselect_alu_src2 = (source_select == OPERAND_B_IMM)
                           ? immediate_data : register_data;
    endfunction

`define RESOLVE_OPERAND(TAG, SRC_ADDR, USED, LATE_OK, RF_DATA, PAIR_MATCH, PAIR_READY, OUT_DATA, OUT_LATE, OUT_BLOCKED) \
    wire TAG``_active = (USED) & ((SRC_ADDR) != 5'd0); \
    wire TAG``_ex1_s1_hit = TAG``_active \
        & producer_match(ex1_s1_valid, ex1_s1_reg_write, \
                         ex1_s1_rd, (SRC_ADDR)); \
    wire TAG``_ex1_s0_hit = TAG``_active \
        & producer_match(ex1_s0_valid, ex1_s0_reg_write, \
                         ex1_s0_rd, (SRC_ADDR)); \
    wire TAG``_ex2_s1_hit = TAG``_active \
        & producer_match(ex2_s1_valid, ex2_s1_reg_write, \
                         ex2_s1_rd, (SRC_ADDR)); \
    wire TAG``_ex2_s0_hit = TAG``_active \
        & producer_match(ex2_s0_valid, ex2_s0_reg_write, \
                         ex2_s0_rd, (SRC_ADDR)); \
    wire TAG``_mem_s1_hit = TAG``_active \
        & producer_match(mem_s1_valid, mem_s1_reg_write, \
                         mem_s1_rd, (SRC_ADDR)); \
    wire TAG``_mem_s0_hit = TAG``_active \
        & producer_match(mem_s0_valid, mem_s0_reg_write, \
                         mem_s0_rd, (SRC_ADDR)); \
    wire TAG``_wb_s1_hit = TAG``_active \
        & producer_match(wb_s1_valid, wb_s1_reg_write, \
                         wb_s1_rd, (SRC_ADDR)); \
    wire TAG``_wb_s0_hit = TAG``_active \
        & producer_match(wb_s0_valid, wb_s0_reg_write, \
                         wb_s0_rd, (SRC_ADDR)); \
    wire TAG``_ex1_group_hit = TAG``_ex1_s1_hit \
                             | TAG``_ex1_s0_hit; \
    wire TAG``_ex2_group_hit = TAG``_ex2_s1_hit \
                             | TAG``_ex2_s0_hit; \
    wire TAG``_registered_group_hit = TAG``_mem_s1_hit \
                                    | TAG``_mem_s0_hit \
                                    | TAG``_wb_s1_hit \
                                    | TAG``_wb_s0_hit; \
    wire [31:0] TAG``_ex1_data = TAG``_ex1_s1_hit \
                               ? ex1_s1_result : ex1_s0_result; \
    wire TAG``_ex1_ready = TAG``_ex1_s1_hit \
                         ? ex1_s1_result_ready : ex1_s0_result_ready; \
    wire TAG``_ex1_can_late = TAG``_ex1_s1_hit \
                            ? ex1_s1_can_late : ex1_s0_can_late; \
    wire late_src_t TAG``_ex1_late_source = TAG``_ex1_s1_hit \
                                          ? LATE_MEM_S1 : LATE_MEM_S0; \
    wire [31:0] TAG``_ex2_data = TAG``_ex2_s1_hit \
                               ? ex2_s1_result : ex2_s0_result; \
    wire TAG``_ex2_ready = TAG``_ex2_s1_hit \
                         ? ex2_s1_result_ready : ex2_s0_result_ready; \
    wire [1:0] TAG``_registered_select = { \
        ~TAG``_mem_s1_hit & ~TAG``_mem_s0_hit, \
        ~TAG``_mem_s1_hit & (TAG``_mem_s0_hit | ~TAG``_wb_s1_hit) \
    }; \
    wire [31:0] TAG``_registered_data = select_four_data( \
        TAG``_registered_select, mem_s1_result, mem_s0_result, \
        wb_s1_result, wb_s0_result \
    ); \
    wire [1:0] TAG``_group_select = { \
        ~TAG``_ex1_group_hit & ~TAG``_ex2_group_hit, \
        ~TAG``_ex1_group_hit \
            & (TAG``_ex2_group_hit | ~TAG``_registered_group_hit) \
    }; \
    wire [31:0] TAG``_selected_data = select_four_data( \
        TAG``_group_select, TAG``_ex1_data, TAG``_ex2_data, \
        TAG``_registered_data, (RF_DATA) \
    ); \
    wire TAG``_selected_ready = select_four_bit( \
        TAG``_group_select, TAG``_ex1_ready, TAG``_ex2_ready, \
        1'b1, 1'b1 \
    ); \
    wire TAG``_selected_can_late = select_four_bit( \
        TAG``_group_select, TAG``_ex1_can_late, 1'b0, 1'b0, 1'b0 \
    ); \
    wire late_src_t TAG``_selected_late_source = select_four_late( \
        TAG``_group_select, TAG``_ex1_late_source, \
        LATE_NONE, LATE_NONE, LATE_NONE \
    ); \
    wire TAG``_pair_active = TAG``_active & (PAIR_MATCH); \
    wire TAG``_late_available = TAG``_selected_can_late & (LATE_OK); \
    assign OUT_DATA = TAG``_selected_data; \
    assign OUT_LATE = TAG``_pair_active \
        ? (((PAIR_READY) & (LATE_OK)) ? LATE_PAIR_S0 : LATE_NONE) \
        : ((!TAG``_selected_ready & TAG``_late_available) \
           ? TAG``_selected_late_source : LATE_NONE); \
    assign OUT_BLOCKED = TAG``_pair_active \
        ? ~((PAIR_READY) & (LATE_OK)) \
        : (TAG``_active & ~TAG``_selected_ready \
           & ~TAG``_late_available)

    wire s0_rs1_blocked;
    wire s0_rs2_blocked;
    wire s1_rs1_blocked;
    wire s1_rs2_blocked;

    `RESOLVE_OPERAND(s0_rs1, id_s0_rs1, id_s0_rs1_used,
                     id_s0_rs1_late_ok, id_s0_rf_rs1,
                     1'b0, 1'b0, id_s0_rs1_data,
                     id_s0_rs1_late, s0_rs1_blocked);
    `RESOLVE_OPERAND(s0_rs2, id_s0_rs2, id_s0_rs2_used,
                     id_s0_rs2_late_ok, id_s0_rf_rs2,
                     1'b0, 1'b0, id_s0_rs2_data,
                     id_s0_rs2_late, s0_rs2_blocked);

    wire s0_alu_src1_is_register = id_s0_src1_sel == OPERAND_A_SRC0;
    wire s0_alu_src2_is_register = id_s0_src2_sel == OPERAND_B_SRC1;
    wire s0_result_has_late =
        (s0_alu_src1_is_register
         & (id_s0_rs1_late != LATE_NONE))
      | (s0_alu_src2_is_register
         & (id_s0_rs2_late != LATE_NONE));
    wire same_pair_result_ready = id_s0_alu_only
                                & ~s0_result_has_late
                                & ~s0_rs1_blocked
                                & ~s0_rs2_blocked;
    wire same_pair_rs1_match = id_s1_valid & id_s0_alu_only
                             & id_s0_reg_write & (id_s0_rd != 5'd0)
                             & (id_s0_rd == id_s1_rs1);
    wire same_pair_rs2_match = id_s1_valid & id_s0_alu_only
                             & id_s0_reg_write & (id_s0_rd != 5'd0)
                             & (id_s0_rd == id_s1_rs2);

    `RESOLVE_OPERAND(s1_rs1, id_s1_rs1,
                     id_s1_valid & id_s1_rs1_used,
                     id_s1_rs1_late_ok, id_s1_rf_rs1,
                     same_pair_rs1_match, same_pair_result_ready,
                     id_s1_rs1_data, id_s1_rs1_late,
                     s1_rs1_blocked);
    `RESOLVE_OPERAND(s1_rs2, id_s1_rs2,
                     id_s1_valid & id_s1_rs2_used,
                     id_s1_rs2_late_ok, id_s1_rf_rs2,
                     same_pair_rs2_match, same_pair_result_ready,
                     id_s1_rs2_data, id_s1_rs2_late,
                     s1_rs2_blocked);

`undef RESOLVE_OPERAND

    // Apply PC/immediate selection to each age-group candidate in parallel.
    // The late group selector is then also the final ALU-source selector,
    // avoiding a complete forwarding mux followed by another 32-bit mux.
    wire [31:0] s0_alu_src1_ex1_candidate = preselect_alu_src1(
        id_s0_src1_sel, s0_rs1_ex1_data, id_s0_pc
    );
    wire [31:0] s0_alu_src1_ex2_candidate = preselect_alu_src1(
        id_s0_src1_sel, s0_rs1_ex2_data, id_s0_pc
    );
    wire [31:0] s0_alu_src1_registered_candidate = preselect_alu_src1(
        id_s0_src1_sel, s0_rs1_registered_data, id_s0_pc
    );
    wire [31:0] s0_alu_src1_rf_candidate = preselect_alu_src1(
        id_s0_src1_sel, id_s0_rf_rs1, id_s0_pc
    );
    wire [31:0] s0_alu_src2_ex1_candidate = preselect_alu_src2(
        id_s0_src2_sel, s0_rs2_ex1_data, id_s0_imm
    );
    wire [31:0] s0_alu_src2_ex2_candidate = preselect_alu_src2(
        id_s0_src2_sel, s0_rs2_ex2_data, id_s0_imm
    );
    wire [31:0] s0_alu_src2_registered_candidate = preselect_alu_src2(
        id_s0_src2_sel, s0_rs2_registered_data, id_s0_imm
    );
    wire [31:0] s0_alu_src2_rf_candidate = preselect_alu_src2(
        id_s0_src2_sel, id_s0_rf_rs2, id_s0_imm
    );
    wire [31:0] s1_alu_src1_ex1_candidate = preselect_alu_src1(
        id_s1_src1_sel, s1_rs1_ex1_data, id_s1_pc
    );
    wire [31:0] s1_alu_src1_ex2_candidate = preselect_alu_src1(
        id_s1_src1_sel, s1_rs1_ex2_data, id_s1_pc
    );
    wire [31:0] s1_alu_src1_registered_candidate = preselect_alu_src1(
        id_s1_src1_sel, s1_rs1_registered_data, id_s1_pc
    );
    wire [31:0] s1_alu_src1_rf_candidate = preselect_alu_src1(
        id_s1_src1_sel, id_s1_rf_rs1, id_s1_pc
    );
    (* keep = "true" *) wire [31:0] s1_alu_src2_ex1_candidate =
        preselect_alu_src2(
            id_s1_src2_sel, s1_rs2_ex1_data, id_s1_imm
        );
    (* keep = "true" *) wire [31:0] s1_alu_src2_ex2_candidate =
        preselect_alu_src2(
            id_s1_src2_sel, s1_rs2_ex2_data, id_s1_imm
        );
    (* keep = "true" *) wire [31:0] s1_alu_src2_registered_candidate =
        preselect_alu_src2(
            id_s1_src2_sel, s1_rs2_registered_data, id_s1_imm
        );
    (* keep = "true" *) wire [31:0] s1_alu_src2_rf_candidate =
        preselect_alu_src2(
            id_s1_src2_sel, id_s1_rf_rs2, id_s1_imm
        );

    assign id_s0_alu_src1 = select_four_data(
        s0_rs1_group_select,
        s0_alu_src1_ex1_candidate, s0_alu_src1_ex2_candidate,
        s0_alu_src1_registered_candidate, s0_alu_src1_rf_candidate
    );
    assign id_s0_alu_src2 = select_four_data(
        s0_rs2_group_select,
        s0_alu_src2_ex1_candidate, s0_alu_src2_ex2_candidate,
        s0_alu_src2_registered_candidate, s0_alu_src2_rf_candidate
    );
    assign id_s1_alu_src1 = select_four_data(
        s1_rs1_group_select,
        s1_alu_src1_ex1_candidate, s1_alu_src1_ex2_candidate,
        s1_alu_src1_registered_candidate, s1_alu_src1_rf_candidate
    );
    assign id_s1_alu_src2 = select_four_data(
        s1_rs2_group_select,
        s1_alu_src2_ex1_candidate, s1_alu_src2_ex2_candidate,
        s1_alu_src2_registered_candidate, s1_alu_src2_rf_candidate
    );

    wire mul_rs1_mem_s1_hit = producer_match(
        mem_s1_valid, mem_s1_reg_write, mem_s1_rd, id_s0_rs1
    );
    wire mul_rs1_mem_s0_hit = producer_match(
        mem_s0_valid, mem_s0_reg_write, mem_s0_rd, id_s0_rs1
    );
    wire mul_rs1_wb_s1_hit = producer_match(
        wb_s1_valid, wb_s1_reg_write, wb_s1_rd, id_s0_rs1
    );
    wire mul_rs1_wb_s0_hit = producer_match(
        wb_s0_valid, wb_s0_reg_write, wb_s0_rd, id_s0_rs1
    );
    wire mul_rs2_mem_s1_hit = producer_match(
        mem_s1_valid, mem_s1_reg_write, mem_s1_rd, id_s0_rs2
    );
    wire mul_rs2_mem_s0_hit = producer_match(
        mem_s0_valid, mem_s0_reg_write, mem_s0_rd, id_s0_rs2
    );
    wire mul_rs2_wb_s1_hit = producer_match(
        wb_s1_valid, wb_s1_reg_write, wb_s1_rd, id_s0_rs2
    );
    wire mul_rs2_wb_s0_hit = producer_match(
        wb_s0_valid, wb_s0_reg_write, wb_s0_rd, id_s0_rs2
    );

    wire [1:0] mul_rs1_select = {
        ~mul_rs1_mem_s1_hit & ~mul_rs1_mem_s0_hit,
        ~mul_rs1_mem_s1_hit
            & (mul_rs1_mem_s0_hit | ~mul_rs1_wb_s1_hit)
    };
    wire [1:0] mul_rs2_select = {
        ~mul_rs2_mem_s1_hit & ~mul_rs2_mem_s0_hit,
        ~mul_rs2_mem_s1_hit
            & (mul_rs2_mem_s0_hit | ~mul_rs2_wb_s1_hit)
    };
    wire [31:0] mul_rs1_wb_s0_or_rf = mul_rs1_wb_s0_hit
                                    ? wb_s0_result : id_s0_rf_rs1;
    wire [31:0] mul_rs2_wb_s0_or_rf = mul_rs2_wb_s0_hit
                                    ? wb_s0_result : id_s0_rf_rs2;
    assign id_mul_rs1_data = select_four_data(
        mul_rs1_select, mem_s1_result, mem_s0_result,
        wb_s1_result, mul_rs1_wb_s0_or_rf
    );
    assign id_mul_rs2_data = select_four_data(
        mul_rs2_select, mem_s1_result, mem_s0_result,
        wb_s1_result, mul_rs2_wb_s0_or_rf
    );

    // The DSP input copy intentionally has no EX1/EX2 data path.  A matching
    // multiply waits until the producer reaches the registered MEM group.
    wire mul_rs1_ex_match = id_s0_is_mul & id_s0_rs1_used
        & (producer_match(ex1_s1_valid, ex1_s1_reg_write,
                          ex1_s1_rd, id_s0_rs1)
         | producer_match(ex1_s0_valid, ex1_s0_reg_write,
                          ex1_s0_rd, id_s0_rs1)
         | producer_match(ex2_s1_valid, ex2_s1_reg_write,
                          ex2_s1_rd, id_s0_rs1)
         | producer_match(ex2_s0_valid, ex2_s0_reg_write,
                          ex2_s0_rd, id_s0_rs1));
    wire mul_rs2_ex_match = id_s0_is_mul & id_s0_rs2_used
        & (producer_match(ex1_s1_valid, ex1_s1_reg_write,
                          ex1_s1_rd, id_s0_rs2)
         | producer_match(ex1_s0_valid, ex1_s0_reg_write,
                          ex1_s0_rd, id_s0_rs2)
         | producer_match(ex2_s1_valid, ex2_s1_reg_write,
                          ex2_s1_rd, id_s0_rs2)
         | producer_match(ex2_s0_valid, ex2_s0_reg_write,
                          ex2_s0_rd, id_s0_rs2));

    assign id_ready_go = ~s0_rs1_blocked
                       & ~s0_rs2_blocked
                       & ~s1_rs1_blocked
                       & ~s1_rs2_blocked
                       & ~mul_rs1_ex_match
                       & ~mul_rs2_ex_match;

endmodule
