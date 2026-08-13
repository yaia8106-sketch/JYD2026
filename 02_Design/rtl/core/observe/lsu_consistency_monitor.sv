`ifndef SYNTHESIS
// ============================================================
// Module: lsu_consistency_monitor
// Description: Simulation-only checks for dual-issue LSU steering, compact
//              address mirrors, and the Slot-0 to Slot-1 store-data bypass.
// Domain: observe.
// ============================================================

module lsu_consistency_monitor
    import cpu_defs::*;
#(
    parameter bit AXI_UNCACHED_DATA = 1'b0
) (
    input logic          clk,
    input logic          rst_n,
    input logic          ex_slot0_valid,
    input logic          ex_slot1_valid,
    input id_ex_slot0_t  ex_slot0_payload,
    input id_ex_slot1_t  ex_slot1_payload,
    input logic [3:0]    ex_slot0_repair,
    input logic [3:0]    ex_slot1_repair,
    input logic          ex_slot0_branch_flush,
    input logic          ex_slot0_priv_trap,
    input logic          ex_slot1_addr_replay,
    input logic [18:0]   ex_slot0_lsu_addr_low,
    input logic [18:0]   ex_slot1_lsu_addr_low,
    input logic [1:0]    ex_slot0_align_addr_low,
    input logic [1:0]    ex_slot1_align_addr_low,
    input logic [31:0]   ex_slot0_alu_addr,
    input logic [31:0]   ex_slot1_alu_addr,
    input logic          ex_slot0_is_cacheable,
    input logic          ex_slot1_is_cacheable,
    input logic          ex_slot0_store_data_bypass,
    input logic [31:0]   ex_slot1_store_data,
    input logic [31:0]   ex_slot0_alu_result,
    input logic          mem_branch_flush,
    input logic          cache_req,
    input logic          mmio_store_load_hazard,
    input ex_mem_slot0_t mem_slot0_payload,
    input ex_mem_slot1_t mem_slot1_payload
);

    wire ex_slot1_is_lsu = ex_slot1_valid
                         & (ex_slot1_payload.common.mem_read_en
                            | ex_slot1_payload.common.mem_write_en);
    wire ex_slot0_uses_priv_result =
        (ex_slot0_payload.priv_op == PRIV_REG)
        | (ex_slot0_payload.priv_op == PRIV_COUNTER)
        | (ex_slot0_payload.priv_op == PRIV_CPUCFG);
    wire ex_slot1_side_effect_kill = ex_slot0_branch_flush
                                   | ex_slot0_priv_trap
                                   | ex_slot1_addr_replay;
    wire ex_selected_lsu_read = ex_slot1_is_lsu
        ? (ex_slot1_payload.common.mem_read_en
           & ~ex_slot1_side_effect_kill)
        : (ex_slot0_payload.common.mem_read_en & ~ex_slot0_priv_trap);
    wire ex_selected_lsu_write = ex_slot1_is_lsu
        ? (ex_slot1_payload.common.mem_write_en
           & ~ex_slot1_side_effect_kill)
        : (ex_slot0_payload.common.mem_write_en & ~ex_slot0_priv_trap);
    wire ex_selected_lsu_cacheable = ex_slot1_is_lsu
        ? ex_slot1_is_cacheable : ex_slot0_is_cacheable;
    wire cache_req_reference = ex_slot0_valid & ~mem_branch_flush
        & (ex_selected_lsu_read | ex_selected_lsu_write)
        & (ex_selected_lsu_cacheable | AXI_UNCACHED_DATA);

    wire mem_store_active = (|mem_slot0_payload.store_wea)
                          | (|mem_slot1_payload.store_wea);
    wire mem_store_uncacheable =
        ((|mem_slot0_payload.store_wea) & ~mem_slot0_payload.is_cacheable)
        | ((|mem_slot1_payload.store_wea)
           & ~mem_slot1_payload.is_cacheable);
    wire mmio_store_load_hazard_reference = !AXI_UNCACHED_DATA
        & ex_selected_lsu_read
        & mem_store_active
        & mem_store_uncacheable;

    always_ff @(posedge clk) begin
        if (rst_n && (cache_req !== cache_req_reference))
            $fatal(1, "Late Slot-1 LSU kill changed DCache request validity");
        if (rst_n
                  && (mmio_store_load_hazard
                      !== mmio_store_load_hazard_reference))
            $fatal(1, "Late Slot-1 LSU kill changed MMIO store/load hazard");

        if (rst_n && ex_slot0_valid
                  && (ex_slot0_payload.common.mem_read_en
                      | ex_slot0_payload.common.mem_write_en)) begin
            if (ex_slot0_repair[3])
                $fatal(1, "Slot0 LSU unexpectedly repairs immediate source 2");
            if (ex_slot0_lsu_addr_low !== ex_slot0_alu_addr[18:0])
                $fatal(1, "Slot0 short LSU address disagrees with full address");
            if (ex_slot0_align_addr_low !== ex_slot0_alu_addr[1:0])
                $fatal(1, "Slot0 alignment address disagrees with full address");
        end
        if (rst_n && ex_slot1_valid
                  && (ex_slot1_payload.common.mem_read_en
                      | ex_slot1_payload.common.mem_write_en)) begin
            if (ex_slot1_repair[3])
                $fatal(1, "Slot1 LSU unexpectedly repairs immediate source 2");
            if (ex_slot1_lsu_addr_low !== ex_slot1_alu_addr[18:0])
                $fatal(1, "Slot1 short LSU address disagrees with full address");
            if (ex_slot1_align_addr_low !== ex_slot1_alu_addr[1:0])
                $fatal(1, "Slot1 alignment address disagrees with full address");
        end

        if (rst_n && ex_slot1_valid && ex_slot0_store_data_bypass) begin
            if (!(ex_slot0_valid
                  && ex_slot0_payload.common.reg_write_en
                  && (ex_slot0_payload.common.rd != 5'd0)
                  && ex_slot1_payload.common.mem_write_en
                  && (ex_slot1_payload.common.rs2_addr
                      == ex_slot0_payload.common.rd)
                  && (ex_slot1_payload.common.rs1_addr
                      != ex_slot0_payload.common.rd)
                  && !ex_slot0_payload.common.mem_read_en
                  && !ex_slot0_payload.common.mem_write_en
                  && !ex_slot0_uses_priv_result
                  && !ex_slot0_payload.is_muldiv))
                $fatal(1, "Invalid Slot0-ALU to Slot1-store-data bypass tag");
            if (ex_slot1_store_data !== ex_slot0_alu_result)
                $fatal(1, "Slot1 store-data bypass did not select Slot0 ALU result");
        end
    end

endmodule
`endif
