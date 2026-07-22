// ============================================================
// Module: mem_wb_payload_builder
// Description: Pure combinational construction of MEM/WB payloads.
// Domain: pipeline boundary.
// Pipeline valid/allow state remains in mem_wb_reg modules.
// ============================================================

module mem_wb_payload_builder
    import cpu_defs::*;
(
    input  logic [31:0]      s0_alu_result,
    input  logic [31:0]      s0_pc,
    input  logic [31:0]      s0_inst,
    input  logic [31:0]      s0_pc_plus_4,
    input  logic [ 4:0]      s0_rd,
    input  logic             s0_reg_write_en,
    input  wb_src_t           s0_wb_sel,
    input  logic             s0_is_load,
    input  logic [31:0]      s0_load_data,
    input  logic             s0_is_store,
    input  mem_size_t         s0_mem_size,
    input  logic             s0_mem_unsigned,
    input  logic [31:0]      s0_mem_addr,
    input  logic [31:0]      s0_store_data,
    input  logic             s0_exception,
    input  logic             s0_csr_rstat,
    input  logic [31:0]      s0_csr_data,

    input  logic [31:0]      s1_pc,
    input  logic [31:0]      s1_inst,
    input  logic [31:0]      s1_alu_result,
    input  logic [31:0]      s1_pc_plus_4,
    input  logic [ 4:0]      s1_rd,
    input  logic             s1_reg_write_en,
    input  wb_src_t           s1_wb_sel,
    input  logic             s1_is_load,
    input  logic             s1_is_store,
    input  mem_size_t         s1_mem_size,
    input  logic             s1_mem_unsigned,
    input  logic [31:0]      s1_mem_addr,
    input  logic [31:0]      s1_store_data,

    output mem_wb_slot0_t    slot0_payload,
    output mem_wb_slot1_t    slot1_payload
);

    // MEM/WB carries the final load data only for Slot 0 because the shared LSU
    // allows at most one load result per cycle.
    always_comb begin
        slot0_payload = '0;
        slot0_payload.pc = s0_pc;
        slot0_payload.inst = s0_inst;
        slot0_payload.alu_result = s0_alu_result;
        slot0_payload.pc_plus_4 = s0_pc_plus_4;
        slot0_payload.rd = s0_rd;
        slot0_payload.reg_write_en = s0_reg_write_en;
        slot0_payload.wb_sel = s0_wb_sel;
        slot0_payload.is_load = s0_is_load;
        slot0_payload.load_data = s0_load_data;
        slot0_payload.is_store = s0_is_store;
        slot0_payload.mem_size = s0_mem_size;
        slot0_payload.mem_unsigned = s0_mem_unsigned;
        slot0_payload.mem_addr = s0_mem_addr;
        slot0_payload.store_data = s0_store_data;
        slot0_payload.exception = s0_exception;
        slot0_payload.csr_rstat = s0_csr_rstat;
        slot0_payload.csr_data = s0_csr_data;

        slot1_payload = '0;
        slot1_payload.pc = s1_pc;
        slot1_payload.inst = s1_inst;
        slot1_payload.alu_result = s1_alu_result;
        slot1_payload.pc_plus_4 = s1_pc_plus_4;
        slot1_payload.rd = s1_rd;
        slot1_payload.reg_write_en = s1_reg_write_en;
        slot1_payload.wb_sel = s1_wb_sel;
        slot1_payload.is_load = s1_is_load;
        slot1_payload.is_store = s1_is_store;
        slot1_payload.mem_size = s1_mem_size;
        slot1_payload.mem_unsigned = s1_mem_unsigned;
        slot1_payload.mem_addr = s1_mem_addr;
        slot1_payload.store_data = s1_store_data;
    end

endmodule
