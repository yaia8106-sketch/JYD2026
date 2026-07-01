// ============================================================
// Module: load_hazard_ctrl
// Description: Load-use stall detection and MEM-load WB repair tagging.
// Domain: decode and issue.
//
// The forwarding network supplies whether a younger producer blocks each
// possible MEM-load repair source. This module owns only dependency policy;
// it does not select operand data.
// ============================================================

module load_hazard_ctrl (
    // Slot 0 ID consumer
    input  logic [4:0] id_rs1_addr,
    input  logic [4:0] id_rs2_addr,
    input  logic       id_rs1_used,
    input  logic       id_rs2_used,
    input  logic       id_s0_repair_ok,

    // Slot 1 ID consumer
    input  logic       id_s1_valid,
    input  logic [4:0] id_s1_rs1_addr,
    input  logic [4:0] id_s1_rs2_addr,
    input  logic       id_s1_rs1_used,
    input  logic       id_s1_rs2_used,
    input  logic       id_s1_repair_ok,

    // EX load producers
    input  logic       ex_valid,
    input  logic       ex_mem_read,
    input  logic [4:0] ex_rd,
    input  logic       ex_s1_valid,
    input  logic       ex_s1_mem_read,
    input  logic [4:0] ex_s1_rd,

    // MEM load producers
    input  logic       mem_valid,
    input  logic       mem_reg_write,
    input  logic       mem_is_load,
    input  logic [4:0] mem_rd,
    input  logic       mem_s1_valid,
    input  logic       mem_s1_reg_write,
    input  logic       mem_s1_is_load,
    input  logic [4:0] mem_s1_rd,
    input  logic       mem_load_ready,

    // Younger forwarding sources suppress an older MEM-load repair tag.
    input  logic       s0_rs1_blocks_s0_mem_repair,
    input  logic       s0_rs2_blocks_s0_mem_repair,
    input  logic       s1_rs1_blocks_s0_mem_repair,
    input  logic       s1_rs2_blocks_s0_mem_repair,
    input  logic       s0_rs1_blocks_s1_mem_repair,
    input  logic       s0_rs2_blocks_s1_mem_repair,
    input  logic       s1_rs1_blocks_s1_mem_repair,
    input  logic       s1_rs2_blocks_s1_mem_repair,

    // Repair tags carried into EX
    output logic       id_rs1_wb_repair,
    output logic       id_rs2_wb_repair,
    output logic       id_rs1_wb_repair_s1,
    output logic       id_rs2_wb_repair_s1,
    output logic       id_s1_rs1_wb_repair,
    output logic       id_s1_rs2_wb_repair,
    output logic       id_s1_rs1_wb_repair_s1,
    output logic       id_s1_rs2_wb_repair_s1,

    // Named observation outputs retained by the forwarding integration shell.
    output logic       id_s0_uses_ex_load,
    output logic       id_s1_uses_ex_load,
    output logic       id_s0_uses_s1_ex_load,
    output logic       id_s1_uses_s1_ex_load,
    output logic       id_s0_uses_mem_load,
    output logic       id_s1_uses_mem_load,
    output logic       id_s0_uses_s1_mem_load,
    output logic       id_s1_uses_s1_mem_load,
    output logic       load_in_ex,
    output logic       load_in_s1_ex,
    output logic       load_in_mem,
    output logic       load_in_s1_mem,
    output logic       load_use_hazard
);

    // A ready MEM load is registered in MEM/WB while its consumer advances.
    // The consumer then selects that registered value in EX on the next cycle.
    localparam logic ENABLE_MEM_LOAD_WB_REPAIR = 1'b1;

    wire mem_s0_load_pending = mem_valid & mem_is_load & (mem_rd != 5'd0);
    wire mem_s1_load_pending = mem_s1_valid & mem_s1_is_load
                             & (mem_s1_rd != 5'd0);
    wire mem_s0_load_repair_source = mem_s0_load_pending & mem_reg_write
                                   & mem_load_ready;
    wire mem_s1_load_repair_source = mem_s1_load_pending & mem_s1_reg_write
                                   & mem_load_ready;
    wire id_s0_has_mem_load_repair_path =
        ENABLE_MEM_LOAD_WB_REPAIR & id_s0_repair_ok;
    wire id_s1_has_mem_load_repair_path =
        ENABLE_MEM_LOAD_WB_REPAIR & id_s1_valid & id_s1_repair_ok;
    wire id_s0_can_repair_mem_load = id_s0_has_mem_load_repair_path
                                   & mem_load_ready;
    wire id_s1_can_repair_mem_load = id_s1_has_mem_load_repair_path
                                   & mem_load_ready;

    wire s0_rs1_uses_s0_mem_load = id_rs1_used & (mem_rd == id_rs1_addr);
    wire s0_rs2_uses_s0_mem_load = id_rs2_used & (mem_rd == id_rs2_addr);
    wire s1_rs1_uses_s0_mem_load = id_s1_valid & id_s1_rs1_used
                                 & (mem_rd == id_s1_rs1_addr);
    wire s1_rs2_uses_s0_mem_load = id_s1_valid & id_s1_rs2_used
                                 & (mem_rd == id_s1_rs2_addr);

    wire s0_rs1_uses_s1_mem_load = id_rs1_used & (mem_s1_rd == id_rs1_addr);
    wire s0_rs2_uses_s1_mem_load = id_rs2_used & (mem_s1_rd == id_rs2_addr);
    wire s1_rs1_uses_s1_mem_load = id_s1_valid & id_s1_rs1_used
                                 & (mem_s1_rd == id_s1_rs1_addr);
    wire s1_rs2_uses_s1_mem_load = id_s1_valid & id_s1_rs2_used
                                 & (mem_s1_rd == id_s1_rs2_addr);

    wire id_rs1_wb_repair_s0 = mem_s0_load_repair_source
                              & id_s0_has_mem_load_repair_path
                              & s0_rs1_uses_s0_mem_load
                              & ~s0_rs1_blocks_s0_mem_repair;
    wire id_rs2_wb_repair_s0 = mem_s0_load_repair_source
                              & id_s0_has_mem_load_repair_path
                              & s0_rs2_uses_s0_mem_load
                              & ~s0_rs2_blocks_s0_mem_repair;
    wire id_s1_rs1_wb_repair_s0 = mem_s0_load_repair_source
                                 & id_s1_has_mem_load_repair_path
                                 & s1_rs1_uses_s0_mem_load
                                 & ~s1_rs1_blocks_s0_mem_repair;
    wire id_s1_rs2_wb_repair_s0 = mem_s0_load_repair_source
                                 & id_s1_has_mem_load_repair_path
                                 & s1_rs2_uses_s0_mem_load
                                 & ~s1_rs2_blocks_s0_mem_repair;

    wire id_rs1_wb_repair_s1_w = mem_s1_load_repair_source
                                & id_s0_has_mem_load_repair_path
                                & s0_rs1_uses_s1_mem_load
                                & ~s0_rs1_blocks_s1_mem_repair;
    wire id_rs2_wb_repair_s1_w = mem_s1_load_repair_source
                                & id_s0_has_mem_load_repair_path
                                & s0_rs2_uses_s1_mem_load
                                & ~s0_rs2_blocks_s1_mem_repair;
    wire id_s1_rs1_wb_repair_s1_w = mem_s1_load_repair_source
                                   & id_s1_has_mem_load_repair_path
                                   & s1_rs1_uses_s1_mem_load
                                   & ~s1_rs1_blocks_s1_mem_repair;
    wire id_s1_rs2_wb_repair_s1_w = mem_s1_load_repair_source
                                   & id_s1_has_mem_load_repair_path
                                   & s1_rs2_uses_s1_mem_load
                                   & ~s1_rs2_blocks_s1_mem_repair;

    assign id_rs1_wb_repair = id_rs1_wb_repair_s0 | id_rs1_wb_repair_s1_w;
    assign id_rs2_wb_repair = id_rs2_wb_repair_s0 | id_rs2_wb_repair_s1_w;
    assign id_rs1_wb_repair_s1 = id_rs1_wb_repair_s1_w;
    assign id_rs2_wb_repair_s1 = id_rs2_wb_repair_s1_w;
    assign id_s1_rs1_wb_repair = id_s1_rs1_wb_repair_s0
                                | id_s1_rs1_wb_repair_s1_w;
    assign id_s1_rs2_wb_repair = id_s1_rs2_wb_repair_s0
                                | id_s1_rs2_wb_repair_s1_w;
    assign id_s1_rs1_wb_repair_s1 = id_s1_rs1_wb_repair_s1_w;
    assign id_s1_rs2_wb_repair_s1 = id_s1_rs2_wb_repair_s1_w;

    // ================================================================
    //  Load-use stall detection
    // ================================================================
    assign id_s0_uses_ex_load = (id_rs1_used & (ex_rd == id_rs1_addr))
                               | (id_rs2_used & (ex_rd == id_rs2_addr));
    assign id_s1_uses_ex_load = id_s1_valid
                               & ((id_s1_rs1_used & (ex_rd == id_s1_rs1_addr))
                                | (id_s1_rs2_used & (ex_rd == id_s1_rs2_addr)));
    assign load_in_ex = ex_valid & ex_mem_read & (ex_rd != 5'd0)
                      & (id_s0_uses_ex_load | id_s1_uses_ex_load);

    assign id_s0_uses_s1_ex_load =
        (id_rs1_used & (ex_s1_rd == id_rs1_addr))
      | (id_rs2_used & (ex_s1_rd == id_rs2_addr));
    assign id_s1_uses_s1_ex_load = id_s1_valid
                                  & ((id_s1_rs1_used
                                      & (ex_s1_rd == id_s1_rs1_addr))
                                   | (id_s1_rs2_used
                                      & (ex_s1_rd == id_s1_rs2_addr)));
    assign load_in_s1_ex = ex_s1_valid & ex_s1_mem_read & (ex_s1_rd != 5'd0)
                         & (id_s0_uses_s1_ex_load | id_s1_uses_s1_ex_load);

    wire id_s0_uses_s0_mem_load = s0_rs1_uses_s0_mem_load
                                 | s0_rs2_uses_s0_mem_load;
    wire id_s1_uses_s0_mem_load = s1_rs1_uses_s0_mem_load
                                 | s1_rs2_uses_s0_mem_load;
    assign id_s0_uses_mem_load = id_s0_uses_s0_mem_load;
    assign id_s1_uses_mem_load = id_s1_uses_s0_mem_load;
    assign id_s0_uses_s1_mem_load = s0_rs1_uses_s1_mem_load
                                   | s0_rs2_uses_s1_mem_load;
    assign id_s1_uses_s1_mem_load = s1_rs1_uses_s1_mem_load
                                   | s1_rs2_uses_s1_mem_load;

    wire id_s0_waits_s0_mem_load = mem_s0_load_pending
                                  & id_s0_uses_s0_mem_load
                                  & ~id_s0_can_repair_mem_load;
    wire id_s1_waits_s0_mem_load = mem_s0_load_pending
                                  & id_s1_uses_s0_mem_load
                                  & ~id_s1_can_repair_mem_load;
    wire id_s0_waits_s1_mem_load = mem_s1_load_pending
                                  & id_s0_uses_s1_mem_load
                                  & ~id_s0_can_repair_mem_load;
    wire id_s1_waits_s1_mem_load = mem_s1_load_pending
                                  & id_s1_uses_s1_mem_load
                                  & ~id_s1_can_repair_mem_load;

    assign load_in_mem = id_s0_waits_s0_mem_load | id_s1_waits_s0_mem_load;
    assign load_in_s1_mem = id_s0_waits_s1_mem_load | id_s1_waits_s1_mem_load;
    assign load_use_hazard = load_in_ex | load_in_s1_ex
                           | load_in_mem | load_in_s1_mem;

endmodule
