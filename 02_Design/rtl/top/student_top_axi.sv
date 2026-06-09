`timescale 1ns / 1ps
// ============================================================
// Module: student_top_axi
// Description:
//   Processor-side AXI top. This top keeps local MMIO direct and exposes the
//   DCache external-memory path as an AXI4 master.
//
//   This module is intentionally parallel to student_top.sv:
//     - student_top.sv keeps the current BRAM backend contest flow.
//     - student_top_axi.sv is the processor-side AXI integration target.
// ============================================================

module student_top_axi #(
    parameter P_SW_CNT  = 64,
    parameter P_LED_CNT = 32,
    parameter P_SEG_CNT = 40,
    parameter P_KEY_CNT = 8
) (
    input                            w_cpu_clk,
    input                            w_clk_50Mhz,
    input                            w_clk_rst,      // active-high reset
    input  [P_KEY_CNT - 1:0]         virtual_key,
    input  [P_SW_CNT  - 1:0]         virtual_sw,

    output [P_LED_CNT - 1:0]         virtual_led,
    output [P_SEG_CNT - 1:0]         virtual_seg,

    // AXI4 master write address channel.
    output logic [31:0]              m_axi_awaddr,
    output logic [ 7:0]              m_axi_awlen,
    output logic [ 2:0]              m_axi_awsize,
    output logic [ 1:0]              m_axi_awburst,
    output logic                     m_axi_awlock,
    output logic [ 3:0]              m_axi_awcache,
    output logic [ 2:0]              m_axi_awprot,
    output logic [ 3:0]              m_axi_awqos,
    output logic                     m_axi_awvalid,
    input  logic                     m_axi_awready,

    // AXI4 master write data channel.
    output logic [31:0]              m_axi_wdata,
    output logic [ 3:0]              m_axi_wstrb,
    output logic                     m_axi_wlast,
    output logic                     m_axi_wvalid,
    input  logic                     m_axi_wready,

    // AXI4 master write response channel.
    input  logic [ 1:0]              m_axi_bresp,
    input  logic                     m_axi_bvalid,
    output logic                     m_axi_bready,

    // AXI4 master read address channel.
    output logic [31:0]              m_axi_araddr,
    output logic [ 7:0]              m_axi_arlen,
    output logic [ 2:0]              m_axi_arsize,
    output logic [ 1:0]              m_axi_arburst,
    output logic                     m_axi_arlock,
    output logic [ 3:0]              m_axi_arcache,
    output logic [ 2:0]              m_axi_arprot,
    output logic [ 3:0]              m_axi_arqos,
    output logic                     m_axi_arvalid,
    input  logic                     m_axi_arready,

    // AXI4 master read data channel.
    input  logic [31:0]              m_axi_rdata,
    input  logic [ 1:0]              m_axi_rresp,
    input  logic                     m_axi_rlast,
    input  logic                     m_axi_rvalid,
    output logic                     m_axi_rready
);

    // CPU <-> IROM
    logic [63:0] irom_data;
    logic [11:0] irom_addr;

    // CPU <-> DCache
    logic        cache_req;
    logic        cache_wr;
    logic [31:0] cache_addr;
    logic [ 3:0] cache_wea;
    logic [31:0] cache_wdata;
    logic [31:0] cache_rdata;
    logic        cache_ready;

    // CPU <-> local MMIO bridge
    logic [31:0] mmio_addr;
    logic [31:0] mmio_wr_addr;
    logic [ 3:0] mmio_wea;
    logic [31:0] mmio_wdata;
    logic [31:0] mmio_rdata;
    logic        timer_irq_pending;

    // DCache <-> memory backend
    logic        dmem_req_valid;
    logic        dmem_req_ready;
    logic        dmem_req_write;
    logic [31:0] dmem_req_addr;
    logic [ 7:0] dmem_req_len;
    logic [31:0] dmem_req_wdata;
    logic [ 3:0] dmem_req_wstrb;
    logic        dmem_rd_valid;
    logic        dmem_rd_ready;
    logic [31:0] dmem_rd_data;
    logic        dmem_rd_last;
    logic [ 1:0] dmem_rd_resp;
    logic        dmem_wr_valid;
    logic        dmem_wr_ready;
    logic [ 1:0] dmem_wr_resp;
    logic        axi_backend_busy;

    logic        dcache_flush;
    logic        cache_pipeline_stall;

    // Reset synchronizer: async assert, sync release in CPU clock domain.
    logic [1:0] cpu_rst_pipe;
    logic       cpu_rst;
    logic       cpu_rst_n;

    always_ff @(posedge w_cpu_clk or posedge w_clk_rst) begin
        if (w_clk_rst)
            cpu_rst_pipe <= 2'b11;
        else
            cpu_rst_pipe <= {cpu_rst_pipe[0], 1'b0};
    end

    assign cpu_rst   = cpu_rst_pipe[1];
    assign cpu_rst_n = ~cpu_rst;

    cpu_top u_cpu (
        .clk         (w_cpu_clk),
        .rst_n       (cpu_rst_n),
        .irom_addr   (irom_addr),
        .irom_data   (irom_data),
        .cache_req   (cache_req),
        .cache_wr    (cache_wr),
        .cache_addr  (cache_addr),
        .cache_wea   (cache_wea),
        .cache_wdata (cache_wdata),
        .cache_rdata (cache_rdata),
        .cache_ready (cache_ready),
        .cache_flush (dcache_flush),
        .cache_pipeline_stall (cache_pipeline_stall),
        .mmio_addr   (mmio_addr),
        .mmio_wr_addr(mmio_wr_addr),
        .mmio_wea    (mmio_wea),
        .mmio_wdata  (mmio_wdata),
        .mmio_rdata  (mmio_rdata),
        .timer_irq_pending (timer_irq_pending)
    );

    IROM64 u_irom (
        .clka  (w_cpu_clk),
        .addra (irom_addr),
        .douta (irom_data)
    );

    dcache u_dcache (
        .clk         (w_cpu_clk),
        .rst_n       (cpu_rst_n),
        .cpu_req     (cache_req),
        .cpu_wr      (cache_wr),
        .cpu_addr    (cache_addr),
        .cpu_wea     (cache_wea),
        .cpu_wdata   (cache_wdata),
        .cpu_rdata   (cache_rdata),
        .cpu_ready   (cache_ready),
        .pipeline_stall (cache_pipeline_stall),
        .flush       (dcache_flush),
        .mem_req_valid (dmem_req_valid),
        .mem_req_ready (dmem_req_ready),
        .mem_req_write (dmem_req_write),
        .mem_req_addr  (dmem_req_addr),
        .mem_req_len   (dmem_req_len),
        .mem_req_wdata (dmem_req_wdata),
        .mem_req_wstrb (dmem_req_wstrb),
        .mem_rd_valid  (dmem_rd_valid),
        .mem_rd_ready  (dmem_rd_ready),
        .mem_rd_data   (dmem_rd_data),
        .mem_rd_last   (dmem_rd_last),
        .mem_rd_resp   (dmem_rd_resp),
        .mem_wr_valid  (dmem_wr_valid),
        .mem_wr_ready  (dmem_wr_ready),
        .mem_wr_resp   (dmem_wr_resp)
    );

    dcache_axi_backend u_dcache_axi_backend (
        .clk           (w_cpu_clk),
        .rst_n         (cpu_rst_n),
        .mem_req_valid (dmem_req_valid),
        .mem_req_ready (dmem_req_ready),
        .mem_req_write (dmem_req_write),
        .mem_req_addr  (dmem_req_addr),
        .mem_req_len   (dmem_req_len),
        .mem_req_wdata (dmem_req_wdata),
        .mem_req_wstrb (dmem_req_wstrb),
        .mem_rd_valid  (dmem_rd_valid),
        .mem_rd_ready  (dmem_rd_ready),
        .mem_rd_data   (dmem_rd_data),
        .mem_rd_last   (dmem_rd_last),
        .mem_rd_resp   (dmem_rd_resp),
        .mem_wr_valid  (dmem_wr_valid),
        .mem_wr_ready  (dmem_wr_ready),
        .mem_wr_resp   (dmem_wr_resp),
        .busy          (axi_backend_busy),
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

    mmio_bridge u_mmio (
        .clk     (w_cpu_clk),
        .cnt_clk (w_clk_50Mhz),
        .rst     (cpu_rst),
        .addr     (mmio_addr),
        .wr_addr  (mmio_wr_addr),
        .wea      (mmio_wea),
        .wdata    (mmio_wdata),
        .rdata    (mmio_rdata),
        .timer_irq_pending (timer_irq_pending),
        .sw      (virtual_sw),
        .key     (virtual_key),
        .led     (virtual_led),
        .seg     (virtual_seg)
    );

endmodule
