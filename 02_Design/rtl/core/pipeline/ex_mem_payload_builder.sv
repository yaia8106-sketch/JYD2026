// ============================================================
// Module: ex_mem_payload_builder
// Description: Pure combinational construction of EX/MEM payloads.
// Domain: pipeline boundary.
// Pipeline valid/allow/flush state remains in ex_mem_reg modules.
// ============================================================

module ex_mem_payload_builder
    import cpu_defs::*;
(
    input  logic               redirect_valid,
    input  logic [31:0]        redirect_target,

    input  logic [31:0]        s0_alu_result,
    input  logic [31:0]        s0_pc,
    input  logic [31:0]        s0_pc_plus_4,
    input  logic [ 4:0]        s0_rd,
    input  logic               s0_reg_write_en,
    input  logic [ 1:0]        s0_wb_sel,
    input  logic               s0_mem_read_en,
    input  logic [ 1:0]        s0_mem_size,
    input  logic               s0_mem_unsigned,
    input  logic [ 3:0]        s0_store_wea,
    input  logic [31:0]        s0_store_data,
    input  logic               s0_is_cacheable,

    input  logic [31:0]        s1_pc,
    input  logic [31:0]        s1_inst,
    input  logic [31:0]        s1_alu_result,
    input  logic [31:0]        s1_pc_plus_4,
    input  logic [ 4:0]        s1_rd,
    input  logic               s1_reg_write_en,
    input  logic [ 1:0]        s1_wb_sel,
    input  logic               s1_mem_read_en,
    input  logic               s1_mem_write_en,
    input  logic [ 1:0]        s1_mem_size,
    input  logic               s1_mem_unsigned,
    input  logic [ 3:0]        s1_store_wea,
    input  logic [31:0]        s1_store_data,
    input  logic               s1_is_cacheable,

    output redirect_t          redirect,
    output ex_mem_slot0_t      slot0_payload,
    output ex_mem_slot1_t      slot1_payload
);

    // Redirect payload and data payload are built together, but the register
    // stage may propagate the redirect even when MEM is backpressured.
    always_comb begin
        redirect.valid = redirect_valid;
        redirect.target = redirect_target;

        slot0_payload = '0;
        slot0_payload.alu_result = s0_alu_result;
        slot0_payload.pc = s0_pc;
        slot0_payload.pc_plus_4 = s0_pc_plus_4;
        slot0_payload.rd = s0_rd;
        slot0_payload.reg_write_en = s0_reg_write_en;
        slot0_payload.wb_sel = s0_wb_sel;
        slot0_payload.mem_read_en = s0_mem_read_en;
        slot0_payload.mem_size = s0_mem_size;
        slot0_payload.mem_unsigned = s0_mem_unsigned;
        slot0_payload.store_wea = s0_store_wea;
        slot0_payload.store_data = s0_store_data;
        slot0_payload.is_cacheable = s0_is_cacheable;

        slot1_payload = '0;
        slot1_payload.pc = s1_pc;
        slot1_payload.inst = s1_inst;
        slot1_payload.alu_result = s1_alu_result;
        slot1_payload.pc_plus_4 = s1_pc_plus_4;
        slot1_payload.rd = s1_rd;
        slot1_payload.reg_write_en = s1_reg_write_en;
        slot1_payload.wb_sel = s1_wb_sel;
        slot1_payload.mem_read_en = s1_mem_read_en;
        slot1_payload.mem_write_en = s1_mem_write_en;
        slot1_payload.mem_size = s1_mem_size;
        slot1_payload.mem_unsigned = s1_mem_unsigned;
        slot1_payload.store_wea = s1_store_wea;
        slot1_payload.store_data = s1_store_data;
        slot1_payload.is_cacheable = s1_is_cacheable;
    end

endmodule
