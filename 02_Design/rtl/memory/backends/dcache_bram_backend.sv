// ============================================================
// Module: dcache_bram_backend
// Description:
//   Backend adapter from the DCache memory request/response interface to the
//   existing DRAM4MyOwn simple-dual-port BRAM.
//
//   This module deliberately behaves like a variable-latency backend from the
//   DCache point of view: requests are accepted with valid/ready and read data
//   is returned with valid/ready. The implementation underneath still uses the
//   local BRAM model/IP.
// ============================================================

module dcache_bram_backend #(
    // 1: BRAM output changes in the cycle after the address-sampling edge
    // 2: BRAM has an additional output register enabled.
    parameter integer READ_LATENCY = 1
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        mem_req_valid,
    output logic        mem_req_ready,
    input  logic        mem_req_write,
    input  logic [31:0] mem_req_addr,
    input  logic [ 7:0] mem_req_len,
    input  logic [31:0] mem_req_wdata,
    input  logic [ 3:0] mem_req_wstrb,

    output logic        mem_rd_valid,
    input  logic        mem_rd_ready,
    output logic [31:0] mem_rd_data,
    output logic        mem_rd_last,
    output logic [ 1:0] mem_rd_resp,
    input  logic        mem_rd_cancel,

    output logic        mem_wr_valid,
    input  logic        mem_wr_ready,
    output logic [ 1:0] mem_wr_resp,

    output logic [15:0] dram_rd_addr,
    input  logic [31:0] dram_rdata,
    output logic [15:0] dram_wr_addr,
    output logic [ 3:0] dram_wea,
    output logic [31:0] dram_wdata
);

    typedef enum logic [1:0] {
        B_IDLE,
        B_RD_BURST,
        B_WR_ISSUE,
        B_WR_RESP
    } state_t;

    state_t state;

    logic [15:0] addr_r;
    logic [ 7:0] len_r;
    logic [ 7:0] beat_r;
    logic [31:0] wdata_r;
    logic [ 3:0] wstrb_r;
    logic [1:0]  rd_valid_pipe;
    logic [1:0]  rd_last_pipe;

    wire req_fire = mem_req_valid & mem_req_ready;
    wire rd_fire  = mem_rd_valid & mem_rd_ready;
    wire wr_fire  = mem_wr_valid & mem_wr_ready;
    wire rd_issue = (state == B_RD_BURST) & (beat_r <= len_r);

    assign mem_req_ready = (state == B_IDLE);

    assign dram_rd_addr = rd_issue ? addr_r : 16'd0;
    assign dram_wr_addr = (state == B_WR_ISSUE) ? addr_r : 16'd0;
    assign dram_wea     = (state == B_WR_ISSUE) ? wstrb_r : 4'd0;
    assign dram_wdata   = wdata_r;

    wire rd_valid_out = (READ_LATENCY == 2) ? rd_valid_pipe[1] : rd_valid_pipe[0];
    wire rd_last_out  = (READ_LATENCY == 2) ? rd_last_pipe[1]  : rd_last_pipe[0];

    assign mem_rd_valid = (state == B_RD_BURST) & rd_valid_out;
    assign mem_rd_data  = dram_rdata;
    assign mem_rd_last  = rd_last_out;
    assign mem_rd_resp  = 2'b00;

    assign mem_wr_valid = (state == B_WR_RESP);
    assign mem_wr_resp  = 2'b00;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state   <= B_IDLE;
            addr_r  <= 16'd0;
            len_r   <= 8'd0;
            beat_r  <= 8'd0;
            wdata_r <= 32'd0;
            wstrb_r <= 4'd0;
            rd_valid_pipe <= 2'b00;
            rd_last_pipe <= 2'b00;
        end else begin
            if (mem_rd_cancel) begin
                state <= B_IDLE;
                rd_valid_pipe <= 2'b00;
                rd_last_pipe <= 2'b00;
                beat_r <= 8'd0;
            end else case (state)
                B_IDLE: begin
                    if (req_fire) begin
                        addr_r  <= mem_req_addr[17:2];
                        len_r   <= mem_req_write ? 8'd0 : mem_req_len;
                        beat_r  <= 8'd0;
                        wdata_r <= mem_req_wdata;
                        wstrb_r <= mem_req_wstrb;
                        rd_valid_pipe <= 2'b00;
                        rd_last_pipe <= 2'b00;
                        state   <= mem_req_write ? B_WR_ISSUE : B_RD_BURST;
                    end
                end

                B_RD_BURST: begin
                    if (rd_fire & mem_rd_last) begin
                        state <= B_IDLE;
                        rd_valid_pipe <= 2'b00;
                        rd_last_pipe <= 2'b00;
                    end else begin
                        rd_valid_pipe <= {rd_valid_pipe[0], rd_issue};
                        rd_last_pipe <= {rd_last_pipe[0], rd_issue & (beat_r == len_r)};

                        if (rd_issue) begin
                            beat_r <= beat_r + 8'd1;
                            addr_r <= addr_r + 16'd1;
                        end
                    end
                end

                B_WR_ISSUE:
                    state <= B_WR_RESP;

                B_WR_RESP: begin
                    if (wr_fire)
                        state <= B_IDLE;
                end

                default:
                    state <= B_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && mem_rd_valid && !mem_rd_ready)
            $error("dcache_bram_backend read burst does not support response backpressure");
    end
`endif

endmodule
