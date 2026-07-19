// ============================================================
// Module: bitmanip_decoder
// Description: Exact RV32 Zba/Zbb/Zbc/Zbs/Zbkb/Zbkx decoder.
// Domain: decode and issue.
// ============================================================

module bitmanip_decoder
    import cpu_defs::*;
(
    input  logic [31:0]  inst,
    output logic         is_bitmanip,
    output bitmanip_op_t bitmanip_op
);

    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [4:0] rs2    = inst[24:20];
    wire [6:0] funct7 = inst[31:25];

    always_comb begin
        bitmanip_op = BM_NONE;

        case (opcode)
            OP_R_TYPE: begin
                case ({funct7, funct3})
                    // Zba
                    {7'h10, 3'b010}: bitmanip_op = BM_SH1ADD;
                    {7'h10, 3'b100}: bitmanip_op = BM_SH2ADD;
                    {7'h10, 3'b110}: bitmanip_op = BM_SH3ADD;

                    // Zbb logical-with-negate, min/max, and rotate
                    {7'h20, 3'b111}: bitmanip_op = BM_ANDN;
                    {7'h20, 3'b110}: bitmanip_op = BM_ORN;
                    {7'h20, 3'b100}: bitmanip_op = BM_XNOR;
                    {7'h05, 3'b110}: bitmanip_op = BM_MAX;
                    {7'h05, 3'b111}: bitmanip_op = BM_MAXU;
                    {7'h05, 3'b100}: bitmanip_op = BM_MIN;
                    {7'h05, 3'b101}: bitmanip_op = BM_MINU;
                    {7'h30, 3'b001}: bitmanip_op = BM_ROL;
                    {7'h30, 3'b101}: bitmanip_op = BM_ROR;

                    // Zbc
                    {7'h05, 3'b001}: bitmanip_op = BM_CLMUL;
                    {7'h05, 3'b010}: bitmanip_op = BM_CLMULR;
                    {7'h05, 3'b011}: bitmanip_op = BM_CLMULH;

                    // Zbs register forms
                    {7'h24, 3'b001}: bitmanip_op = BM_BCLR;
                    {7'h24, 3'b101}: bitmanip_op = BM_BEXT;
                    {7'h34, 3'b001}: bitmanip_op = BM_BINV;
                    {7'h14, 3'b001}: bitmanip_op = BM_BSET;

                    // Zbkb packing and Zbb zext.h alias
                    {7'h04, 3'b100}: begin
                        bitmanip_op = (rs2 == 5'd0) ? BM_ZEXT_H : BM_PACK;
                    end
                    {7'h04, 3'b111}: bitmanip_op = BM_PACKH;

                    // Zbkx
                    {7'h14, 3'b010}: bitmanip_op = BM_XPERM4;
                    {7'h14, 3'b100}: bitmanip_op = BM_XPERM8;

                    default: bitmanip_op = BM_NONE;
                endcase
            end

            OP_I_ALU: begin
                case ({funct7, funct3})
                    // Zbb unary operations
                    {7'h30, 3'b001}: begin
                        case (rs2)
                            5'd0: bitmanip_op = BM_CLZ;
                            5'd1: bitmanip_op = BM_CTZ;
                            5'd2: bitmanip_op = BM_CPOP;
                            5'd4: bitmanip_op = BM_SEXT_B;
                            5'd5: bitmanip_op = BM_SEXT_H;
                            default: bitmanip_op = BM_NONE;
                        endcase
                    end
                    {7'h30, 3'b101}: bitmanip_op = BM_ROR;
                    {7'h14, 3'b101}: begin
                        if (rs2 == 5'd7)
                            bitmanip_op = BM_ORC_B;
                    end
                    {7'h34, 3'b101}: begin
                        if (rs2 == 5'd7)
                            bitmanip_op = BM_BREV8;
                        else if (rs2 == 5'd24)
                            bitmanip_op = BM_REV8;
                    end

                    // Zbs immediate forms; rs2 is the RV32 shamt.
                    {7'h24, 3'b001}: bitmanip_op = BM_BCLR;
                    {7'h24, 3'b101}: bitmanip_op = BM_BEXT;
                    {7'h34, 3'b001}: bitmanip_op = BM_BINV;
                    {7'h14, 3'b001}: bitmanip_op = BM_BSET;

                    // RV32-only Zbkb bit interleave/deinterleave.
                    {7'h04, 3'b001}: begin
                        if (rs2 == 5'd15)
                            bitmanip_op = BM_ZIP;
                    end
                    {7'h04, 3'b101}: begin
                        if (rs2 == 5'd15)
                            bitmanip_op = BM_UNZIP;
                    end

                    default: bitmanip_op = BM_NONE;
                endcase
            end

            default: bitmanip_op = BM_NONE;
        endcase
    end

    assign is_bitmanip = bitmanip_op != BM_NONE;

endmodule
