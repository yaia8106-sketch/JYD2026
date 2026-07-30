// ============================================================
// Module: axi_master_adapter
// Description:
//   AXI master for the processor memory backend. It supports one outstanding
//   read per AXI ID and one independent outstanding write. The internal
//   command uses AXI AxLEN encoding (beats minus one), carries its burst type
//   and read ID, and keeps write payloads on a separate ready/valid stream.
//
// This transport block is platform-neutral. Read ARID/RID are carried here;
// the NSCSCC bridge adds its fixed write AWID and AXI3 WID. The JYD BRAM build
// does not compile this file.
// ============================================================

module axi_master_adapter #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer STRB_WIDTH = DATA_WIDTH / 8,
    parameter integer ID_WIDTH = 4,
    parameter logic [2:0] AXI_SIZE = 3'd2
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    req_valid,
    output logic                    req_ready,
    input  logic                    req_write,
    input  logic [ADDR_WIDTH-1:0]   req_addr,
    input  logic [7:0]              req_len,
    input  logic [1:0]              req_burst,
    input  logic [ID_WIDTH-1:0]     req_id,

    input  logic                    w_valid,
    output logic                    w_ready,
    input  logic [DATA_WIDTH-1:0]   w_data,
    input  logic [STRB_WIDTH-1:0]   w_strb,
    input  logic                    w_last,

    output logic                    rd_valid,
    input  logic                    rd_ready,
    output logic [DATA_WIDTH-1:0]   rd_data,
    output logic                    rd_last,
    output logic [1:0]              rd_resp,
    output logic [ID_WIDTH-1:0]     rd_id,

    output logic                    wr_valid,
    input  logic                    wr_ready,
    output logic [1:0]              wr_resp,
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
    output logic [ID_WIDTH-1:0]     m_axi_arid,
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,

    input  logic [ID_WIDTH-1:0]     m_axi_rid,
    input  logic [DATA_WIDTH-1:0]   m_axi_rdata,
    input  logic [1:0]              m_axi_rresp,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready
);

    localparam integer ID_COUNT = 1 << ID_WIDTH;

    logic [ID_COUNT-1:0] read_busy_q;
    logic                 read_cmd_valid_q;
    logic [ADDR_WIDTH-1:0] read_addr_q;
    logic [7:0]            read_len_q;
    logic [1:0]            read_burst_q;
    logic [ID_WIDTH-1:0]   read_id_q;

    logic                  write_active_q;
    logic                  write_aw_pending_q;
    logic                  write_data_done_q;
    logic [ADDR_WIDTH-1:0] write_addr_q;
    logic [7:0]            write_len_q;
    logic [1:0]            write_burst_q;
    logic [7:0]            write_beat_q;

    wire read_req_ready = ~read_cmd_valid_q & ~read_busy_q[req_id];
    wire write_req_ready = ~write_active_q;
    wire req_fire = req_valid & req_ready;
    wire read_req_fire = req_fire & ~req_write;
    wire write_req_fire = req_fire & req_write;

    wire aw_fire  = m_axi_awvalid & m_axi_awready;
    wire w_fire   = m_axi_wvalid & m_axi_wready;
    wire b_fire   = m_axi_bvalid & m_axi_bready;
    wire ar_fire  = m_axi_arvalid & m_axi_arready;
    wire r_fire   = m_axi_rvalid & m_axi_rready;

    wire expected_wlast = write_beat_q == write_len_q;
    wire write_response_phase = write_active_q
                              & ~write_aw_pending_q
                              & write_data_done_q;

    assign req_ready = req_write ? write_req_ready : read_req_ready;
    assign busy = (|read_busy_q) | write_active_q;

    assign m_axi_awaddr  = write_addr_q;
    assign m_axi_awlen   = write_len_q;
    assign m_axi_awsize  = AXI_SIZE;
    assign m_axi_awburst = write_burst_q;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0000;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awqos   = 4'b0000;
    assign m_axi_awvalid = write_active_q & write_aw_pending_q;

    assign m_axi_wdata  = w_data;
    assign m_axi_wstrb  = w_strb;
    assign m_axi_wlast  = expected_wlast;
    assign m_axi_wvalid = write_active_q & ~write_data_done_q & w_valid;
    assign w_ready      = write_active_q & ~write_data_done_q
                        & m_axi_wready;

    assign m_axi_bready = write_response_phase & wr_ready;
    assign wr_valid = write_response_phase & m_axi_bvalid;
    assign wr_resp = m_axi_bresp;

    assign m_axi_araddr  = read_addr_q;
    assign m_axi_arlen   = read_len_q;
    assign m_axi_arsize  = AXI_SIZE;
    assign m_axi_arburst = read_burst_q;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0000;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;
    assign m_axi_arid    = read_id_q;
    assign m_axi_arvalid = read_cmd_valid_q;

    assign m_axi_rready = rd_ready;
    assign rd_valid = m_axi_rvalid;
    assign rd_data = m_axi_rdata;
    assign rd_last = m_axi_rlast;
    assign rd_resp = m_axi_rresp;
    assign rd_id = m_axi_rid;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            read_busy_q <= '0;
            read_cmd_valid_q <= 1'b0;
            read_addr_q <= '0;
            read_len_q <= 8'd0;
            read_burst_q <= 2'b01;
            read_id_q <= '0;

            write_active_q <= 1'b0;
            write_aw_pending_q <= 1'b0;
            write_data_done_q <= 1'b0;
            write_addr_q <= '0;
            write_len_q <= 8'd0;
            write_burst_q <= 2'b01;
            write_beat_q <= 8'd0;
        end else begin
            if (read_req_fire) begin
                read_busy_q[req_id] <= 1'b1;
                read_cmd_valid_q <= 1'b1;
                read_addr_q <= req_addr;
                read_len_q <= req_len;
                read_burst_q <= req_burst;
                read_id_q <= req_id;
            end else if (ar_fire) begin
                read_cmd_valid_q <= 1'b0;
            end

            if (r_fire & m_axi_rlast)
                read_busy_q[m_axi_rid] <= 1'b0;

            if (write_req_fire) begin
                write_active_q <= 1'b1;
                write_aw_pending_q <= 1'b1;
                write_data_done_q <= 1'b0;
                write_addr_q <= req_addr;
                write_len_q <= req_len;
                write_burst_q <= req_burst;
                write_beat_q <= 8'd0;
            end else begin
                if (aw_fire)
                    write_aw_pending_q <= 1'b0;
                if (w_fire) begin
                    if (expected_wlast)
                        write_data_done_q <= 1'b1;
                    else
                        write_beat_q <= write_beat_q + 1'b1;
                end
                if (b_fire) begin
                    write_active_q <= 1'b0;
                    write_data_done_q <= 1'b0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && w_fire && (w_last != expected_wlast))
            $error("AXI adapter write stream LAST disagrees with command LEN");
        if (rst_n && !write_active_q && w_valid)
            $error("AXI adapter received write data outside a write command");
        if (rst_n && r_fire && !read_busy_q[m_axi_rid])
            $error("AXI adapter received a response for an idle read ID");
        if (rst_n && read_req_fire && (req_burst == 2'b10)
            && (req_len != 8'd1) && (req_len != 8'd3)
            && (req_len != 8'd7) && (req_len != 8'd15))
            $error("AXI WRAP burst used an illegal beat count");
    end
`endif

endmodule
