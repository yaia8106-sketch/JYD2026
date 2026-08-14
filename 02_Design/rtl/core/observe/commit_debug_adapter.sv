// ============================================================
// 中文说明：把写回提交信息整理成调试和比赛接口使用的格式。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：commit_debug_adapter。
// 说明：把两个 WB payload 适配为扁平的 NSCSCC 提交/调试接口。
// 本模块不保存架构状态。
// ============================================================

module commit_debug_adapter (
    input  logic        wb_slot0_valid,
    input  logic [31:0] wb_slot0_pc,
    input  logic [31:0] wb_slot0_inst,
    input  logic [ 4:0] wb_slot0_rd,
    input  logic        wb_slot0_reg_write,
    input  logic [31:0] wb_slot0_write_data,
    input  logic        wb_slot0_is_load,
    input  logic        wb_slot0_is_store,
    input  logic [ 1:0] wb_slot0_mem_size,
    input  logic        wb_slot0_mem_unsigned,
    input  logic [31:0] wb_slot0_mem_addr,
    input  logic [31:0] wb_slot0_store_data,
    input  logic        wb_slot0_exception,
    input  logic        wb_slot0_csr_rstat,
    input  logic [31:0] wb_slot0_csr_data,

    input  logic        wb_slot1_valid,
    input  logic [31:0] wb_slot1_pc,
    input  logic [31:0] wb_slot1_inst,
    input  logic [ 4:0] wb_slot1_rd,
    input  logic        wb_slot1_reg_write,
    input  logic [31:0] wb_slot1_write_data,
    input  logic        wb_slot1_is_load,
    input  logic        wb_slot1_is_store,
    input  logic [ 1:0] wb_slot1_mem_size,
    input  logic        wb_slot1_mem_unsigned,
    input  logic [31:0] wb_slot1_mem_addr,
    input  logic [31:0] wb_slot1_store_data,

    output logic        debug0_wb_valid,
    output logic [31:0] debug0_wb_pc,
    output logic [ 3:0] debug0_wb_rf_wen,
    output logic [ 4:0] debug0_wb_rf_wnum,
    output logic [31:0] debug0_wb_rf_wdata,
    output logic [31:0] debug0_wb_inst,
    output logic        debug0_wb_exception,
    output logic        debug0_wb_mem_read,
    output logic        debug0_wb_mem_write,
    output logic [ 1:0] debug0_wb_mem_size,
    output logic        debug0_wb_mem_unsigned,
    output logic [31:0] debug0_wb_mem_addr,
    output logic [31:0] debug0_wb_store_data,
    output logic        debug0_wb_csr_rstat,
    output logic [31:0] debug0_wb_csr_data,

    output logic        debug1_wb_valid,
    output logic [31:0] debug1_wb_pc,
    output logic [ 3:0] debug1_wb_rf_wen,
    output logic [ 4:0] debug1_wb_rf_wnum,
    output logic [31:0] debug1_wb_rf_wdata,
    output logic [31:0] debug1_wb_inst,
    output logic        debug1_wb_mem_read,
    output logic        debug1_wb_mem_write,
    output logic [ 1:0] debug1_wb_mem_size,
    output logic        debug1_wb_mem_unsigned,
    output logic [31:0] debug1_wb_mem_addr,
    output logic [31:0] debug1_wb_store_data
);

    assign debug0_wb_valid = wb_slot0_valid & ~wb_slot0_exception;
    assign debug0_wb_pc = wb_slot0_pc;
    assign debug0_wb_rf_wen = {4{
        wb_slot0_valid
        & wb_slot0_reg_write
        & ~wb_slot0_exception
        & (wb_slot0_rd != 5'd0)
    }};
    assign debug0_wb_rf_wnum = wb_slot0_rd;
    assign debug0_wb_rf_wdata = wb_slot0_write_data;
    assign debug0_wb_inst = wb_slot0_inst;
    assign debug0_wb_exception = wb_slot0_valid & wb_slot0_exception;
    assign debug0_wb_mem_read = wb_slot0_valid & wb_slot0_is_load
                              & ~wb_slot0_exception;
    assign debug0_wb_mem_write = wb_slot0_valid & wb_slot0_is_store
                               & ~wb_slot0_exception;
    assign debug0_wb_mem_size = wb_slot0_mem_size;
    assign debug0_wb_mem_unsigned = wb_slot0_mem_unsigned;
    assign debug0_wb_mem_addr = wb_slot0_mem_addr;
    assign debug0_wb_store_data = wb_slot0_store_data;
    assign debug0_wb_csr_rstat = wb_slot0_valid
                               & wb_slot0_csr_rstat
                               & ~wb_slot0_exception;
    assign debug0_wb_csr_data = wb_slot0_csr_data;

    assign debug1_wb_valid = wb_slot1_valid;
    assign debug1_wb_pc = wb_slot1_pc;
    assign debug1_wb_rf_wen = {4{
        wb_slot1_valid
        & wb_slot1_reg_write
        & (wb_slot1_rd != 5'd0)
    }};
    assign debug1_wb_rf_wnum = wb_slot1_rd;
    assign debug1_wb_rf_wdata = wb_slot1_write_data;
    assign debug1_wb_inst = wb_slot1_inst;
    assign debug1_wb_mem_read = wb_slot1_valid & wb_slot1_is_load;
    assign debug1_wb_mem_write = wb_slot1_valid & wb_slot1_is_store;
    assign debug1_wb_mem_size = wb_slot1_mem_size;
    assign debug1_wb_mem_unsigned = wb_slot1_mem_unsigned;
    assign debug1_wb_mem_addr = wb_slot1_mem_addr;
    assign debug1_wb_store_data = wb_slot1_store_data;

endmodule
