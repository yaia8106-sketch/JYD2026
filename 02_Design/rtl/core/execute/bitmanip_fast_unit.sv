// ============================================================
// Module: bitmanip_fast_unit
// Description: Combinational RV32 bit-manipulation resources except CLMUL.
// Domain: execute.
// ============================================================

module bitmanip_fast_unit
    import cpu_defs::*;
(
    input  bitmanip_op_t op,
    input  logic [31:0]  rs1,
    input  logic [31:0]  rs2,
    output logic [31:0]  result
);

    function automatic logic [31:0] clz32(input logic [31:0] value);
        integer i;
        logic found;
        begin
            clz32 = 32'd32;
            found = 1'b0;
            for (i = 31; i >= 0; i = i - 1) begin
                if (!found && value[i]) begin
                    clz32 = 32'(31 - i);
                    found = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic [31:0] ctz32(input logic [31:0] value);
        integer i;
        logic found;
        begin
            ctz32 = 32'd32;
            found = 1'b0;
            for (i = 0; i < 32; i = i + 1) begin
                if (!found && value[i]) begin
                    ctz32 = 32'(i);
                    found = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic [7:0] reverse8(input logic [7:0] value);
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                reverse8[i] = value[7-i];
        end
    endfunction

    function automatic logic [31:0] zip32(input logic [31:0] value);
        integer i;
        begin
            zip32 = 32'd0;
            for (i = 0; i < 16; i = i + 1) begin
                zip32[2*i]   = value[i];
                zip32[2*i+1] = value[i+16];
            end
        end
    endfunction

    function automatic logic [31:0] unzip32(input logic [31:0] value);
        integer i;
        begin
            unzip32 = 32'd0;
            for (i = 0; i < 16; i = i + 1) begin
                unzip32[i]    = value[2*i];
                unzip32[i+16] = value[2*i+1];
            end
        end
    endfunction

    function automatic logic [31:0] xperm4(
        input logic [31:0] data,
        input logic [31:0] indices
    );
        integer i;
        logic [3:0] index;
        begin
            xperm4 = 32'd0;
            for (i = 0; i < 8; i = i + 1) begin
                index = indices[4*i +: 4];
                if (index < 4'd8)
                    xperm4[4*i +: 4] = data[4*index +: 4];
            end
        end
    endfunction

    function automatic logic [31:0] xperm8(
        input logic [31:0] data,
        input logic [31:0] indices
    );
        integer i;
        logic [7:0] index;
        begin
            xperm8 = 32'd0;
            for (i = 0; i < 4; i = i + 1) begin
                index = indices[8*i +: 8];
                if (index < 8'd4)
                    xperm8[8*i +: 8] = data[8*index +: 8];
            end
        end
    endfunction

    wire [4:0] shamt = rs2[4:0];
    wire [4:0] inv_shamt = 5'd0 - shamt;
    wire [31:0] bit_mask = 32'b1 << shamt;

    // Candidate results are computed in parallel; op only controls the final
    // selector so unrelated operations do not form a serial priority chain.
    wire [31:0] sh1add_result = (rs1 << 1) + rs2;
    wire [31:0] sh2add_result = (rs1 << 2) + rs2;
    wire [31:0] sh3add_result = (rs1 << 3) + rs2;
    wire [31:0] andn_result = rs1 & ~rs2;
    wire [31:0] orn_result = rs1 | ~rs2;
    wire [31:0] xnor_result = ~(rs1 ^ rs2);
    wire [31:0] clz_result = clz32(rs1);
    wire [31:0] ctz_result = ctz32(rs1);

    // Balanced population-count tree: five parallel reduction levels instead
    // of a serial 32-input accumulator chain.
    wire [1:0] pop_l1 [0:15];
    wire [2:0] pop_l2 [0:7];
    wire [3:0] pop_l3 [0:3];
    wire [4:0] pop_l4 [0:1];
    wire [5:0] popcount_result;
    genvar pop_g;
    generate
        for (pop_g = 0; pop_g < 16; pop_g = pop_g + 1) begin : g_pop_l1
            assign pop_l1[pop_g] = {1'b0, rs1[2*pop_g]}
                                     + {1'b0, rs1[2*pop_g+1]};
        end
        for (pop_g = 0; pop_g < 8; pop_g = pop_g + 1) begin : g_pop_l2
            assign pop_l2[pop_g] = {1'b0, pop_l1[2*pop_g]}
                                     + {1'b0, pop_l1[2*pop_g+1]};
        end
        for (pop_g = 0; pop_g < 4; pop_g = pop_g + 1) begin : g_pop_l3
            assign pop_l3[pop_g] = {1'b0, pop_l2[2*pop_g]}
                                     + {1'b0, pop_l2[2*pop_g+1]};
        end
        for (pop_g = 0; pop_g < 2; pop_g = pop_g + 1) begin : g_pop_l4
            assign pop_l4[pop_g] = {1'b0, pop_l3[2*pop_g]}
                                     + {1'b0, pop_l3[2*pop_g+1]};
        end
    endgenerate
    assign popcount_result = {1'b0, pop_l4[0]} + {1'b0, pop_l4[1]};

    wire [31:0] max_result = ($signed(rs1) < $signed(rs2)) ? rs2 : rs1;
    wire [31:0] maxu_result = (rs1 < rs2) ? rs2 : rs1;
    wire [31:0] min_result = ($signed(rs1) < $signed(rs2)) ? rs1 : rs2;
    wire [31:0] minu_result = (rs1 < rs2) ? rs1 : rs2;
    wire [31:0] sext_b_result = {{24{rs1[7]}}, rs1[7:0]};
    wire [31:0] sext_h_result = {{16{rs1[15]}}, rs1[15:0]};
    wire [31:0] zext_h_result = {16'd0, rs1[15:0]};
    wire [31:0] rol_result = (rs1 << shamt) | (rs1 >> inv_shamt);
    wire [31:0] ror_result = (rs1 >> shamt) | (rs1 << inv_shamt);
    wire [31:0] orc_b_result = {
        {8{|rs1[31:24]}}, {8{|rs1[23:16]}},
        {8{|rs1[15:8]}},  {8{|rs1[7:0]}}
    };
    wire [31:0] rev8_result = {
        rs1[7:0], rs1[15:8], rs1[23:16], rs1[31:24]
    };
    wire [31:0] bclr_result = rs1 & ~bit_mask;
    wire [31:0] bext_result = {31'd0, rs1[shamt]};
    wire [31:0] binv_result = rs1 ^ bit_mask;
    wire [31:0] bset_result = rs1 | bit_mask;
    wire [31:0] pack_result = {rs2[15:0], rs1[15:0]};
    wire [31:0] packh_result = {16'd0, rs2[7:0], rs1[7:0]};
    wire [31:0] brev8_result = {
        reverse8(rs1[31:24]), reverse8(rs1[23:16]),
        reverse8(rs1[15:8]), reverse8(rs1[7:0])
    };
    wire [31:0] zip_result = zip32(rs1);
    wire [31:0] unzip_result = unzip32(rs1);
    wire [31:0] xperm4_result = xperm4(rs1, rs2);
    wire [31:0] xperm8_result = xperm8(rs1, rs2);

    always_comb begin
        case (op)
            BM_SH1ADD: result = sh1add_result;
            BM_SH2ADD: result = sh2add_result;
            BM_SH3ADD: result = sh3add_result;
            BM_ANDN:   result = andn_result;
            BM_ORN:    result = orn_result;
            BM_XNOR:   result = xnor_result;
            BM_CLZ:    result = clz_result;
            BM_CTZ:    result = ctz_result;
            BM_CPOP:   result = {26'd0, popcount_result};
            BM_MAX:    result = max_result;
            BM_MAXU:   result = maxu_result;
            BM_MIN:    result = min_result;
            BM_MINU:   result = minu_result;
            BM_SEXT_B: result = sext_b_result;
            BM_SEXT_H: result = sext_h_result;
            BM_ZEXT_H: result = zext_h_result;
            BM_ROL:    result = rol_result;
            BM_ROR:    result = ror_result;
            BM_ORC_B:  result = orc_b_result;
            BM_REV8:   result = rev8_result;
            BM_BCLR:   result = bclr_result;
            BM_BEXT:   result = bext_result;
            BM_BINV:   result = binv_result;
            BM_BSET:   result = bset_result;
            BM_PACK:   result = pack_result;
            BM_PACKH:  result = packh_result;
            BM_BREV8:  result = brev8_result;
            BM_ZIP:    result = zip_result;
            BM_UNZIP:  result = unzip_result;
            BM_XPERM4: result = xperm4_result;
            BM_XPERM8: result = xperm8_result;
            default:   result = 32'd0;
        endcase
    end

endmodule
