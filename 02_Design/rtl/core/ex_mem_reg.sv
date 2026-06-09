// ============================================================
// Module: ex_mem_reg
// Description: EX/MEM pipeline register
// Note: No flush (branch instruction itself flows through normally)
// 250MHz: branch_flush/target registered here for timing closure
// ============================================================

module ex_mem_reg (
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        ex_valid,
    input  logic        ex_ready_go,
    output logic        mem_allowin,
    output logic        mem_valid,
    input  logic        mem_ready_go,
    input  logic        wb_allowin,

    // 250MHz: registered branch flush (captures EX-stage combinational result)
    input  logic        ex_branch_flush,
    input  logic [31:0] ex_branch_target,
    output logic        mem_branch_flush,
    output logic [31:0] mem_branch_target,

    // Data in (from EX stage)
    input  logic [31:0] ex_alu_result,
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_pc_plus_4,
    input  logic [ 4:0] ex_rd,
    input  logic        ex_reg_write_en,
    input  logic [ 1:0] ex_wb_sel,
    input  logic        ex_mem_read_en,
    input  logic [ 1:0] ex_mem_size,
    input  logic        ex_mem_unsigned,

    // FIX-C: Store signals (latched for MEM-stage DRAM write)
    input  logic [ 3:0] ex_store_wea,        // gated byte WEA from mem_interface
    input  logic [31:0] ex_store_data,       // shifted store data from mem_interface

    // DCache: cacheable flag
    input  logic        ex_is_cacheable,

    // Data out (to MEM stage)
    output logic [31:0] mem_alu_result,
    output logic [31:0] mem_pc,
    output logic [31:0] mem_pc_plus_4,
    output logic [ 4:0] mem_rd,
    output logic        mem_reg_write_en,
    output logic [ 1:0] mem_wb_sel,
    output logic        mem_mem_read_en,    // = mem_is_load
    output logic [ 1:0] mem_mem_size,
    output logic        mem_mem_unsigned,

    // FIX-C: Registered store signals (MEM stage → DRAM write port)
    output logic [ 3:0] mem_store_wea,
    output logic [31:0] mem_store_data,

    // DCache: registered cacheable flag
    output logic        mem_is_cacheable
);

    // ---- Handshake ----
    assign mem_allowin = !mem_valid || (mem_ready_go & wb_allowin);

    // ---- Pipeline register ----
    // 250MHz: when mem_branch_flush fires, the instruction in EX is spurious
    // (it entered EX one cycle before the registered flush could stop it).
    // Must prevent it from entering MEM with valid=1.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_valid         <= 1'b0;
            mem_alu_result    <= 32'd0;
            mem_pc            <= 32'd0;
            mem_pc_plus_4     <= 32'd0;
            mem_rd            <= 5'd0;
            mem_reg_write_en  <= 1'b0;
            mem_wb_sel        <= 2'd0;
            mem_mem_read_en   <= 1'b0;
            mem_mem_size      <= 2'd0;
            mem_mem_unsigned  <= 1'b0;
            mem_store_wea     <= 4'd0;
            mem_store_data    <= 32'd0;
            mem_is_cacheable  <= 1'b0;
        end else if (mem_allowin) begin
            // 250MHz: when mem_branch_flush fires, the instruction in EX is spurious
            // (it entered EX before the registered flush could stop it).
            // Gate incoming valid with ~mem_branch_flush to prevent it entering MEM.
            // NOTE: Do NOT kill current MEM instruction unconditionally — if it has
            // a pending DCache miss (mem_allowin was 0), it must stay valid until
            // the DCache completes. The old priority "else if (mem_branch_flush)"
            // killed the flush-generating instruction itself on cache miss.
            mem_valid         <= ex_valid & ex_ready_go & ~mem_branch_flush;
            mem_alu_result    <= ex_alu_result;
            mem_pc            <= ex_pc;
            mem_pc_plus_4     <= ex_pc_plus_4;
            mem_rd            <= ex_rd;
            mem_reg_write_en  <= ex_reg_write_en;
            mem_wb_sel        <= ex_wb_sel;
            mem_mem_read_en   <= ex_mem_read_en;
            mem_mem_size      <= ex_mem_size;
            mem_mem_unsigned  <= ex_mem_unsigned;
            mem_store_wea     <= ex_store_wea;
            mem_store_data    <= ex_store_data;
            mem_is_cacheable  <= ex_is_cacheable;
        end
    end

    // 250MHz: branch_flush/target registered unconditionally
    // Must NOT be gated by mem_allowin — flush must propagate immediately
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_branch_flush  <= 1'b0;
            mem_branch_target <= 32'd0;
        end else begin
            mem_branch_flush  <= ex_branch_flush;
            mem_branch_target <= ex_branch_target;
        end
    end

endmodule
