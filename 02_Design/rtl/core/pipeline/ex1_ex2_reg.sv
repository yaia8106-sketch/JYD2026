// ============================================================
// Module: ex1_ex2_reg
// Description: Shared dual-slot EX1/EX2 pipeline boundary.
//
// EX1 supplies the early ALU/address results used by forwarding and the
// synchronous Cache read address.  The complete decoded payload is retained so
// each slot can run its independent final ALU in EX2.
// ============================================================

module ex1_ex2_reg
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    input  logic          ex1_valid,
    input  logic          ex1_s1_valid,
    input  logic          ex1_ready_go,
    input  logic          ex2_allowin,
    input  logic          ex2_flush,

    input  id_ex_slot0_t  ex1_slot0_payload,
    input  id_ex_slot1_t  ex1_slot1_payload,
    input  logic [31:0]   ex1_s0_early_result,
    input  logic [31:0]   ex1_s1_early_result,
    input  logic [31:0]   ex1_s0_mem_addr,
    input  logic [31:0]   ex1_s1_mem_addr,
    input  logic [31:0]   ex1_s0_pc_plus_4,
    input  logic [31:0]   ex1_s1_pc_plus_4,
    input  logic [ 3:0]   ex1_s0_store_wea,
    input  logic [ 3:0]   ex1_s1_store_wea,
    input  logic          ex1_s0_is_cacheable,
    input  logic          ex1_s1_is_cacheable,

    // Resolved EX2 operands are fed back only to capture a late value when
    // EX2 stalls.  This turns the first available MEM/pair value into an
    // ordinary local operand, so a producer may retire while EX2 remains held.
    input  logic [31:0]   ex2_s0_alu_src1_final,
    input  logic [31:0]   ex2_s0_alu_src2_final,
    input  logic [31:0]   ex2_s0_rs1_final,
    input  logic [31:0]   ex2_s0_rs2_final,
    input  logic [31:0]   ex2_s1_alu_src1_final,
    input  logic [31:0]   ex2_s1_alu_src2_final,
    input  logic [31:0]   ex2_s1_rs1_final,
    input  logic [31:0]   ex2_s1_rs2_final,

    output logic          ex2_valid,
    output logic          ex2_s1_valid,
    output id_ex_slot0_t  ex2_slot0_payload,
    output id_ex_slot1_t  ex2_slot1_payload,
    output logic [31:0]   ex2_s0_early_result,
    output logic [31:0]   ex2_s1_early_result,
    output logic [31:0]   ex2_s0_mem_addr,
    output logic [31:0]   ex2_s1_mem_addr,
    output logic [31:0]   ex2_s0_pc_plus_4,
    output logic [31:0]   ex2_s1_pc_plus_4,
    output logic [ 3:0]   ex2_s0_store_wea,
    output logic [ 3:0]   ex2_s1_store_wea,
    output logic          ex2_s0_is_cacheable,
    output logic          ex2_s1_is_cacheable
);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ex2_valid <= 1'b0;
            ex2_s1_valid <= 1'b0;
            ex2_slot0_payload <= '0;
            ex2_slot1_payload <= '0;
            ex2_s0_early_result <= 32'd0;
            ex2_s1_early_result <= 32'd0;
            ex2_s0_mem_addr <= 32'd0;
            ex2_s1_mem_addr <= 32'd0;
            ex2_s0_pc_plus_4 <= 32'd0;
            ex2_s1_pc_plus_4 <= 32'd0;
            ex2_s0_store_wea <= 4'd0;
            ex2_s1_store_wea <= 4'd0;
            ex2_s0_is_cacheable <= 1'b0;
            ex2_s1_is_cacheable <= 1'b0;
        end else if (ex2_flush) begin
            ex2_valid <= 1'b0;
            ex2_s1_valid <= 1'b0;
            ex2_slot0_payload.common.rs1_late_src <= LATE_NONE;
            ex2_slot0_payload.common.rs2_late_src <= LATE_NONE;
            ex2_slot0_payload.common.alu_src1_late_src <= LATE_NONE;
            ex2_slot0_payload.common.alu_src2_late_src <= LATE_NONE;
            ex2_slot1_payload.common.rs1_late_src <= LATE_NONE;
            ex2_slot1_payload.common.rs2_late_src <= LATE_NONE;
            ex2_slot1_payload.common.alu_src1_late_src <= LATE_NONE;
            ex2_slot1_payload.common.alu_src2_late_src <= LATE_NONE;
            ex2_s0_store_wea <= 4'd0;
            ex2_s1_store_wea <= 4'd0;
        end else if (ex2_allowin) begin
            ex2_valid <= ex1_valid & ex1_ready_go;
            ex2_s1_valid <= ex1_s1_valid & ex1_valid & ex1_ready_go;
            ex2_slot0_payload <= ex1_slot0_payload;
            ex2_slot1_payload <= ex1_slot1_payload;
            ex2_s0_early_result <= ex1_s0_early_result;
            ex2_s1_early_result <= ex1_s1_early_result;
            ex2_s0_mem_addr <= ex1_s0_mem_addr;
            ex2_s1_mem_addr <= ex1_s1_mem_addr;
            ex2_s0_pc_plus_4 <= ex1_s0_pc_plus_4;
            ex2_s1_pc_plus_4 <= ex1_s1_pc_plus_4;
            ex2_s0_store_wea <= ex1_s0_store_wea;
            ex2_s1_store_wea <= ex1_s1_store_wea;
            ex2_s0_is_cacheable <= ex1_s0_is_cacheable;
            ex2_s1_is_cacheable <= ex1_s1_is_cacheable;
        end else begin
            if (ex2_slot0_payload.common.rs1_late_src != LATE_NONE) begin
                ex2_slot0_payload.common.rs1_data <= ex2_s0_rs1_final;
                ex2_slot0_payload.common.rs1_late_src <= LATE_NONE;
            end
            if (ex2_slot0_payload.common.rs2_late_src != LATE_NONE) begin
                ex2_slot0_payload.common.rs2_data <= ex2_s0_rs2_final;
                ex2_slot0_payload.common.rs2_late_src <= LATE_NONE;
            end
            if (ex2_slot0_payload.common.alu_src1_late_src != LATE_NONE) begin
                ex2_slot0_payload.common.alu_src1 <=
                    ex2_s0_alu_src1_final;
                ex2_slot0_payload.common.alu_src1_late_src <= LATE_NONE;
            end
            if (ex2_slot0_payload.common.alu_src2_late_src != LATE_NONE) begin
                ex2_slot0_payload.common.alu_src2 <=
                    ex2_s0_alu_src2_final;
                ex2_slot0_payload.common.alu_src2_late_src <= LATE_NONE;
            end
            if (ex2_slot1_payload.common.rs1_late_src != LATE_NONE) begin
                ex2_slot1_payload.common.rs1_data <= ex2_s1_rs1_final;
                ex2_slot1_payload.common.rs1_late_src <= LATE_NONE;
            end
            if (ex2_slot1_payload.common.rs2_late_src != LATE_NONE) begin
                ex2_slot1_payload.common.rs2_data <= ex2_s1_rs2_final;
                ex2_slot1_payload.common.rs2_late_src <= LATE_NONE;
            end
            if (ex2_slot1_payload.common.alu_src1_late_src != LATE_NONE) begin
                ex2_slot1_payload.common.alu_src1 <=
                    ex2_s1_alu_src1_final;
                ex2_slot1_payload.common.alu_src1_late_src <= LATE_NONE;
            end
            if (ex2_slot1_payload.common.alu_src2_late_src != LATE_NONE) begin
                ex2_slot1_payload.common.alu_src2 <=
                    ex2_s1_alu_src2_final;
                ex2_slot1_payload.common.alu_src2_late_src <= LATE_NONE;
            end
        end
    end

endmodule
