// ============================================================
// Module: memory_backend_arbiter
// Description:
//   Two-client arbiter for the common memory-backend command/response stream.
//   It locks ownership until the selected read burst or write response ends.
//   DCache has priority so an LSU miss that stalls retirement cannot be
//   starved by speculative instruction fetches.
// ============================================================

module memory_backend_arbiter (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        i_req_valid,
    output logic        i_req_ready,
    input  logic [31:0] i_req_addr,
    input  logic [ 7:0] i_req_len,
    output logic        i_rd_valid,
    input  logic        i_rd_ready,
    output logic [31:0] i_rd_data,
    output logic        i_rd_last,
    output logic [ 1:0] i_rd_resp,

    input  logic        d_req_valid,
    output logic        d_req_ready,
    input  logic        d_req_write,
    input  logic [31:0] d_req_addr,
    input  logic [ 7:0] d_req_len,
    input  logic [31:0] d_req_wdata,
    input  logic [ 3:0] d_req_wstrb,
    output logic        d_rd_valid,
    input  logic        d_rd_ready,
    output logic [31:0] d_rd_data,
    output logic        d_rd_last,
    output logic [ 1:0] d_rd_resp,
    output logic        d_wr_valid,
    input  logic        d_wr_ready,
    output logic [ 1:0] d_wr_resp,

    output logic        m_req_valid,
    input  logic        m_req_ready,
    output logic        m_req_write,
    output logic [31:0] m_req_addr,
    output logic [ 7:0] m_req_len,
    output logic [31:0] m_req_wdata,
    output logic [ 3:0] m_req_wstrb,
    input  logic        m_rd_valid,
    output logic        m_rd_ready,
    input  logic [31:0] m_rd_data,
    input  logic        m_rd_last,
    input  logic [ 1:0] m_rd_resp,
    input  logic        m_wr_valid,
    output logic        m_wr_ready,
    input  logic [ 1:0] m_wr_resp
);

    typedef enum logic [1:0] {
        OWNER_NONE,
        OWNER_IROM,
        OWNER_DCACHE
    } owner_t;

    owner_t owner;
    wire select_dcache = (owner == OWNER_NONE) & d_req_valid;
    wire select_irom = (owner == OWNER_NONE) & ~d_req_valid & i_req_valid;
    wire command_fire = m_req_valid & m_req_ready;
    wire read_done = m_rd_valid & m_rd_ready & m_rd_last;
    wire write_done = m_wr_valid & m_wr_ready;

    assign m_req_valid = select_dcache | select_irom;
    assign m_req_write = select_dcache ? d_req_write : 1'b0;
    assign m_req_addr = select_dcache ? d_req_addr : i_req_addr;
    assign m_req_len = select_dcache ? d_req_len : i_req_len;
    assign m_req_wdata = select_dcache ? d_req_wdata : 32'd0;
    assign m_req_wstrb = select_dcache ? d_req_wstrb : 4'd0;

    assign d_req_ready = select_dcache & m_req_ready;
    assign i_req_ready = select_irom & m_req_ready;

    assign i_rd_valid = (owner == OWNER_IROM) & m_rd_valid;
    assign i_rd_data  = m_rd_data;
    assign i_rd_last  = m_rd_last;
    assign i_rd_resp  = m_rd_resp;
    assign d_rd_valid = (owner == OWNER_DCACHE) & m_rd_valid;
    assign d_rd_data  = m_rd_data;
    assign d_rd_last  = m_rd_last;
    assign d_rd_resp  = m_rd_resp;
    assign d_wr_valid = (owner == OWNER_DCACHE) & m_wr_valid;
    assign d_wr_resp  = m_wr_resp;

    assign m_rd_ready = (owner == OWNER_IROM) ? i_rd_ready
                      : (owner == OWNER_DCACHE) ? d_rd_ready
                      : 1'b0;
    assign m_wr_ready = (owner == OWNER_DCACHE) & d_wr_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            owner <= OWNER_NONE;
        end else begin
            if (owner == OWNER_NONE) begin
                if (command_fire)
                    owner <= select_dcache ? OWNER_DCACHE : OWNER_IROM;
            end else if (read_done | write_done) begin
                owner <= OWNER_NONE;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && (owner == OWNER_IROM) && m_wr_valid)
            $error("IROM backend received an impossible AXI write response");
    end
`endif

endmodule
