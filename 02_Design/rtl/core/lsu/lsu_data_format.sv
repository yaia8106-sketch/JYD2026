// ============================================================
// Module: lsu_data_format
// Description: Format the single LSU's store requests and load response.
// Domain: load/store unit.
//
// The two issue slots have independent EX store-format candidates, but issue
// policy permits only one LSU operation per pair. The MEM load formatter is
// shared because only one load response can return in a cycle.
// ============================================================

module lsu_data_format #(
    // NSCSCC's DCache returns an already extracted and extended load value.
    // Other platforms return a raw aligned word and use mem_interface below.
    parameter bit CACHE_RDATA_FORMATTED = 1'b0
) (
    // Slot 0 EX store candidate.
    input  logic        ex_slot0_valid,
    input  logic        ex_slot0_kill,
    input  logic        ex_slot0_store,
    input  logic [ 1:0] ex_slot0_addr_low,
    input  logic [ 1:0] ex_slot0_mem_size,
    input  logic [31:0] ex_slot0_store_data,
    output logic [ 3:0] ex_slot0_store_wea,

    // Slot 1 EX store candidate.
    input  logic        ex_slot1_valid,
    input  logic        ex_slot1_kill,
    input  logic        ex_slot1_store,
    input  logic [ 1:0] ex_slot1_addr_low,
    input  logic [ 1:0] ex_slot1_mem_size,
    input  logic [31:0] ex_slot1_store_data,
    output logic [ 3:0] ex_slot1_store_wea,

    // Shared MEM load response.
    input  logic        mem_load_en,
    input  logic [ 1:0] mem_load_addr_low,
    input  logic [ 1:0] mem_load_size,
    input  logic        mem_load_unsigned,
    input  logic [31:0] mem_load_data,
    input  logic [31:0] mem_load_data_ex,
    output logic [31:0] mem_load_result,
    output logic [31:0] mem_load_repair_result
);

    logic [31:0] raw_load_result;

    mem_interface u_slot0_store_format (
        .store_valid    (ex_slot0_valid & ~ex_slot0_kill),
        .store_en       (ex_slot0_store),
        .store_addr_low (ex_slot0_addr_low),
        .store_mem_size (ex_slot0_mem_size),
        .store_data_in  (ex_slot0_store_data),
        .store_wea      (ex_slot0_store_wea),
        .store_data_out (),
        .load_en        (mem_load_en),
        .load_addr_low  (mem_load_addr_low),
        .load_mem_size  (mem_load_size),
        .load_unsigned  (mem_load_unsigned),
        .load_dram_dout (mem_load_data),
        .load_data_out  (raw_load_result)
    );

    mem_interface u_slot1_store_format (
        .store_valid    (ex_slot1_valid & ~ex_slot1_kill),
        .store_en       (ex_slot1_store),
        .store_addr_low (ex_slot1_addr_low),
        .store_mem_size (ex_slot1_mem_size),
        .store_data_in  (ex_slot1_store_data),
        .store_wea      (ex_slot1_store_wea),
        .store_data_out (),
        .load_en        (1'b0),
        .load_addr_low  (2'd0),
        .load_mem_size  (2'd0),
        .load_unsigned  (1'b0),
        .load_dram_dout (32'd0),
        .load_data_out  ()
    );

    assign mem_load_result = CACHE_RDATA_FORMATTED
                           ? mem_load_data : raw_load_result;
    assign mem_load_repair_result = CACHE_RDATA_FORMATTED
                                  ? mem_load_data_ex : raw_load_result;

endmodule
