// ============================================================
// Module: mul_operand_forwarding
// Description: Physically independent Slot-0 MUL operand forwarding.
// Domain: decode and issue.
//
// A MUL with an EX RAW dependency waits until the producer reaches MEM. This
// local forwarding copy therefore selects only registered MEM/WB/RF values and
// does not pull the ordinary ID operand muxes toward the distant DSP inputs.
// ============================================================

(* keep_hierarchy = "yes" *)
module mul_operand_forwarding (
    input  logic [ 4:0] id_rs1_addr,
    input  logic [ 4:0] id_rs2_addr,
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    input  logic        mem_valid,
    input  logic        mem_reg_write,
    input  logic        mem_is_load,
    input  logic        mem_is_mul,
    input  logic [ 4:0] mem_rd,
    input  logic [31:0] mem_alu_result,
    input  logic [31:0] mem_mul_result,
    input  logic [31:0] mem_pc_plus_4,
    input  logic [ 1:0] mem_wb_sel,

    input  logic        mem_s1_valid,
    input  logic        mem_s1_reg_write,
    input  logic        mem_s1_is_load,
    input  logic [ 4:0] mem_s1_rd,
    input  logic [31:0] mem_s1_alu_result,
    input  logic [31:0] mem_s1_pc_plus_4,
    input  logic [ 1:0] mem_s1_wb_sel,

    input  logic        wb_valid,
    input  logic        wb_reg_write,
    input  logic [ 4:0] wb_rd,
    input  logic [31:0] wb_write_data,

    input  logic        wb_s1_valid,
    input  logic        wb_s1_reg_write,
    input  logic [ 4:0] wb_s1_rd,
    input  logic [31:0] wb_s1_write_data,

    output logic [31:0] mul_rs1_data,
    output logic [31:0] mul_rs2_data
);

    wire mem_select_pc4 = mem_wb_sel == 2'b10;
    wire [31:0] mem_nonmul_forward_data = mem_select_pc4
        ? mem_pc_plus_4 : mem_alu_result;
    wire [31:0] mem_slot1_forward_data = (mem_s1_wb_sel == 2'b10)
        ? mem_s1_pc_plus_4 : mem_s1_alu_result;

    function automatic logic [31:0] select_registered_group(
        input logic [ 1:0] group_select,
        input logic [31:0] mem_data,
        input logic [31:0] wb_data,
        input logic [31:0] rf_data
    );
        case (group_select)
            2'b00:   select_registered_group = mem_data;
            2'b01:   select_registered_group = wb_data;
            default: select_registered_group = rf_data;
        endcase
    endfunction

`define MUL_FWD_MUX(TAG, SRC_ADDR, RF_DATA, OUT_DATA) \
    wire TAG``_s1_mem_hit = mem_s1_valid && mem_s1_reg_write \
                          && !mem_s1_is_load && (mem_s1_rd != 5'd0) \
                          && (mem_s1_rd == SRC_ADDR); \
    wire TAG``_s0_mem_hit = mem_valid && mem_reg_write && !mem_is_load \
                          && (mem_rd != 5'd0) && (mem_rd == SRC_ADDR); \
    wire TAG``_s1_wb_hit = wb_s1_valid && wb_s1_reg_write \
                         && (wb_s1_rd != 5'd0) && (wb_s1_rd == SRC_ADDR); \
    wire TAG``_s0_wb_hit = wb_valid && wb_reg_write \
                         && (wb_rd != 5'd0) && (wb_rd == SRC_ADDR); \
    wire TAG``_s0_mem_mul_fast_select = !TAG``_s1_mem_hit \
                                      && TAG``_s0_mem_hit \
                                      && mem_is_mul \
                                      && !mem_select_pc4; \
    wire TAG``_s0_mem_fallback_hit = TAG``_s0_mem_hit \
                                   && (!mem_is_mul || mem_select_pc4); \
    wire TAG``_mem_group_hit = TAG``_s1_mem_hit \
                             | TAG``_s0_mem_fallback_hit; \
    wire TAG``_wb_group_hit = TAG``_s1_wb_hit | TAG``_s0_wb_hit; \
    wire [31:0] TAG``_mem_group_data = TAG``_s1_mem_hit \
        ? mem_slot1_forward_data : mem_nonmul_forward_data; \
    wire [31:0] TAG``_wb_group_data = TAG``_s1_wb_hit \
        ? wb_s1_write_data : wb_write_data; \
    wire [1:0] TAG``_registered_select = { \
        ~TAG``_mem_group_hit & ~TAG``_wb_group_hit, \
        ~TAG``_mem_group_hit & TAG``_wb_group_hit \
    }; \
    wire [31:0] TAG``_registered_data = select_registered_group( \
        TAG``_registered_select, TAG``_mem_group_data, \
        TAG``_wb_group_data, RF_DATA \
    ); \
    assign OUT_DATA = TAG``_s0_mem_mul_fast_select \
                    ? mem_mul_result : TAG``_registered_data

    `MUL_FWD_MUX(rs1, id_rs1_addr, rf_rs1_data, mul_rs1_data);
    `MUL_FWD_MUX(rs2, id_rs2_addr, rf_rs2_data, mul_rs2_data);

`undef MUL_FWD_MUX

endmodule
