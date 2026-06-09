// ============================================================
// Module: wb_mux
// Description: WB stage writeback data selection (pure combinational)
//   Also computes PC+4 for JAL/JALR link address
// ============================================================

module wb_mux (
    input  logic [31:0] wb_alu_result,
    input  logic [31:0] wb_load_data,      // from mem_interface load side
    input  logic [31:0] wb_pc_plus_4,     // pre-computed, no adder needed
    input  logic [ 1:0] wb_sel,            // 00=ALU, 01=DRAM, 10=PC+4

    output logic [31:0] wb_write_data
);

    // ---- 3-way AND-OR MUX ----
    wire sel_alu  = (wb_sel == 2'b00);
    wire sel_mem  = (wb_sel == 2'b01);
    wire sel_link = (wb_sel == 2'b10);

    assign wb_write_data = ({32{sel_alu}}  & wb_alu_result)
                         | ({32{sel_mem}}  & wb_load_data)
                         | ({32{sel_link}} & wb_pc_plus_4);

endmodule
