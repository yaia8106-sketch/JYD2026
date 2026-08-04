// ============================================================
// Module: memory_backend_arbiter
// Description:
//   Two-client arbiter for the common memory-backend command/response stream.
//
//   ICache and DCache reads use different AXI IDs, so one read from each
//   client may remain outstanding at the same time. Read data is returned by
//   RID instead of by one global owner bit. DCache writes remain
//   single-outstanding. Dirty-line writebacks may overlap reads, while
//   uncached/MMIO writes remain serialized against both read clients.
//
//   DCache has command priority so an LSU miss that stalls retirement cannot
//   be starved by speculative instruction fetches.
// ============================================================

module memory_backend_arbiter #(
    parameter integer ID_WIDTH = 4,
    parameter logic [ID_WIDTH-1:0] I_READ_ID  = 'd0,
    parameter logic [ID_WIDTH-1:0] D_READ_ID  = 'd1,
    parameter logic [ID_WIDTH-1:0] D_WRITE_ID = 'd2
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    i_req_valid,
    output logic                    i_req_ready,
    input  logic [31:0]             i_req_addr,
    input  logic [ 7:0]             i_req_len,
    input  logic [ 1:0]             i_req_burst,
    output logic                    i_rd_valid,
    input  logic                    i_rd_ready,
    output logic [31:0]             i_rd_data,
    output logic                    i_rd_last,
    output logic [ 1:0]             i_rd_resp,

    input  logic                    d_req_valid,
    output logic                    d_req_ready,
    input  logic                    d_req_write,
    input  logic                    d_req_writeback,
    input  logic [31:0]             d_req_addr,
    input  logic [ 7:0]             d_req_len,
    input  logic [ 1:0]             d_req_burst,
    input  logic                    d_w_valid,
    output logic                    d_w_ready,
    input  logic [31:0]             d_w_data,
    input  logic [ 3:0]             d_w_strb,
    input  logic                    d_w_last,
    output logic                    d_rd_valid,
    input  logic                    d_rd_ready,
    output logic [31:0]             d_rd_data,
    output logic                    d_rd_last,
    output logic [ 1:0]             d_rd_resp,
    output logic                    d_wr_valid,
    input  logic                    d_wr_ready,
    output logic [ 1:0]             d_wr_resp,

    output logic                    m_req_valid,
    input  logic                    m_req_ready,
    output logic                    m_req_write,
    output logic [31:0]             m_req_addr,
    output logic [ 7:0]             m_req_len,
    output logic [ 1:0]             m_req_burst,
    output logic [ID_WIDTH-1:0]     m_req_id,
    output logic                    m_w_valid,
    input  logic                    m_w_ready,
    output logic [31:0]             m_w_data,
    output logic [ 3:0]             m_w_strb,
    output logic                    m_w_last,
    input  logic                    m_rd_valid,
    output logic                    m_rd_ready,
    input  logic [31:0]             m_rd_data,
    input  logic                    m_rd_last,
    input  logic [ 1:0]             m_rd_resp,
    input  logic [ID_WIDTH-1:0]     m_rd_id,
    input  logic                    m_wr_valid,
    output logic                    m_wr_ready,
    input  logic [ 1:0]             m_wr_resp
);

    logic i_read_active_q;
    logic d_read_active_q;
    logic d_write_active_q;
    logic d_write_overlap_ok_q;

    // Read slots are independent by AXI ID.  The write slot is independent as
    // well, but only an explicitly identified cache-line writeback opens the
    // read/write overlap; an uncached write preserves strong serialization.
    wire d_read_can_start = ~d_read_active_q
                          & (~d_write_active_q | d_write_overlap_ok_q);
    wire d_write_can_start = ~d_write_active_q
                           & (d_req_writeback
                              | (~i_read_active_q & ~d_read_active_q));
    wire select_dcache =
        d_req_valid
        & (d_req_write ? d_write_can_start : d_read_can_start);
    wire select_irom =
        i_req_valid
        & ~i_read_active_q
        & (~d_write_active_q | d_write_overlap_ok_q)
        & ~select_dcache;

    wire command_fire = m_req_valid & m_req_ready;
    wire i_read_done =
        m_rd_valid & m_rd_ready & m_rd_last & (m_rd_id == I_READ_ID);
    wire d_read_done =
        m_rd_valid & m_rd_ready & m_rd_last & (m_rd_id == D_READ_ID);
    wire write_done = m_wr_valid & m_wr_ready;

    assign m_req_valid = select_dcache | select_irom;
    assign m_req_write = select_dcache ? d_req_write : 1'b0;
    assign m_req_addr = select_dcache ? d_req_addr : i_req_addr;
    assign m_req_len = select_dcache ? d_req_len : i_req_len;
    assign m_req_burst = select_dcache ? d_req_burst : i_req_burst;
    assign m_req_id =
        select_dcache
            ? (d_req_write ? D_WRITE_ID : D_READ_ID)
            : I_READ_ID;

    assign d_req_ready = select_dcache & m_req_ready;
    assign i_req_ready = select_irom & m_req_ready;

    assign m_w_valid = d_write_active_q & d_w_valid;
    assign m_w_data  = d_w_data;
    assign m_w_strb  = d_w_strb;
    assign m_w_last  = d_w_last;
    assign d_w_ready = d_write_active_q & m_w_ready;

    assign i_rd_valid =
        i_read_active_q & m_rd_valid & (m_rd_id == I_READ_ID);
    assign i_rd_data = m_rd_data;
    assign i_rd_last = m_rd_last;
    assign i_rd_resp = m_rd_resp;

    assign d_rd_valid =
        d_read_active_q & m_rd_valid & (m_rd_id == D_READ_ID);
    assign d_rd_data = m_rd_data;
    assign d_rd_last = m_rd_last;
    assign d_rd_resp = m_rd_resp;

    assign d_wr_valid = d_write_active_q & m_wr_valid;
    assign d_wr_resp = m_wr_resp;

    assign m_rd_ready =
        (m_rd_id == I_READ_ID) ? (i_read_active_q & i_rd_ready)
      : (m_rd_id == D_READ_ID) ? (d_read_active_q & d_rd_ready)
                               : 1'b0;
    assign m_wr_ready = d_write_active_q & d_wr_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            i_read_active_q <= 1'b0;
            d_read_active_q <= 1'b0;
            d_write_active_q <= 1'b0;
            d_write_overlap_ok_q <= 1'b0;
        end else begin
            if (i_read_done)
                i_read_active_q <= 1'b0;
            if (d_read_done)
                d_read_active_q <= 1'b0;
            if (write_done) begin
                d_write_active_q <= 1'b0;
                d_write_overlap_ok_q <= 1'b0;
            end

            if (command_fire) begin
                if (select_dcache) begin
                    if (d_req_write) begin
                        d_write_active_q <= 1'b1;
                        d_write_overlap_ok_q <= d_req_writeback;
                    end else
                        d_read_active_q <= 1'b1;
                end else begin
                    i_read_active_q <= 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((I_READ_ID == D_READ_ID)
            || (I_READ_ID == D_WRITE_ID)
            || (D_READ_ID == D_WRITE_ID))
            $error("Memory backend AXI IDs must be distinct");
    end

    always_ff @(posedge clk) begin
        if (rst_n && m_rd_valid
            && (m_rd_id != I_READ_ID) && (m_rd_id != D_READ_ID))
            $error("Memory backend received unknown AXI RID %0d", m_rd_id);
        if (rst_n && m_rd_valid && (m_rd_id == I_READ_ID)
            && !i_read_active_q)
            $error("Memory backend received ICache data without an I read");
        if (rst_n && m_rd_valid && (m_rd_id == D_READ_ID)
            && !d_read_active_q)
            $error("Memory backend received DCache data without a D read");
        if (rst_n && !d_write_active_q && d_w_valid)
            $error("DCache supplied write data without an active write");
        if (rst_n && d_req_valid && d_req_writeback && !d_req_write)
            $error("DCache marked a read command as writeback");
        if (rst_n && d_write_active_q
            && !d_write_overlap_ok_q
            && (i_read_active_q || d_read_active_q))
            $error("Serialized DCache AXI write overlapped an outstanding read");
    end
`endif

endmodule
