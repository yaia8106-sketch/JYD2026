// ============================================================
// Module: mem_wb_reg
// Description: Slot 0 MEM/WB handshake and structured payload register.
// Domain: pipeline boundary.
// ============================================================

module mem_wb_reg
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    // Handshake
    input  logic          mem_valid,
    input  logic          mem_ready_go,
    output logic          wb_allowin,
    output logic          wb_valid,

    // Load data is updated only when the shared LSU completes a load.
    input  logic          mem_load_valid,

    // Registered payload
    input  mem_wb_slot0_t mem_payload,
    output mem_wb_slot0_t wb_payload,

    // Physical replica used only by EX-stage load-data repair.
    output logic [31:0]   wb_load_data_ex
);

    wire wb_ready_go = 1'b1;
    assign wb_allowin = !wb_valid || wb_ready_go;

    // This copy deliberately has no reset and is only observed when a repair
    // tag proves that a completed load exists.  Giving it a different control
    // shape prevents synthesis from merging it back into wb_payload.load_data,
    // allowing the ID-forwarding and EX-repair consumers to be placed around
    // separate source registers.
    always_ff @(posedge clk) begin
        if (rst_n && mem_load_valid && mem_ready_go)
            wb_load_data_ex <= mem_payload.load_data;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_valid                <= 1'b0;
            wb_payload              <= '0;
        end else if (wb_allowin) begin
            wb_valid                <= mem_valid & mem_ready_go;
            wb_payload.alu_result   <= mem_payload.alu_result;
            wb_payload.pc_plus_4    <= mem_payload.pc_plus_4;
            wb_payload.rd           <= mem_payload.rd;
            wb_payload.reg_write_en <= mem_payload.reg_write_en;
            wb_payload.wb_sel       <= mem_payload.wb_sel;
            wb_payload.is_load      <= mem_payload.is_load;

            // A non-load must retain the last completed load for the EX-stage
            // WB-repair path.  Keeping this field on its own write enable also
            // prevents unrelated MMIO/store selection from feeding its D pin.
            if (mem_load_valid & mem_ready_go)
                wb_payload.load_data <= mem_payload.load_data;
        end
    end

endmodule
