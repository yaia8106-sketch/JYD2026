// ============================================================
// Module: irom_backend_adapter
// Description:
//   Converts one 64-bit instruction-block request into a two-beat, 32-bit
//   backend read burst.  The response is held until the frontend accepts it.
// ============================================================

module irom_backend_adapter (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        irom_req_valid,
    output logic        irom_req_ready,
    input  logic [31:0] irom_req_addr,
    output logic        irom_resp_valid,
    input  logic        irom_resp_ready,
    output logic [63:0] irom_resp_data,
    output logic [ 1:0] irom_resp_resp,

    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic [ 7:0] mem_req_len,
    input  logic        mem_rd_valid,
    output logic        mem_rd_ready,
    input  logic [31:0] mem_rd_data,
    input  logic        mem_rd_last,
    input  logic [ 1:0] mem_rd_resp
);

    typedef enum logic [1:0] {
        S_IDLE,
        S_READ,
        S_RESP
    } state_t;

    state_t state;
    logic [31:0] word0_r;
    logic [ 1:0] response_r;
    logic [ 7:0] beat_r;

    wire req_fire = irom_req_valid & irom_req_ready;
    wire rd_fire = mem_rd_valid & mem_rd_ready;
    wire resp_fire = irom_resp_valid & irom_resp_ready;

    assign mem_req_valid = (state == S_IDLE) & irom_req_valid;
    assign mem_req_addr = {irom_req_addr[31:3], 3'b000};
    assign mem_req_len = 8'd1;
    assign irom_req_ready = (state == S_IDLE) & mem_req_ready;
    assign mem_rd_ready = state == S_READ;
    assign irom_resp_valid = state == S_RESP;
    assign irom_resp_resp = response_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            word0_r <= 32'd0;
            irom_resp_data <= 64'd0;
            response_r <= 2'b00;
            beat_r <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_fire) begin
                        response_r <= 2'b00;
                        beat_r <= 8'd0;
                        state <= S_READ;
                    end
                end
                S_READ: begin
                    if (rd_fire) begin
                        response_r <= response_r | mem_rd_resp;
                        if (beat_r == 8'd0)
                            word0_r <= mem_rd_data;
                        beat_r <= beat_r + 8'd1;
                        if (mem_rd_last) begin
                            irom_resp_data <= (beat_r == 8'd0)
                                            ? {32'd0, mem_rd_data}
                                            : {mem_rd_data, word0_r};
                            state <= S_RESP;
                        end
                    end
                end
                S_RESP:
                    if (resp_fire)
                        state <= S_IDLE;
                default:
                    state <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && rd_fire && mem_rd_last && (beat_r != 8'd1))
            $error("IROM AXI burst returned %0d beats instead of two", beat_r + 1'b1);
        if (rst_n && rd_fire && !mem_rd_last && (beat_r >= 8'd1))
            $error("IROM AXI burst exceeded two beats");
    end
`endif

endmodule
