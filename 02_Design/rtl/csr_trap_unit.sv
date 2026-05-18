// ============================================================
// Module: csr_trap_unit
// Description: Minimal M-mode CSR state and synchronous trap control.
// ============================================================

module csr_trap_unit (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        ex_valid,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,
    input  logic        ex_redirect_fire,

    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_rs1_data,
    input  logic [ 4:0] ex_rs1_addr,
    input  logic        ex_is_csr,
    input  logic        ex_csr_uses_imm,
    input  logic [ 2:0] ex_csr_cmd,
    input  logic [11:0] ex_csr_addr,
    input  logic        ex_is_ecall,
    input  logic        ex_is_mret,

    output logic        ex_system_inst,
    output logic        ex_system_redirect,
    output logic [31:0] ex_system_target,
    output logic [31:0] ex_csr_rdata
);

    localparam logic [11:0] CSR_MSTATUS  = 12'h300;
    localparam logic [11:0] CSR_MTVEC    = 12'h305;
    localparam logic [11:0] CSR_MSCRATCH = 12'h340;
    localparam logic [11:0] CSR_MEPC     = 12'h341;
    localparam logic [11:0] CSR_MCAUSE   = 12'h342;
    localparam logic [31:0] MSTATUS_WR_MASK = 32'h0000_0088;

    logic [31:0] csr_mstatus;
    logic [31:0] csr_mtvec;
    logic [31:0] csr_mscratch;
    logic [31:0] csr_mepc;
    logic [31:0] csr_mcause;

    wire ex_csr_supported = (ex_csr_addr == CSR_MSTATUS)
                          | (ex_csr_addr == CSR_MTVEC)
                          | (ex_csr_addr == CSR_MSCRATCH)
                          | (ex_csr_addr == CSR_MEPC)
                          | (ex_csr_addr == CSR_MCAUSE);

    wire [31:0] ex_csr_src = ex_csr_uses_imm ? {27'd0, ex_rs1_addr} : ex_rs1_data;
    wire        ex_csr_src_nonzero = |ex_csr_src;
    wire        ex_csr_cmd_write = (ex_csr_cmd[1:0] == 2'b01);
    wire        ex_csr_cmd_set   = (ex_csr_cmd[1:0] == 2'b10);
    wire        ex_csr_cmd_clear = (ex_csr_cmd[1:0] == 2'b11);
    wire        ex_csr_write_req = ex_is_csr & ex_csr_supported
                                 & (ex_csr_cmd_write
                                  | ((ex_csr_cmd_set | ex_csr_cmd_clear) & ex_csr_src_nonzero));

    wire [31:0] ex_csr_wdata = ex_csr_cmd_write ? ex_csr_src :
                                ex_csr_cmd_set   ? (ex_csr_rdata | ex_csr_src) :
                                ex_csr_cmd_clear ? (ex_csr_rdata & ~ex_csr_src) :
                                                   ex_csr_rdata;

    wire ex_csr_fire = ex_valid & ex_is_csr & ~mem_branch_flush
                     & ex_ready_go & mem_allowin;
    wire ex_csr_write_fire = ex_csr_fire & ex_csr_write_req;
    wire ex_ecall_fire = ex_system_redirect & ex_is_ecall;
    wire ex_mret_fire = ex_system_redirect & ex_is_mret;

    assign ex_system_inst = ex_is_ecall | ex_is_mret;
    assign ex_system_redirect = ex_valid & ex_system_inst & ex_redirect_fire;
    assign ex_system_target = ex_is_ecall ? {csr_mtvec[31:2], 2'b00} : csr_mepc;

    assign ex_csr_rdata = (ex_csr_addr == CSR_MSTATUS)  ? csr_mstatus :
                          (ex_csr_addr == CSR_MTVEC)    ? csr_mtvec :
                          (ex_csr_addr == CSR_MSCRATCH) ? csr_mscratch :
                          (ex_csr_addr == CSR_MEPC)     ? csr_mepc :
                          (ex_csr_addr == CSR_MCAUSE)   ? csr_mcause :
                                                          32'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_mstatus  <= 32'd0;
            csr_mtvec    <= 32'd0;
            csr_mscratch <= 32'd0;
            csr_mepc     <= 32'd0;
            csr_mcause   <= 32'd0;
        end else begin
            if (ex_csr_write_fire) begin
                case (ex_csr_addr)
                    CSR_MSTATUS:  csr_mstatus  <= ex_csr_wdata & MSTATUS_WR_MASK;
                    CSR_MTVEC:    csr_mtvec    <= ex_csr_wdata;
                    CSR_MSCRATCH: csr_mscratch <= ex_csr_wdata;
                    CSR_MEPC:     csr_mepc     <= ex_csr_wdata;
                    CSR_MCAUSE:   csr_mcause   <= ex_csr_wdata;
                    default:      ;
                endcase
            end

            if (ex_ecall_fire) begin
                csr_mepc       <= ex_pc;
                csr_mcause     <= 32'd11;
                csr_mstatus[7] <= csr_mstatus[3];
                csr_mstatus[3] <= 1'b0;
            end else if (ex_mret_fire) begin
                csr_mstatus[3] <= csr_mstatus[7];
                csr_mstatus[7] <= 1'b1;
            end
        end
    end

endmodule
