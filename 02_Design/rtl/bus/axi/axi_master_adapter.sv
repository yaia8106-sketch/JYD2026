// ============================================================
// Module: axi_master_adapter
// Description:
//   Single-outstanding AXI master for the processor memory backend.
//   The internal command uses AXI AxLEN encoding (beats minus one), supports
//   read bursts, and intentionally restricts writes to one beat.
//
// This transport block is platform-neutral.  AXI IDs and AXI3 WID are added
// by the NSCSCC platform bridge; the JYD BRAM build does not compile this file.
// ============================================================

module axi_master_adapter #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer STRB_WIDTH = DATA_WIDTH / 8,
    parameter logic [2:0] AXI_SIZE = 3'd2
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    req_valid,
    output logic                    req_ready,
    input  logic                    req_write,
    input  logic [ADDR_WIDTH-1:0]   req_addr,
    input  logic [7:0]              req_len,
    input  logic [DATA_WIDTH-1:0]   req_wdata,
    input  logic [STRB_WIDTH-1:0]   req_wstrb,

    output logic                    rd_valid,
    input  logic                    rd_ready,
    output logic [DATA_WIDTH-1:0]   rd_data,
    output logic                    rd_last,
    output logic [1:0]              rd_resp,

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
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,

    input  logic [DATA_WIDTH-1:0]   m_axi_rdata,
    input  logic [1:0]              m_axi_rresp,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_READ_ADDR,
        S_READ_DATA,
        S_WRITE_ADDR_DATA,
        S_WRITE_RESP
    } state_t;

    state_t state;
    logic [ADDR_WIDTH-1:0] addr_r;
    logic [7:0]            len_r;
    logic [DATA_WIDTH-1:0] wdata_r;
    logic [STRB_WIDTH-1:0] wstrb_r;
    logic                  aw_done;
    logic                  w_done;

    wire write_req_supported = ~req_write | (req_len == 8'd0);
    wire req_fire = req_valid & req_ready;
    wire aw_fire  = m_axi_awvalid & m_axi_awready;
    wire w_fire   = m_axi_wvalid & m_axi_wready;
    wire b_fire   = m_axi_bvalid & m_axi_bready;
    wire ar_fire  = m_axi_arvalid & m_axi_arready;
    wire r_fire   = m_axi_rvalid & m_axi_rready;

    assign req_ready = (state == S_IDLE) & write_req_supported;
    assign busy = state != S_IDLE;

    assign m_axi_awaddr  = addr_r;
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = AXI_SIZE;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0000;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awqos   = 4'b0000;
    assign m_axi_awvalid = (state == S_WRITE_ADDR_DATA) & ~aw_done;

    assign m_axi_wdata  = wdata_r;
    assign m_axi_wstrb  = wstrb_r;
    assign m_axi_wlast  = 1'b1;
    assign m_axi_wvalid = (state == S_WRITE_ADDR_DATA) & ~w_done;

    assign m_axi_bready = (state == S_WRITE_RESP) & wr_ready;
    assign wr_valid = (state == S_WRITE_RESP) & m_axi_bvalid;
    assign wr_resp = m_axi_bresp;

    assign m_axi_araddr  = addr_r;
    assign m_axi_arlen   = len_r;
    assign m_axi_arsize  = AXI_SIZE;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0000;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;
    assign m_axi_arvalid = state == S_READ_ADDR;

    assign m_axi_rready = (state == S_READ_DATA) & rd_ready;
    assign rd_valid = (state == S_READ_DATA) & m_axi_rvalid;
    assign rd_data = m_axi_rdata;
    assign rd_last = m_axi_rlast;
    assign rd_resp = m_axi_rresp;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            addr_r  <= '0;
            len_r   <= 8'd0;
            wdata_r <= '0;
            wstrb_r <= '0;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    aw_done <= 1'b0;
                    w_done  <= 1'b0;
                    if (req_fire) begin
                        addr_r  <= req_addr;
                        len_r   <= req_len;
                        wdata_r <= req_wdata;
                        wstrb_r <= req_wstrb;
                        state <= req_write ? S_WRITE_ADDR_DATA
                                           : S_READ_ADDR;
                    end
                end
                S_READ_ADDR:
                    if (ar_fire)
                        state <= S_READ_DATA;
                S_READ_DATA:
                    if (r_fire & m_axi_rlast)
                        state <= S_IDLE;
                S_WRITE_ADDR_DATA: begin
                    if (aw_fire)
                        aw_done <= 1'b1;
                    if (w_fire)
                        w_done <= 1'b1;
                    if ((aw_done | aw_fire) & (w_done | w_fire))
                        state <= S_WRITE_RESP;
                end
                S_WRITE_RESP:
                    if (b_fire)
                        state <= S_IDLE;
                default:
                    state <= S_IDLE;
            endcase
        end
    end

endmodule
