// ============================================================
// 中文说明：按照 load 或 store 的大小、符号属性和地址低位完成数据扩展与写掩码生成。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：lsu_data_format。
// 说明：整理唯一 LSU 的 store 请求和 load 响应。
// 所属单元：load/store。
// 两个发射槽分别计算 EX store 格式候选，但发射策略保证每组最多只有一个
// LSU 操作。MEM 的 load 格式器可以共用，因为每周期最多返回一个 load 结果。
// ============================================================

module lsu_data_format #(
    // NSCSCC 的 DCache 返回已经提取并扩展好的 load 值。
    // 其他平台返回原始对齐字，并使用下面的 mem_interface 处理。
    parameter bit CACHE_RDATA_FORMATTED = 1'b0
) (
    // Slot0 EX store 候选。
    input  logic        ex_slot0_valid,
    input  logic        ex_slot0_kill,
    input  logic        ex_slot0_store,
    input  logic [ 1:0] ex_slot0_addr_low,
    input  logic [ 1:0] ex_slot0_mem_size,
    input  logic [31:0] ex_slot0_store_data,
    output logic [ 3:0] ex_slot0_store_wea,

    // Slot1 EX store 候选。
    input  logic        ex_slot1_valid,
    input  logic        ex_slot1_kill,
    input  logic        ex_slot1_store,
    input  logic [ 1:0] ex_slot1_addr_low,
    input  logic [ 1:0] ex_slot1_mem_size,
    input  logic [31:0] ex_slot1_store_data,
    output logic [ 3:0] ex_slot1_store_wea,

    // 共用的 MEM load 响应。
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
