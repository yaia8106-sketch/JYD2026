// ============================================================
// Module: regfile
// Description: 32x32-bit register file, 2R1W, read-first
// Spec: 02_Design/spec/regfile_spec.md
// ============================================================

module regfile (
    input  logic        clk,
    input  logic        rst_n,

    // Read ports (combinational)
    input  logic [ 4:0] rs1_addr,
    input  logic [ 4:0] rs2_addr,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data,

    // Write port (posedge)
    input  logic [ 4:0] rd_addr,
    input  logic [31:0] rd_data,
    input  logic        rd_wen,     // reg_write_en from pipeline
    input  logic        rd_valid    // wb_valid (gating: only write when valid)
);

    // ---- Register array ----
    logic [31:0] regs [1:31];   // x0 not stored, hardwired to 0

    // ---- Read (combinational, read-first) ----
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

    // ---- Write (posedge, x0 guard) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 1; i < 32; i++) begin
                regs[i] <= 32'd0;
            end
        end else if (rd_valid && rd_wen && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end

endmodule
