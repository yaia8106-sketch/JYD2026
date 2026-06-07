// ============================================================
// Module: dcache_axi_backend
// Description:
//   Connects the DCache memory backend interface to an AXI4 master adapter.
//   This is the block that turns DCache refill/write-through requests into
//   AXI transactions.
// ============================================================

module dcache_axi_backend #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer STRB_WIDTH = DATA_WIDTH / 8,
    parameter [2:0]   AXI_SIZE   = 3'd2
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    mem_req_valid,
    output logic                    mem_req_ready,
    input  logic                    mem_req_write,
    input  logic [ADDR_WIDTH-1:0]   mem_req_addr,
    input  logic [7:0]              mem_req_len,
    input  logic [DATA_WIDTH-1:0]   mem_req_wdata,
    input  logic [STRB_WIDTH-1:0]   mem_req_wstrb,

    output logic                    mem_rd_valid,
    input  logic                    mem_rd_ready,
    output logic [DATA_WIDTH-1:0]   mem_rd_data,
    output logic                    mem_rd_last,
    output logic [1:0]              mem_rd_resp,

    output logic                    mem_wr_valid,
    input  logic                    mem_wr_ready,
    output logic [1:0]              mem_wr_resp,

    output logic                    busy,

    output logic [ADDR_WIDTH-1:0]   m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awlock,
    output logic [3:0]              m_axi_awcache,
    output logic [2:0]              m_axi_awprot,
    output logic [3:0]              m_axi_awqos,
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,

    output logic [DATA_WIDTH-1:0]   m_axi_wdata,
    output logic [STRB_WIDTH-1:0]   m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    input  logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,

    output logic [ADDR_WIDTH-1:0]   m_axi_araddr,
    output logic [7:0]              m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic                    m_axi_arlock,
    output logic [3:0]              m_axi_arcache,
    output logic [2:0]              m_axi_arprot,
    output logic [3:0]              m_axi_arqos,
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,

    input  logic [DATA_WIDTH-1:0]   m_axi_rdata,
    input  logic [1:0]              m_axi_rresp,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready
);

    axi_master_adapter #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .STRB_WIDTH (STRB_WIDTH),
        .AXI_SIZE   (AXI_SIZE)
    ) u_axi_master_adapter (
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
        .busy          (busy),

        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awlock  (m_axi_awlock),
        .m_axi_awcache (m_axi_awcache),
        .m_axi_awprot  (m_axi_awprot),
        .m_axi_awqos   (m_axi_awqos),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),

        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),

        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),

        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arlock  (m_axi_arlock),
        .m_axi_arcache (m_axi_arcache),
        .m_axi_arprot  (m_axi_arprot),
        .m_axi_arqos   (m_axi_arqos),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),

        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready)
    );

endmodule
