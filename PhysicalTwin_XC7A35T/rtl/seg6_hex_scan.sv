`timescale 1ns / 1ps

module seg6_hex_scan (
    input  logic        clk,
    input  logic        rst,
    input  logic [23:0] value,

    output logic [6:0]  seg,
    output logic        dp,
    output logic [5:0]  an
);

    logic [15:0] scan_cnt;

    always_ff @(posedge clk) begin
        scan_cnt <= scan_cnt + 16'd1;
    end

    wire [2:0] raw_digit = scan_cnt[15:13];
    wire [2:0] digit = (raw_digit >= 3'd6) ? 3'd0 : raw_digit;

    logic [3:0] nibble;

    always @* begin
        case (digit)
            3'd0: nibble = value[23:20];
            3'd1: nibble = value[19:16];
            3'd2: nibble = value[15:12];
            3'd3: nibble = value[11: 8];
            3'd4: nibble = value[ 7: 4];
            default: nibble = value[ 3: 0];
        endcase
    end

    always @* begin
        an = 6'b111111;
        case (digit)
            3'd0: an[0] = 1'b0;
            3'd1: an[1] = 1'b0;
            3'd2: an[2] = 1'b0;
            3'd3: an[3] = 1'b0;
            3'd4: an[4] = 1'b0;
            default: an[5] = 1'b0;
        endcase
    end

    always @* begin
        case (nibble)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'ha: seg = 7'b0001000;
            4'hb: seg = 7'b0000011;
            4'hc: seg = 7'b1000110;
            4'hd: seg = 7'b0100001;
            4'he: seg = 7'b0000110;
            default: seg = 7'b0001110;
        endcase
    end

    assign dp = 1'b1;

endmodule
