`timescale 1ns / 1ps
// ============================================================
// Chiplab contract:
//   file   : mycpu_top.v
//   module : core_top
// ISA/platform contract:
//   LA32R sources are selected only by platform/nscscc/filelist.f.
//   This wrapper never compiles into the JYD RISC-V BRAM build.
// ============================================================

module core_top #(
    parameter TLBNUM = 32
) (
    input  wire         aclk,
    input  wire         aresetn,
    input  wire  [ 7:0] intrpt,

    output wire  [ 3:0] arid,
    output wire  [31:0] araddr,
    output wire  [ 7:0] arlen,
    output wire  [ 2:0] arsize,
    output wire  [ 1:0] arburst,
    output wire  [ 1:0] arlock,
    output wire  [ 3:0] arcache,
    output wire  [ 2:0] arprot,
    output wire         arvalid,
    input  wire         arready,
    input  wire  [ 3:0] rid,
    input  wire  [31:0] rdata,
    input  wire  [ 1:0] rresp,
    input  wire         rlast,
    input  wire         rvalid,
    output wire         rready,

    output wire  [ 3:0] awid,
    output wire  [31:0] awaddr,
    output wire  [ 7:0] awlen,
    output wire  [ 2:0] awsize,
    output wire  [ 1:0] awburst,
    output wire  [ 1:0] awlock,
    output wire  [ 3:0] awcache,
    output wire  [ 2:0] awprot,
    output wire         awvalid,
    input  wire         awready,
    output wire  [ 3:0] wid,
    output wire  [31:0] wdata,
    output wire  [ 3:0] wstrb,
    output wire         wlast,
    output wire         wvalid,
    input  wire         wready,
    input  wire  [ 3:0] bid,
    input  wire  [ 1:0] bresp,
    input  wire         bvalid,
    output wire         bready,

    input  wire         break_point,
    input  wire         infor_flag,
    input  wire  [ 4:0] reg_num,
    output wire         ws_valid,
    output wire  [31:0] rf_rdata,

    output wire  [31:0] debug0_wb_pc,
    output wire  [ 3:0] debug0_wb_rf_wen,
    output wire  [ 4:0] debug0_wb_rf_wnum,
    output wire  [31:0] debug0_wb_rf_wdata,
    output wire  [31:0] debug0_wb_inst
`ifdef CPU_2CMT
    ,
    output wire  [31:0] debug1_wb_pc,
    output wire  [ 3:0] debug1_wb_rf_wen,
    output wire  [ 4:0] debug1_wb_rf_wnum,
    output wire  [31:0] debug1_wb_rf_wdata
