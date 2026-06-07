`timescale 1ns / 1ps
// ============================================================
// Module: axi_ram_model
// Description:
//   Small AXI4 RAM slave model for student_top_axi simulation.
//   It supports one read burst and one single-beat write response path, which
//   matches the current processor-side AXI master behavior.
// ============================================================

module axi_ram_model #(
    parameter integer READ_LATENCY = 2
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] s_axi_awaddr,
    input  logic [ 7:0] s_axi_awlen,
    input  logic [ 2:0] s_axi_awsize,
    input  logic [ 1:0] s_axi_awburst,
    input  logic        s_axi_awlock,
    input  logic [ 3:0] s_axi_awcache,
    input  logic [ 2:0] s_axi_awprot,
    input  logic [ 3:0] s_axi_awqos,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    input  logic [31:0] s_axi_wdata,
    input  logic [ 3:0] s_axi_wstrb,
    input  logic        s_axi_wlast,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    output logic [ 1:0] s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    input  logic [31:0] s_axi_araddr,
    input  logic [ 7:0] s_axi_arlen,
    input  logic [ 2:0] s_axi_arsize,
    input  logic [ 1:0] s_axi_arburst,
    input  logic        s_axi_arlock,
    input  logic [ 3:0] s_axi_arcache,
    input  logic [ 2:0] s_axi_arprot,
    input  logic [ 3:0] s_axi_arqos,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    output logic [31:0] s_axi_rdata,
    output logic [ 1:0] s_axi_rresp,
    output logic        s_axi_rlast,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    output logic [31:0] read_burst_count,
    output logic [31:0] write_beat_count,
    output logic        protocol_error
);

    reg [31:0] mem [0:65535];
    reg [1023:0] dram_file;
    integer i;

    initial begin
        for (i = 0; i < 65536; i = i + 1)
            mem[i] = 32'd0;

        if ($value$plusargs("dram=%s", dram_file))
            $readmemh(dram_file, mem);
    end

    typedef enum logic [1:0] {
        R_IDLE,
        R_DELAY,
        R_SEND
    } read_state_t;

    typedef enum logic [1:0] {
        W_IDLE,
        W_RESP
    } write_state_t;

    read_state_t  read_state;
    write_state_t write_state;

    logic [15:0] rd_addr;
    logic [ 7:0] rd_len;
    logic [ 7:0] rd_beat;
    logic [ 3:0] rd_delay;

    logic        aw_seen;
    logic [15:0] aw_addr_r;
    logic [ 7:0] aw_len_r;
    logic [ 2:0] aw_size_r;
    logic [ 1:0] aw_burst_r;

    logic        w_seen;
    logic [31:0] wdata_r;
    logic [ 3:0] wstrb_r;
    logic        wlast_r;

    wire ar_fire = s_axi_arvalid & s_axi_arready;
    wire r_fire  = s_axi_rvalid & s_axi_rready;
    wire aw_fire = s_axi_awvalid & s_axi_awready;
    wire w_fire  = s_axi_wvalid & s_axi_wready;
    wire b_fire  = s_axi_bvalid & s_axi_bready;

    wire write_commit = (write_state == W_IDLE)
                      & (aw_seen | aw_fire)
                      & (w_seen | w_fire);

    wire [15:0] wr_addr_commit  = aw_fire ? s_axi_awaddr[17:2] : aw_addr_r;
    wire [ 7:0] wr_len_commit   = aw_fire ? s_axi_awlen        : aw_len_r;
    wire [ 2:0] wr_size_commit  = aw_fire ? s_axi_awsize       : aw_size_r;
    wire [ 1:0] wr_burst_commit = aw_fire ? s_axi_awburst      : aw_burst_r;
    wire [31:0] wr_data_commit  = w_fire  ? s_axi_wdata        : wdata_r;
    wire [ 3:0] wr_strb_commit  = w_fire  ? s_axi_wstrb        : wstrb_r;
    wire        wr_last_commit  = w_fire  ? s_axi_wlast        : wlast_r;

    assign s_axi_arready = (read_state == R_IDLE);
    assign s_axi_rvalid  = (read_state == R_SEND);
    assign s_axi_rdata   = mem[rd_addr + rd_beat];
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rlast   = (rd_beat == rd_len);

    assign s_axi_awready = (write_state == W_IDLE) & ~aw_seen;
    assign s_axi_wready  = (write_state == W_IDLE) & ~w_seen;
    assign s_axi_bresp   = 2'b00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_state       <= R_IDLE;
            rd_addr          <= 16'd0;
            rd_len           <= 8'd0;
            rd_beat          <= 8'd0;
            rd_delay         <= 4'd0;
            read_burst_count <= 32'd0;
        end else begin
            case (read_state)
                R_IDLE: begin
                    if (ar_fire) begin
                        rd_addr <= s_axi_araddr[17:2];
                        rd_len <= s_axi_arlen;
                        rd_beat <= 8'd0;
                        rd_delay <= READ_LATENCY[3:0];
                        read_burst_count <= read_burst_count + 32'd1;
                        read_state <= (READ_LATENCY == 0) ? R_SEND : R_DELAY;
                    end
                end

                R_DELAY: begin
                    if (rd_delay == 4'd1)
                        read_state <= R_SEND;
                    rd_delay <= rd_delay - 4'd1;
                end

                R_SEND: begin
                    if (r_fire) begin
                        if (rd_beat == rd_len)
                            read_state <= R_IDLE;
                        else
                            rd_beat <= rd_beat + 8'd1;
                    end
                end

                default:
                    read_state <= R_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_state      <= W_IDLE;
            s_axi_bvalid     <= 1'b0;
            aw_seen          <= 1'b0;
            aw_addr_r        <= 16'd0;
            aw_len_r         <= 8'd0;
            aw_size_r        <= 3'd0;
            aw_burst_r       <= 2'd0;
            w_seen           <= 1'b0;
            wdata_r          <= 32'd0;
            wstrb_r          <= 4'd0;
            wlast_r          <= 1'b0;
            write_beat_count <= 32'd0;
            protocol_error   <= 1'b0;
        end else begin
            case (write_state)
                W_IDLE: begin
                    if (aw_fire) begin
                        aw_seen <= 1'b1;
                        aw_addr_r <= s_axi_awaddr[17:2];
                        aw_len_r <= s_axi_awlen;
                        aw_size_r <= s_axi_awsize;
                        aw_burst_r <= s_axi_awburst;
                    end

                    if (w_fire) begin
                        w_seen <= 1'b1;
                        wdata_r <= s_axi_wdata;
                        wstrb_r <= s_axi_wstrb;
                        wlast_r <= s_axi_wlast;
                    end

                    if (write_commit) begin
                        if (wr_len_commit != 8'd0 || wr_size_commit != 3'd2 ||
                            wr_burst_commit != 2'b01 || !wr_last_commit)
                            protocol_error <= 1'b1;

                        if (wr_strb_commit[0]) mem[wr_addr_commit][ 7: 0] <= wr_data_commit[ 7: 0];
                        if (wr_strb_commit[1]) mem[wr_addr_commit][15: 8] <= wr_data_commit[15: 8];
                        if (wr_strb_commit[2]) mem[wr_addr_commit][23:16] <= wr_data_commit[23:16];
                        if (wr_strb_commit[3]) mem[wr_addr_commit][31:24] <= wr_data_commit[31:24];

                        write_beat_count <= write_beat_count + 32'd1;
                        aw_seen <= 1'b0;
                        w_seen <= 1'b0;
                        s_axi_bvalid <= 1'b1;
                        write_state <= W_RESP;
                    end
                end

                W_RESP: begin
                    if (b_fire) begin
                        s_axi_bvalid <= 1'b0;
                        write_state <= W_IDLE;
                    end
                end

                default:
                    write_state <= W_IDLE;
            endcase
        end
    end

endmodule
