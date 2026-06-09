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

module dcache_bram_backend (
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

    output logic        mem_wr_valid,
    input  logic        mem_wr_ready,
    output logic [ 1:0] mem_wr_resp,

    output logic [15:0] dram_rd_addr,
    input  logic [31:0] dram_rdata,
    output logic [15:0] dram_wr_addr,
    output logic [ 3:0] dram_wea,
    output logic [31:0] dram_wdata
);

    typedef enum logic [2:0] {
        B_IDLE,
        B_RD_ISSUE,
        B_RD_WAIT0,
        B_RD_WAIT1,
        B_RD_RESP,
        B_WR_ISSUE,
        B_WR_RESP
    } state_t;

    state_t state;

    logic [15:0] addr_r;
    logic [ 7:0] len_r;
    logic [ 7:0] beat_r;
    logic [31:0] wdata_r;
    logic [ 3:0] wstrb_r;
    logic [31:0] rdata_r;

    wire req_fire = mem_req_valid & mem_req_ready;
    wire rd_fire  = mem_rd_valid & mem_rd_ready;
    wire wr_fire  = mem_wr_valid & mem_wr_ready;

    assign mem_req_ready = (state == B_IDLE);

    assign dram_rd_addr = (state == B_RD_ISSUE) ? addr_r : 16'd0;
    assign dram_wr_addr = (state == B_WR_ISSUE) ? addr_r : 16'd0;
    assign dram_wea     = (state == B_WR_ISSUE) ? wstrb_r : 4'd0;
    assign dram_wdata   = wdata_r;

    assign mem_rd_valid = (state == B_RD_RESP);
    assign mem_rd_data  = rdata_r;
    assign mem_rd_last  = (beat_r == len_r);
    assign mem_rd_resp  = 2'b00;

    assign mem_wr_valid = (state == B_WR_RESP);
    assign mem_wr_resp  = 2'b00;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= B_IDLE;
            addr_r  <= 16'd0;
            len_r   <= 8'd0;
            beat_r  <= 8'd0;
            wdata_r <= 32'd0;
            wstrb_r <= 4'd0;
            rdata_r <= 32'd0;
        end else begin
            case (state)
                B_IDLE: begin
                    if (req_fire) begin
                        addr_r  <= mem_req_addr[17:2];
                        len_r   <= mem_req_write ? 8'd0 : mem_req_len;
                        beat_r  <= 8'd0;
                        wdata_r <= mem_req_wdata;
                        wstrb_r <= mem_req_wstrb;
                        state   <= mem_req_write ? B_WR_ISSUE : B_RD_ISSUE;
                    end
                end

                B_RD_ISSUE:
                    state <= B_RD_WAIT0;

                B_RD_WAIT0:
                    state <= B_RD_WAIT1;

                B_RD_WAIT1: begin
                    rdata_r <= dram_rdata;
                    state   <= B_RD_RESP;
                end

                B_RD_RESP: begin
                    if (rd_fire) begin
                        if (beat_r == len_r) begin
                            state <= B_IDLE;
                        end else begin
                            beat_r <= beat_r + 8'd1;
                            addr_r <= addr_r + 16'd1;
                            state  <= B_RD_ISSUE;
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

endmodule
