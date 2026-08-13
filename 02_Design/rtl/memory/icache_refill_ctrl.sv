// ============================================================
// Module: icache_refill_ctrl
// Description: Own one four-beat critical-block-first ICache refill.
// Domain: NSCSCC instruction cache.
//
// Lookup, replacement, data-array writes, and frontend response ownership stay
// in icache.sv. This module owns only AXI request/data sequencing and the
// transaction fields made valid by a refill launch.
// ============================================================

module icache_refill_ctrl #(
    parameter int WAY_WIDTH = 1
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        kill,

    input  logic        launch,
    input  logic [28:0] launch_block_addr,
    input  logic [WAY_WIDTH-1:0] launch_way,

    output logic [ 1:0] state,
    output logic [27:0] line_addr,
    output logic        block,
    output logic [WAY_WIDTH-1:0] way,
    output logic        second_block,
    output logic        response_needed,
    output logic        drop,
    output logic        beat,
    output logic [31:0] first_word,
    output logic [ 1:0] block_resp_q,

    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic [ 7:0] mem_req_len,
    output logic [ 1:0] mem_req_burst,
    input  logic        mem_rd_valid,
    output logic        mem_rd_ready,
    input  logic [31:0] mem_rd_data,
    input  logic        mem_rd_last,
    input  logic [ 1:0] mem_rd_resp,

    output logic        mem_req_fire,
    output logic        mem_rd_fire
);

    localparam logic [1:0] REFILL_IDLE = 2'd0;
    localparam logic [1:0] REFILL_REQ  = 2'd1;
    localparam logic [1:0] REFILL_DATA = 2'd2;

    wire [1:0] accepted_block_resp = block_resp_q | mem_rd_resp;

    assign mem_req_valid = state == REFILL_REQ;
    assign mem_req_addr = {line_addr, block, 3'b000};
    assign mem_req_len = 8'd3;
    assign mem_req_burst = 2'b10;
    assign mem_rd_ready = state == REFILL_DATA;
    assign mem_req_fire = mem_req_valid & mem_req_ready;
    assign mem_rd_fire = mem_rd_valid & mem_rd_ready;

    // State changes only on accepted AXI transfers. Once AR is accepted, a
    // kill drains through RLAST because the read itself cannot be cancelled.
    always_ff @(posedge clk) begin
        if (!rst_n)
            state <= REFILL_IDLE;
        else if (kill) begin
            if (state == REFILL_REQ)
                state <= mem_req_fire ? REFILL_DATA : REFILL_IDLE;
            else if ((state == REFILL_DATA) && mem_rd_fire && mem_rd_last)
                state <= REFILL_IDLE;
        end else begin
            case (state)
                REFILL_IDLE:
                    if (launch)
                        state <= REFILL_REQ;
                REFILL_REQ:
                    if (mem_req_fire)
                        state <= REFILL_DATA;
                REFILL_DATA:
                    if (mem_rd_fire) begin
                        if (drop && mem_rd_last)
                            state <= REFILL_IDLE;
                        else if (!drop && beat && second_block && mem_rd_last)
                            state <= REFILL_IDLE;
                    end
                default:
                    state <= REFILL_IDLE;
            endcase
        end
    end

    // Payload fields are written by the event that makes them observable;
    // only the state itself needs reset.
    always_ff @(posedge clk) begin
        if (kill) begin
            response_needed <= 1'b0;
            if (state == REFILL_REQ) begin
                if (mem_req_fire) begin
                    beat <= 1'b0;
                    block_resp_q <= 2'b00;
                    drop <= 1'b1;
                end else begin
                    drop <= 1'b0;
                end
            end else if (state == REFILL_DATA) begin
                if (mem_rd_fire && mem_rd_last) begin
                    drop <= 1'b0;
                    beat <= 1'b0;
                    second_block <= 1'b0;
                    block_resp_q <= 2'b00;
                end else begin
                    drop <= 1'b1;
                end
            end
        end else begin
            case (state)
                REFILL_IDLE: begin
                    drop <= 1'b0;
                    if (launch) begin
                        line_addr <= launch_block_addr[28:1];
                        block <= launch_block_addr[0];
                        way <= launch_way;
                        second_block <= 1'b0;
                        response_needed <= 1'b1;
                    end
                end

                REFILL_REQ: begin
                    if (mem_req_fire) begin
                        beat <= 1'b0;
                        block_resp_q <= 2'b00;
                    end
                end

                REFILL_DATA: begin
                    if (mem_rd_fire) begin
                        if (drop) begin
                            if (mem_rd_last) begin
                                drop <= 1'b0;
                                beat <= 1'b0;
                                second_block <= 1'b0;
                                response_needed <= 1'b0;
                                block_resp_q <= 2'b00;
                            end
                        end else if (!beat) begin
                            first_word <= mem_rd_data;
                            beat <= 1'b1;
                            block_resp_q <= accepted_block_resp;
                        end else begin
                            beat <= 1'b0;
                            block_resp_q <= 2'b00;
                            if (!second_block) begin
                                block <= ~block;
                                second_block <= 1'b1;
                                response_needed <= 1'b0;
                            end else if (mem_rd_last) begin
                                second_block <= 1'b0;
                                response_needed <= 1'b0;
                                drop <= 1'b0;
                            end
                        end
                    end
                end

                default: begin
                    drop <= 1'b0;
                    response_needed <= 1'b0;
                end
            endcase
        end
    end

endmodule
