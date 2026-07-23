// ============================================================
// Module: memory_access_unit
// Description: EX1 Cache request routing, EX2 load completion and MEM stores.
// Domain: load/store unit.
// ============================================================

module memory_access_unit #(
    parameter logic [31:0] CACHE_ADDR_BASE = 32'h8010_0000,
    parameter logic [31:0] CACHE_ADDR_MASK = 32'hFFFC_0000,
    parameter bit AXI_UNCACHED_DATA = 1'b0
) (
    input  logic        ex1_valid,
    input  logic        ex1_ready_go,
    input  logic        ex1_younger_flush,
    input  logic        ex1_mem_read_en,
    input  logic        ex1_mem_write_en,
    input  logic [31:0] ex1_alu_addr,
    input  logic [ 1:0] ex1_mem_size,
    input  logic [ 3:0] ex1_store_wea,
    input  logic        ex1_s1_valid,
    input  logic        ex1_s1_mem_read_en,
    input  logic        ex1_s1_mem_write_en,
    input  logic [31:0] ex1_s1_alu_addr,
    input  logic [ 1:0] ex1_s1_mem_size,
    input  logic [ 3:0] ex1_s1_store_wea,

    input  logic        ex2_valid,
    input  logic [31:0] ex2_alu_addr,
    input  logic        ex2_mem_read_en,
    input  logic        ex2_mem_write_en,
    input  logic [31:0] ex2_store_data,
    input  logic        ex2_is_cacheable,
    input  logic        ex2_s1_valid,
    input  logic [31:0] ex2_s1_alu_addr,
    input  logic        ex2_s1_mem_read_en,
    input  logic        ex2_s1_mem_write_en,
    input  logic [31:0] ex2_s1_store_data,
    input  logic        ex2_s1_is_cacheable,
    input  logic        ex2_lsu_kill,
    input  logic        ex2_allowin,

    input  logic        mem_valid,
    input  logic [31:0] mem_alu_result,
    input  logic        mem_mem_read_en,
    input  logic [ 3:0] mem_store_wea,
    input  logic [31:0] mem_store_data,
    input  logic        mem_is_cacheable,
    input  logic        mem_s1_valid,
    input  logic [31:0] mem_s1_alu_result,
    input  logic        mem_s1_mem_read_en,
    input  logic        mem_s1_mem_write_en,
    input  logic [ 3:0] mem_s1_store_wea,
    input  logic [31:0] mem_s1_store_data,
    input  logic        mem_s1_is_cacheable,
    input  logic        mem_branch_flush,

    input  logic [31:0] cache_rdata,
    input  logic        cache_ready,
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
    output logic [ 3:0] cache_load_mask,
    output logic        cache_uncached,
    output logic        cache_flush,
    output logic        cache_pipeline_stall,

    output logic [31:0] mmio_addr,
    output logic [31:0] mmio_wr_addr,
    output logic [ 3:0] mmio_wea,
    output logic [31:0] mmio_wdata,

    output logic [31:0] ex2_load_data,
    output logic        ex2_load_ready
);

    localparam logic [31:0] DUAL_ISSUE_CNT_ADDR = 32'h8020_0060;

    // The shared LSU chooses Slot 1 only when Slot 0 is not using memory.
    wire ex1_s0_lsu = ex1_mem_read_en | ex1_mem_write_en;
    wire ex1_s1_lsu = ex1_s1_valid
                    & (ex1_s1_mem_read_en | ex1_s1_mem_write_en);
    wire ex1_use_s1_lsu = ~ex1_s0_lsu & ex1_s1_lsu;
    wire [31:0] ex1_lsu_addr = ex1_use_s1_lsu
                             ? ex1_s1_alu_addr : ex1_alu_addr;
    wire ex1_lsu_read = ex1_use_s1_lsu
                      ? ex1_s1_mem_read_en : ex1_mem_read_en;
    wire ex1_lsu_write = ex1_use_s1_lsu
                       ? ex1_s1_mem_write_en : ex1_mem_write_en;
    wire [1:0] ex1_lsu_size = ex1_use_s1_lsu
                            ? ex1_s1_mem_size : ex1_mem_size;
    wire [3:0] ex1_lsu_wea = ex1_use_s1_lsu
                           ? ex1_s1_store_wea : ex1_store_wea;
    wire ex1_lsu_cacheable = ex1_use_s1_lsu
                           ? is_cacheable_s1 : is_cacheable;
    // Precompute load-byte candidates in EX1; DCache registers the selected
    // mask with the request for recent-store coverage checks.
    wire [3:0] ex1_load_byte_mask = 4'b0001 << ex1_lsu_addr[1:0];
    wire [3:0] ex1_load_half_mask = 4'b0011 << ex1_lsu_addr[1:0];

    // Store data may be repaired only in EX2, so it deliberately bypasses the
    // DCache's EX1 request register and remains aligned with that held request.
    wire ex2_s0_lsu = ex2_mem_read_en | ex2_mem_write_en;
    wire ex2_s1_lsu = ex2_s1_valid
                    & (ex2_s1_mem_read_en | ex2_s1_mem_write_en);
    wire ex2_use_s1_lsu = ~ex2_s0_lsu & ex2_s1_lsu;
    wire [31:0] ex2_lsu_addr = ex2_use_s1_lsu
                             ? ex2_s1_alu_addr : ex2_alu_addr;
    wire ex2_lsu_read = ex2_use_s1_lsu
                      ? ex2_s1_mem_read_en : ex2_mem_read_en;
    wire ex2_lsu_write = ex2_use_s1_lsu
                       ? ex2_s1_mem_write_en : ex2_mem_write_en;
    wire [31:0] ex2_lsu_wdata = ex2_use_s1_lsu
                              ? ex2_s1_store_data : ex2_store_data;
    wire ex2_lsu_cacheable = ex2_use_s1_lsu
                           ? ex2_s1_is_cacheable : ex2_is_cacheable;
    wire ex2_store_uncacheable = ex2_valid & ex2_lsu_write
                               & ~ex2_lsu_cacheable;

    // store_wea is generated with valid/write gating in EX1 and is masked again
    // at the EX2/MEM Slot-1 boundary. Use that registered one-hot payload directly
    // so redundant valid/write predicates do not enter MMIO read arbitration.
    wire        mem_s0_store_active = |mem_store_wea;
    wire        mem_s1_store_active = |mem_s1_store_wea;
    wire        mem_use_s1_store = mem_s1_store_active;
    wire [31:0] mem_store_addr = mem_use_s1_store ? mem_s1_alu_result : mem_alu_result;
    wire [ 3:0] mem_selected_store_wea = mem_use_s1_store ? mem_s1_store_wea : mem_store_wea;
    wire [31:0] mem_selected_store_data = mem_use_s1_store ? mem_s1_store_data : mem_store_data;
    wire [31:0] mem_selected_store_data_aligned =
        mem_selected_store_data << {mem_store_addr[1:0], 3'b0};
    wire        mem_selected_store_cacheable = mem_use_s1_store ? mem_s1_is_cacheable : mem_is_cacheable;
    wire        mem_store_active = mem_s1_store_active | mem_s0_store_active;
    wire        mem_store_uncacheable = (mem_s0_store_active & ~mem_is_cacheable)
                                      | (mem_s1_store_active & ~mem_s1_is_cacheable);

    wire dual_issue_cnt_read = (ex2_lsu_addr == DUAL_ISSUE_CNT_ADDR);
    wire [31:0] mmio_load_data = dual_issue_cnt_read ? dual_issue_count : mmio_rdata;

    // The cacheable window is platform-owned.  JYD keeps its 0x8010_0000
    // private DRAM window; NSCSCC selects the LA32R data SRAM window without
    // introducing ISA macros into this shared LSU.
    assign is_cacheable = (ex1_alu_addr & CACHE_ADDR_MASK)
                        == (CACHE_ADDR_BASE & CACHE_ADDR_MASK);
    assign is_cacheable_s1 = (ex1_s1_alu_addr & CACHE_ADDR_MASK)
                           == (CACHE_ADDR_BASE & CACHE_ADDR_MASK);

    // An uncacheable store becomes externally visible in MEM.  A younger
    // EX1 load must therefore wait while that store is either in EX2 or MEM;
    // otherwise the one-cycle MMIO read can sample the old word on the same
    // edge that the store is finally written.
    assign mmio_st_ld_hazard = !AXI_UNCACHED_DATA
                             & ex1_lsu_read
                             & (ex2_store_uncacheable
                                | (mem_store_active
                                   & mem_store_uncacheable));

    assign cache_req = ex1_valid & ex1_ready_go
                     & ~mem_branch_flush & ~ex1_younger_flush
                     & (ex1_lsu_read | ex1_lsu_write)
                     & (ex1_lsu_cacheable | AXI_UNCACHED_DATA);
    assign cache_wr = ex1_lsu_write;
    assign cache_addr = ex1_lsu_addr;
    assign cache_wea = ex1_lsu_wea;
    assign cache_wdata = ex2_lsu_wdata;
    assign cache_load_mask =
        ({4{ex1_lsu_size == 2'b00}} & ex1_load_byte_mask)
      | ({4{ex1_lsu_size == 2'b01}} & ex1_load_half_mask)
      | ({4{ex1_lsu_size == 2'b10}} & 4'b1111);
    assign cache_uncached = AXI_UNCACHED_DATA & ~ex1_lsu_cacheable;
    assign cache_flush = mem_branch_flush | ex2_lsu_kill;
    assign cache_pipeline_stall = ~ex2_allowin;

    assign mmio_addr = ex1_lsu_addr;
    assign mmio_wr_addr = mem_store_addr;
    assign mmio_wea = (mem_store_active & ~mem_selected_store_cacheable
                       & ~AXI_UNCACHED_DATA)
                    ? mem_selected_store_wea : 4'b0000;
    assign mmio_wdata = mem_selected_store_data_aligned;

    assign ex2_load_data = (ex2_lsu_cacheable | AXI_UNCACHED_DATA)
                         ? cache_rdata : mmio_load_data;
    assign ex2_load_ready = cache_ready & ex2_valid & ex2_lsu_read
                          & ~ex2_lsu_kill;

endmodule
