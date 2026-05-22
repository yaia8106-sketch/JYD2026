// ============================================================
// Module: memory_access_unit
// Description: Cache/MMIO request routing and MEM-stage load data muxing.
// ============================================================

module memory_access_unit (
    input  logic        ex_valid,
    input  logic        ex_mem_read_en,
    input  logic        ex_mem_write_en,
    input  logic [31:0] ex_alu_addr,
    input  logic [ 3:0] ex_store_wea,
    input  logic [31:0] ex_store_data,
    input  logic        ex_s1_valid,
    input  logic        ex_s1_mem_read_en,
    input  logic [31:0] ex_s1_alu_addr,

    input  logic        mem_valid,
    input  logic [31:0] mem_alu_result,
    input  logic        mem_mem_read_en,
    input  logic [ 3:0] mem_store_wea,
    input  logic [31:0] mem_store_data,
    input  logic        mem_is_cacheable,
    input  logic        mem_s1_valid,
    input  logic [31:0] mem_s1_alu_result,
    input  logic        mem_s1_mem_read_en,
    input  logic        mem_s1_is_cacheable,
    input  logic        mem_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,

    input  logic [31:0] cache_rdata,
    input  logic [31:0] mmio_rdata,
    input  logic [31:0] dual_issue_count,

    output logic        is_cacheable,
    output logic        is_cacheable_s1,
    output logic        mmio_st_ld_hazard,

    output logic        cache_req,
    output logic        cache_wr,
    output logic [31:0] cache_addr,
    output logic [ 3:0] cache_wea,
    output logic [31:0] cache_wdata,
    output logic        cache_flush,
    output logic        cache_pipeline_stall,

    output logic [31:0] mmio_addr,
    output logic [31:0] mmio_wr_addr,
    output logic [ 3:0] mmio_wea,
    output logic [31:0] mmio_wdata,

    output logic [31:0] mem_load_data,
    output logic        mem_load_ready
);

    localparam logic [31:0] DUAL_ISSUE_CNT_ADDR = 32'h8020_0060;

    wire ex_s0_lsu = ex_mem_read_en | ex_mem_write_en;
    wire ex_s1_lsu = ex_s1_valid & ex_s1_mem_read_en;
    wire ex_use_s1_lsu = ~ex_s0_lsu & ex_s1_lsu;
    wire [31:0] ex_lsu_addr = ex_use_s1_lsu ? ex_s1_alu_addr : ex_alu_addr;
    wire        ex_lsu_read = ex_use_s1_lsu ? ex_s1_mem_read_en : ex_mem_read_en;
    wire        ex_lsu_write = ~ex_use_s1_lsu & ex_mem_write_en;
    wire [ 3:0] ex_lsu_wea = ex_use_s1_lsu ? 4'b0000 : ex_store_wea;
    wire [31:0] ex_lsu_wdata = ex_use_s1_lsu ? 32'd0 : ex_store_data;
    wire        ex_lsu_cacheable = ex_use_s1_lsu ? is_cacheable_s1 : is_cacheable;

    wire mem_s1_load_active = mem_s1_valid & mem_s1_mem_read_en;
    wire [31:0] mem_lsu_addr = mem_s1_load_active ? mem_s1_alu_result : mem_alu_result;
    wire        mem_lsu_cacheable = mem_s1_load_active ? mem_s1_is_cacheable : mem_is_cacheable;

    wire dual_issue_cnt_read = (mem_lsu_addr == DUAL_ISSUE_CNT_ADDR);
    wire [31:0] mmio_load_data = dual_issue_cnt_read ? dual_issue_count : mmio_rdata;

    assign is_cacheable = ex_alu_addr[20] & ~ex_alu_addr[21]
                        & ~ex_alu_addr[19] & ~ex_alu_addr[18];
    assign is_cacheable_s1 = ex_s1_alu_addr[20] & ~ex_s1_alu_addr[21]
                           & ~ex_s1_alu_addr[19] & ~ex_s1_alu_addr[18];

    assign mmio_st_ld_hazard = ex_lsu_read
                             & mem_valid
                             & (|mem_store_wea)
                             & ~mem_is_cacheable;

    assign cache_req = ex_valid & ~mem_branch_flush
                     & (ex_lsu_read | ex_lsu_write)
                     & ex_lsu_cacheable;
    assign cache_wr = ex_lsu_write;
    assign cache_addr = ex_lsu_addr;
    assign cache_wea = ex_lsu_wea;
    assign cache_wdata = ex_lsu_wdata;
    assign cache_flush = mem_branch_flush;
    assign cache_pipeline_stall = ~mem_allowin;

    assign mmio_addr = ex_lsu_addr;
    assign mmio_wr_addr = mem_alu_result;
    assign mmio_wea = (mem_valid & ~mem_is_cacheable) ? mem_store_wea : 4'b0000;
    assign mmio_wdata = mem_store_data;

    assign mem_load_data = mem_lsu_cacheable ? cache_rdata : mmio_load_data;
    assign mem_load_ready = mem_ready_go & (mem_mem_read_en | mem_s1_mem_read_en);

endmodule
