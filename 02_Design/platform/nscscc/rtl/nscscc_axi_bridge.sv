// ============================================================
// Module: nscscc_axi_bridge
// Description:
//   NSCSCC-only memory bridge.  It combines variable-latency 64-bit IROM
//   fetches and the DCache backend onto the single 32-bit AXI master required
//   by chiplab.  Data traffic has arbitration priority to guarantee progress
//   while the pipeline is stalled on an LSU request.
// ============================================================

module nscscc_axi_bridge (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        irom_req_valid,
    output logic        irom_req_ready,
    input  logic [31:0] irom_req_addr,
    output logic        irom_resp_valid,
    output logic [63:0] irom_resp_data,

    input  logic        dmem_req_valid,
    output logic        dmem_req_ready,
    input  logic        dmem_req_write,
    input  logic [31:0] dmem_req_addr,
    input  logic [ 7:0] dmem_req_len,
    input  logic [31:0] dmem_req_wdata,
    input  logic [ 3:0] dmem_req_wstrb,
    output logic        dmem_rd_valid,
    input  logic        dmem_rd_ready,
    output logic [31:0] dmem_rd_data,
    output logic        dmem_rd_last,
    output logic [ 1:0] dmem_rd_resp,
    input  logic        dmem_rd_cancel,
    output logic        dmem_wr_valid,
    input  logic        dmem_wr_ready,
    output logic [ 1:0] dmem_wr_resp,

    output logic [ 3:0] arid,
    output logic [31:0] araddr,
    output logic [ 7:0] arlen,
    output logic [ 2:0] arsize,
    output logic [ 1:0] arburst,
    output logic [ 1:0] arlock,
    output logic [ 3:0] arcache,
    output logic [ 2:0] arprot,
    output logic        arvalid,
    input  logic        arready,
    input  logic [ 3:0] rid,
    input  logic [31:0] rdata,
    input  logic [ 1:0] rresp,
    input  logic        rlast,
    input  logic        rvalid,
    output logic        rready,

    output logic [ 3:0] awid,
    output logic [31:0] awaddr,
    output logic [ 7:0] awlen,
    output logic [ 2:0] awsize,
    output logic [ 1:0] awburst,
    output logic [ 1:0] awlock,
    output logic [ 3:0] awcache,
    output logic [ 2:0] awprot,
    output logic        awvalid,
    input  logic        awready,
    output logic [ 3:0] wid,
    output logic [31:0] wdata,
    output logic [ 3:0] wstrb,
    output logic        wlast,
    output logic        wvalid,
    input  logic        wready,
    input  logic [ 3:0] bid,
    input  logic [ 1:0] bresp,
    input  logic        bvalid,
    output logic        bready
);

    logic        imem_req_valid;
    logic        imem_req_ready;
    logic [31:0] imem_req_addr;
    logic [ 7:0] imem_req_len;
    logic        imem_rd_valid;
    logic        imem_rd_ready;
    logic [31:0] imem_rd_data;
    logic        imem_rd_last;
    logic [ 1:0] imem_rd_resp;
    logic [ 1:0] irom_resp_resp;

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic        mem_req_write;
    logic [31:0] mem_req_addr;
    logic [ 7:0] mem_req_len;
    logic [31:0] mem_req_wdata;
    logic [ 3:0] mem_req_wstrb;
    logic        mem_rd_valid;
    logic        mem_rd_ready;
    logic [31:0] mem_rd_data;
    logic        mem_rd_last;
    logic [ 1:0] mem_rd_resp;
    logic        mem_wr_valid;
    logic        mem_wr_ready;
    logic [ 1:0] mem_wr_resp;
    logic        axi_busy;
    logic        axi_awlock;
    logic        axi_arlock;
    logic [ 3:0] unused_awqos;
    logic [ 3:0] unused_arqos;

    irom_backend_adapter u_irom_backend_adapter (
        .clk            (clk),
        .rst_n          (rst_n),
        .irom_req_valid (irom_req_valid),
        .irom_req_ready (irom_req_ready),
        .irom_req_addr  (irom_req_addr),
        .irom_resp_valid(irom_resp_valid),
        .irom_resp_ready(1'b1),
        .irom_resp_data (irom_resp_data),
        .irom_resp_resp (irom_resp_resp),
        .mem_req_valid  (imem_req_valid),
        .mem_req_ready  (imem_req_ready),
        .mem_req_addr   (imem_req_addr),
        .mem_req_len    (imem_req_len),
        .mem_rd_valid   (imem_rd_valid),
        .mem_rd_ready   (imem_rd_ready),
        .mem_rd_data    (imem_rd_data),
        .mem_rd_last    (imem_rd_last),
        .mem_rd_resp    (imem_rd_resp)
    );

    memory_backend_arbiter u_memory_backend_arbiter (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_req_valid  (imem_req_valid),
        .i_req_ready  (imem_req_ready),
        .i_req_addr   (imem_req_addr),
        .i_req_len    (imem_req_len),
        .i_rd_valid   (imem_rd_valid),
        .i_rd_ready   (imem_rd_ready),
        .i_rd_data    (imem_rd_data),
        .i_rd_last    (imem_rd_last),
        .i_rd_resp    (imem_rd_resp),
        .d_req_valid  (dmem_req_valid),
        .d_req_ready  (dmem_req_ready),
        .d_req_write  (dmem_req_write),
        .d_req_addr   (dmem_req_addr),
        .d_req_len    (dmem_req_len),
        .d_req_wdata  (dmem_req_wdata),
        .d_req_wstrb  (dmem_req_wstrb),
        .d_rd_valid   (dmem_rd_valid),
        .d_rd_ready   (dmem_rd_ready),
        .d_rd_data    (dmem_rd_data),
        .d_rd_last    (dmem_rd_last),
        .d_rd_resp    (dmem_rd_resp),
        .d_wr_valid   (dmem_wr_valid),
        .d_wr_ready   (dmem_wr_ready),
        .d_wr_resp    (dmem_wr_resp),
        .m_req_valid  (mem_req_valid),
        .m_req_ready  (mem_req_ready),
        .m_req_write  (mem_req_write),
        .m_req_addr   (mem_req_addr),
        .m_req_len    (mem_req_len),
        .m_req_wdata  (mem_req_wdata),
        .m_req_wstrb  (mem_req_wstrb),
        .m_rd_valid   (mem_rd_valid),
        .m_rd_ready   (mem_rd_ready),
        .m_rd_data    (mem_rd_data),
        .m_rd_last    (mem_rd_last),
        .m_rd_resp    (mem_rd_resp),
        .m_wr_valid   (mem_wr_valid),
        .m_wr_ready   (mem_wr_ready),
        .m_wr_resp    (mem_wr_resp)
    );

    axi_master_adapter u_axi_master_adapter (
        .clk           (clk),
        .rst_n         (rst_n),
        .req_valid     (mem_req_valid),
        .req_ready     (mem_req_ready),
        .req_write     (mem_req_write),
        .req_addr      (mem_req_addr),
        .req_len       (mem_req_len),
        .req_wdata     (mem_req_wdata),
        .req_wstrb     (mem_req_wstrb),
        .rd_valid      (mem_rd_valid),
        .rd_ready      (mem_rd_ready),
        .rd_data       (mem_rd_data),
        .rd_last       (mem_rd_last),
        .rd_resp       (mem_rd_resp),
        .wr_valid      (mem_wr_valid),
        .wr_ready      (mem_wr_ready),
        .wr_resp       (mem_wr_resp),
        .busy          (axi_busy),
        .m_axi_awaddr  (awaddr),
        .m_axi_awlen   (awlen),
        .m_axi_awsize  (awsize),
        .m_axi_awburst (awburst),
        .m_axi_awlock  (axi_awlock),
        .m_axi_awcache (awcache),
        .m_axi_awprot  (awprot),
        .m_axi_awqos   (unused_awqos),
        .m_axi_awvalid (awvalid),
        .m_axi_awready (awready),
        .m_axi_wdata   (wdata),
        .m_axi_wstrb   (wstrb),
        .m_axi_wlast   (wlast),
        .m_axi_wvalid  (wvalid),
        .m_axi_wready  (wready),
        .m_axi_bresp   (bresp),
        .m_axi_bvalid  (bvalid),
        .m_axi_bready  (bready),
        .m_axi_araddr  (araddr),
        .m_axi_arlen   (arlen),
        .m_axi_arsize  (arsize),
        .m_axi_arburst (arburst),
        .m_axi_arlock  (axi_arlock),
        .m_axi_arcache (arcache),
        .m_axi_arprot  (arprot),
        .m_axi_arqos   (unused_arqos),
        .m_axi_arvalid (arvalid),
        .m_axi_arready (arready),
        .m_axi_rdata   (rdata),
        .m_axi_rresp   (rresp),
        .m_axi_rlast   (rlast),
        .m_axi_rvalid  (rvalid),
        .m_axi_rready  (rready)
    );

    assign arid = 4'h0;
    assign awid = 4'h1;
    assign wid = 4'h1;
    assign arlock = {1'b0, axi_arlock};
    assign awlock = {1'b0, axi_awlock};

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && dmem_rd_cancel)
            $error("NSCSCC AXI reads cannot be cancelled after acceptance");
        if (rst_n && irom_resp_valid && (irom_resp_resp != 2'b00))
            $error("IROM AXI read completed with response %b", irom_resp_resp);
        if (rst_n && rvalid && rready && (rid != arid))
            $error("AXI read ID mismatch: expected %0d got %0d", arid, rid);
        if (rst_n && bvalid && bready && (bid != awid))
            $error("AXI write ID mismatch: expected %0d got %0d", awid, bid);
    end
`endif

endmodule