`endif
);

    reg  [1:0] reset_pipe;
    wire       core_rst_n;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)
            reset_pipe <= 2'b00;
        else
            reset_pipe <= {reset_pipe[0], 1'b1};
    end
    assign core_rst_n = reset_pipe[1];

    wire        irom_req_valid;
    wire        irom_req_ready;
    wire [31:0] irom_req_addr;
    wire        irom_resp_valid;
    wire [63:0] irom_resp_data;

    wire        cache_req;
    wire        cache_wr;
    wire [31:0] cache_addr;
    wire [ 3:0] cache_wea;
    wire [31:0] cache_wdata;
    wire [ 3:0] cache_load_mask;
    wire        cache_uncached;
    wire [31:0] cache_rdata;
    wire        cache_ready;
    wire        cache_flush;
    wire        cache_pipeline_stall;

    wire        dmem_req_valid;
    wire        dmem_req_ready;
    wire        dmem_req_write;
    wire [31:0] dmem_req_addr;
    wire [ 7:0] dmem_req_len;
    wire [31:0] dmem_req_wdata;
    wire [ 3:0] dmem_req_wstrb;
    wire        dmem_rd_valid;
    wire        dmem_rd_ready;
    wire [31:0] dmem_rd_data;
    wire        dmem_rd_last;
    wire [ 1:0] dmem_rd_resp;
    wire        dmem_rd_cancel;
    wire        dmem_wr_valid;
    wire        dmem_wr_ready;
    wire [ 1:0] dmem_wr_resp;

    wire        debug0_wb_valid_i;
    wire        debug1_wb_valid_i;
    wire [31:0] debug1_wb_pc_i;
    wire [ 3:0] debug1_wb_rf_wen_i;
    wire [ 4:0] debug1_wb_rf_wnum_i;
    wire [31:0] debug1_wb_rf_wdata_i;

    cpu_top #(
        .IROM_VARIABLE_LATENCY(1'b1),
        .RESET_PC            (32'h1C00_0000),
        .CACHE_ADDR_BASE     (32'h1C08_0000),
        .CACHE_ADDR_MASK     (32'hFFF8_0000),
        .AXI_UNCACHED_DATA   (1'b1)
    ) u_cpu (
        .clk                 (aclk),
        .rst_n               (core_rst_n),
        .irom_addr           (),
        .irom_req_valid      (irom_req_valid),
        .irom_req_addr       (irom_req_addr),
        .irom_req_ready      (irom_req_ready),
        .irom_resp_valid     (irom_resp_valid),
        .irom_data           (irom_resp_data),
        .cache_req           (cache_req),
        .cache_wr            (cache_wr),
        .cache_addr          (cache_addr),
        .cache_wea           (cache_wea),
        .cache_wdata         (cache_wdata),
        .cache_load_mask     (cache_load_mask),
        .cache_uncached      (cache_uncached),
        .cache_rdata         (cache_rdata),
        .cache_ready         (cache_ready),
        .cache_flush         (cache_flush),
        .cache_pipeline_stall(cache_pipeline_stall),
        .mmio_addr           (),
        .mmio_wr_addr        (),
        .mmio_wea            (),
        .mmio_wdata          (),
        .mmio_rdata          (32'd0),
        .timer_irq_pending   (|intrpt),
        .debug0_wb_valid     (debug0_wb_valid_i),
        .debug0_wb_pc        (debug0_wb_pc),
        .debug0_wb_rf_wen    (debug0_wb_rf_wen),
        .debug0_wb_rf_wnum   (debug0_wb_rf_wnum),
        .debug0_wb_rf_wdata  (debug0_wb_rf_wdata),
        .debug1_wb_valid     (debug1_wb_valid_i),
        .debug1_wb_pc        (debug1_wb_pc_i),
        .debug1_wb_rf_wen    (debug1_wb_rf_wen_i),
        .debug1_wb_rf_wnum   (debug1_wb_rf_wnum_i),
        .debug1_wb_rf_wdata  (debug1_wb_rf_wdata_i)
    );

    dcache #(
        .BACKEND_CANCEL     (1'b0),
        .DIRECT_BRAM        (1'b0),
        .CRITICAL_WORD_FIRST(1'b0),
        .PHYS_ADDR_WIDTH    (32),
        .UNCACHED_ENABLE    (1'b1)
    ) u_dcache (
        .clk                 (aclk),
        .rst_n               (core_rst_n),
        .cpu_req             (cache_req),
        .cpu_wr              (cache_wr),
        .cpu_addr            (cache_addr),
        .cpu_wea             (cache_wea),
        .cpu_wdata           (cache_wdata),
        .cpu_load_mask       (cache_load_mask),
        .cpu_uncached        (cache_uncached),
        .cpu_rdata           (cache_rdata),
        .cpu_ready           (cache_ready),
        .pipeline_stall      (cache_pipeline_stall),
        .flush               (cache_flush),
        .mem_req_valid       (dmem_req_valid),
        .mem_req_ready       (dmem_req_ready),
        .mem_req_write       (dmem_req_write),
        .mem_req_addr        (dmem_req_addr),
        .mem_req_len         (dmem_req_len),
        .mem_req_wdata       (dmem_req_wdata),
        .mem_req_wstrb       (dmem_req_wstrb),
        .mem_rd_valid        (dmem_rd_valid),
        .mem_rd_ready        (dmem_rd_ready),
        .mem_rd_data         (dmem_rd_data),
        .mem_rd_last         (dmem_rd_last),
        .mem_rd_resp         (dmem_rd_resp),
        .mem_rd_cancel       (dmem_rd_cancel),
        .mem_wr_valid        (dmem_wr_valid),
        .mem_wr_ready        (dmem_wr_ready),
        .mem_wr_resp         (dmem_wr_resp),
        .bram_rd_en          (),
        .bram_rd_addr        (),
        .bram_rd_data        (32'd0),
        .bram_wr_addr        (),
        .bram_wea            (),
        .bram_wdata          ()
    );

    nscscc_axi_bridge u_nscscc_axi_bridge (
        .clk            (aclk),
        .rst_n          (core_rst_n),
        .irom_req_valid (irom_req_valid),
        .irom_req_ready (irom_req_ready),
        .irom_req_addr  (irom_req_addr),
        .irom_resp_valid(irom_resp_valid),
        .irom_resp_data (irom_resp_data),
        .dmem_req_valid (dmem_req_valid),
        .dmem_req_ready (dmem_req_ready),
        .dmem_req_write (dmem_req_write),
        .dmem_req_addr  (dmem_req_addr),
        .dmem_req_len   (dmem_req_len),
        .dmem_req_wdata (dmem_req_wdata),
        .dmem_req_wstrb (dmem_req_wstrb),
        .dmem_rd_valid  (dmem_rd_valid),
        .dmem_rd_ready  (dmem_rd_ready),
        .dmem_rd_data   (dmem_rd_data),
        .dmem_rd_last   (dmem_rd_last),
        .dmem_rd_resp   (dmem_rd_resp),
        .dmem_rd_cancel (dmem_rd_cancel),
        .dmem_wr_valid  (dmem_wr_valid),
        .dmem_wr_ready  (dmem_wr_ready),
        .dmem_wr_resp   (dmem_wr_resp),
        .arid           (arid),
        .araddr         (araddr),
        .arlen          (arlen),
        .arsize         (arsize),
        .arburst        (arburst),
        .arlock         (arlock),
        .arcache        (arcache),
        .arprot         (arprot),
        .arvalid        (arvalid),
        .arready        (arready),
        .rid            (rid),
        .rdata          (rdata),
        .rresp          (rresp),
        .rlast          (rlast),
        .rvalid         (rvalid),
        .rready         (rready),
        .awid           (awid),
        .awaddr         (awaddr),
        .awlen          (awlen),
        .awsize         (awsize),
        .awburst        (awburst),
        .awlock         (awlock),
        .awcache        (awcache),
        .awprot         (awprot),
        .awvalid        (awvalid),
        .awready        (awready),
        .wid            (wid),
        .wdata          (wdata),
        .wstrb          (wstrb),
        .wlast          (wlast),
        .wvalid         (wvalid),
        .wready         (wready),
        .bid            (bid),
        .bresp          (bresp),
        .bvalid         (bvalid),
        .bready         (bready)
    );

    assign ws_valid = debug0_wb_valid_i;
    assign rf_rdata = 32'd0;
    assign debug0_wb_inst = 32'd0;

`ifdef CPU_2CMT
    assign debug1_wb_pc = debug1_wb_pc_i;
    assign debug1_wb_rf_wen = debug1_wb_rf_wen_i;
    assign debug1_wb_rf_wnum = debug1_wb_rf_wnum_i;
    assign debug1_wb_rf_wdata = debug1_wb_rf_wdata_i;
`endif

    // Keep optional chiplab debug inputs and the compatibility parameter in
    // the exact public contract even though the current core has no scan-read
    // register-file port.
    wire unused_debug_inputs = break_point ^ infor_flag ^ (^reg_num)
                             ^ (TLBNUM == 0) ^ debug1_wb_valid_i;

endmodule
