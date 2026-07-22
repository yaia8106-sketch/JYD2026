// ============================================================
// Module: riscv_priv_unit
// Description: Minimal RISC-V M-mode CSR, trap, and return state.
// ============================================================

module riscv_priv_unit
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        ex_valid,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,
    input  logic        ex_redirect_fire,

    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_inst,
    input  logic [31:0] ex_src0_data,
    input  logic [31:0] ex_src1_data,
    input  priv_op_t    ex_priv_op,
    input  logic        ex_priv_uses_imm,
    input  priv_cmd_t   ex_priv_cmd,
    input  logic [PRIV_ADDR_W-1:0] ex_priv_addr,
    input  logic [ 4:0] ex_priv_imm,
    input  decode_exception_t ex_exception,
    input  logic        ex_mem_read_en,
    input  logic        ex_mem_write_en,
    input  mem_size_t   ex_mem_size,
    input  logic [31:0] ex_mem_addr,
    input  logic        ex_s1_valid,
    input  logic        ex_s1_mem_read_en,
    input  logic        ex_s1_mem_write_en,
    input  mem_size_t   ex_s1_mem_size,
    input  logic [31:0] ex_s1_mem_addr,

    input  logic        timer_irq_pending,
    input  logic        timer_irq_take,
    input  logic [31:0] timer_irq_mepc,

    output logic        ex_priv_flow,
    output logic        ex_priv_redirect,
    output logic [31:0] ex_priv_target,
    output logic        ex_priv_trap,
    output logic        ex_priv_wait_older,
    output logic        ex_s1_addr_replay,
    output logic        timer_irq_request,
    output logic        timer_irq_redirect,
    output logic [31:0] timer_irq_target,
    output logic [31:0] ex_priv_rdata,
    output logic        debug_excp_valid,
    output logic        debug_ertn,
    output logic [31:0] debug_intr_no,
    output logic [ 5:0] debug_cause,
    output logic [31:0] debug_exception_pc,
    output logic [31:0] debug_exception_inst,
    output logic [PRIV_DEBUG_STATE_W-1:0] debug_priv_state
);

    localparam logic [11:0] CSR_MSTATUS  = 12'h300;
    localparam logic [11:0] CSR_MIE      = 12'h304;
    localparam logic [11:0] CSR_MTVEC    = 12'h305;
    localparam logic [11:0] CSR_MSCRATCH = 12'h340;
    localparam logic [11:0] CSR_MEPC     = 12'h341;
    localparam logic [11:0] CSR_MCAUSE   = 12'h342;
    localparam logic [11:0] CSR_MIP      = 12'h344;
    localparam logic [31:0] MSTATUS_WR_MASK = 32'h0000_0088;
    localparam logic [31:0] MIE_WR_MASK = 32'h0000_0080;
    localparam logic [31:0] MCAUSE_TIMER_INTERRUPT = 32'h8000_0007;

    logic [31:0] csr_mstatus;
    logic [31:0] csr_mie;
    logic [31:0] csr_mtvec;
    logic [31:0] csr_mscratch;
    logic [31:0] csr_mepc;
    logic [31:0] csr_mcause;
    wire [31:0] csr_mip = {24'd0, timer_irq_pending, 7'd0};
    wire [11:0] csr_addr = ex_priv_addr[11:0];

    wire ex_is_csr = ex_priv_op == PRIV_REG;
    wire ex_is_syscall = ex_priv_op == PRIV_SYSCALL;
    wire ex_is_return = ex_priv_op == PRIV_RETURN;
    wire ex_csr_supported = ~|ex_priv_addr[PRIV_ADDR_W-1:12]
                          & ((csr_addr == CSR_MSTATUS)
                           | (csr_addr == CSR_MIE)
                           | (csr_addr == CSR_MTVEC)
                           | (csr_addr == CSR_MSCRATCH)
                           | (csr_addr == CSR_MEPC)
                           | (csr_addr == CSR_MCAUSE)
                           | (csr_addr == CSR_MIP));

    wire [31:0] ex_csr_src = ex_priv_uses_imm
                           ? {27'd0, ex_priv_imm} : ex_src0_data;
    wire ex_csr_src_nonzero = |ex_csr_src;
    wire ex_csr_cmd_write = ex_priv_cmd == PRIV_CMD_WRITE;
    wire ex_csr_cmd_set = ex_priv_cmd == PRIV_CMD_SET;
    wire ex_csr_cmd_clear = ex_priv_cmd == PRIV_CMD_CLEAR;
    wire ex_csr_write_req = ex_is_csr & ex_csr_supported
                          & (ex_csr_cmd_write
                           | ((ex_csr_cmd_set | ex_csr_cmd_clear)
                              & ex_csr_src_nonzero));

    wire [31:0] ex_csr_wdata = ex_csr_cmd_write ? ex_csr_src :
                               ex_csr_cmd_set ? (ex_priv_rdata | ex_csr_src) :
                               ex_csr_cmd_clear ? (ex_priv_rdata & ~ex_csr_src) :
                                                  ex_priv_rdata;

    wire ex_csr_fire = ex_valid & ex_is_csr & ~mem_branch_flush
                     & ex_ready_go & mem_allowin;
    wire ex_csr_write_fire = ex_csr_fire & ex_csr_write_req;
    wire ex_syscall_fire = ex_priv_redirect & ex_is_syscall;
    wire ex_return_fire = ex_priv_redirect & ex_is_return;

    assign ex_priv_flow = ex_is_syscall | ex_is_return;
    assign ex_priv_redirect = ex_valid & ex_priv_flow & ex_redirect_fire;
    assign ex_priv_target = ex_is_syscall ? {csr_mtvec[31:2], 2'b00}
                                          : csr_mepc;
    assign ex_priv_trap = ex_valid & ex_is_syscall;
    assign ex_priv_wait_older = 1'b0;
    assign ex_s1_addr_replay = 1'b0;
    assign timer_irq_request = csr_mstatus[3] & csr_mie[7]
                             & timer_irq_pending;
    assign timer_irq_redirect = timer_irq_take;
    assign timer_irq_target = {csr_mtvec[31:2], 2'b00};
    assign debug_excp_valid = ex_syscall_fire | timer_irq_take;
    assign debug_ertn = ex_return_fire;
    assign debug_intr_no = timer_irq_pending ? 32'd7 : 32'd0;
    assign debug_cause = ex_is_syscall ? 6'd11 : 6'd0;
    assign debug_exception_pc = timer_irq_take ? timer_irq_mepc : ex_pc;
    assign debug_exception_inst = timer_irq_take ? 32'd0 : ex_inst;
    assign debug_priv_state = '0;

    // These are carried by the ISA-neutral interface for LoongArch address
    // exceptions.  Keep the existing RISC-V behavior unchanged here.
    wire unused_mem_exception_inputs = ex_mem_read_en ^ ex_mem_write_en
                                     ^ ex_mem_size[0] ^ ex_mem_addr[0]
                                     ^ ex_exception[0] ^ ex_s1_valid
                                     ^ ex_s1_mem_read_en
                                     ^ ex_s1_mem_write_en
                                     ^ ex_s1_mem_size[0]
                                     ^ ex_s1_mem_addr[0];

    assign ex_priv_rdata = (csr_addr == CSR_MSTATUS)  ? csr_mstatus :
                           (csr_addr == CSR_MIE)      ? csr_mie :
                           (csr_addr == CSR_MTVEC)    ? csr_mtvec :
                           (csr_addr == CSR_MSCRATCH) ? csr_mscratch :
                           (csr_addr == CSR_MEPC)     ? csr_mepc :
                           (csr_addr == CSR_MCAUSE)   ? csr_mcause :
                           (csr_addr == CSR_MIP)      ? csr_mip :
                                                       32'd0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            csr_mstatus  <= 32'd0;
            csr_mie      <= 32'd0;
            csr_mtvec    <= 32'd0;
            csr_mscratch <= 32'd0;
            csr_mepc     <= 32'd0;
            csr_mcause   <= 32'd0;
        end else begin
            if (ex_csr_write_fire) begin
                case (csr_addr)
                    CSR_MSTATUS:  csr_mstatus  <= ex_csr_wdata & MSTATUS_WR_MASK;
                    CSR_MIE:      csr_mie      <= ex_csr_wdata & MIE_WR_MASK;
                    CSR_MTVEC:    csr_mtvec    <= ex_csr_wdata;
                    CSR_MSCRATCH: csr_mscratch <= ex_csr_wdata;
                    CSR_MEPC:     csr_mepc     <= ex_csr_wdata;
                    CSR_MCAUSE:   csr_mcause   <= ex_csr_wdata;
                    default:      ;
                endcase
            end

            if (timer_irq_take) begin
                csr_mepc       <= timer_irq_mepc;
                csr_mcause     <= MCAUSE_TIMER_INTERRUPT;
                csr_mstatus[7] <= csr_mstatus[3];
                csr_mstatus[3] <= 1'b0;
            end else if (ex_syscall_fire) begin
                csr_mepc       <= ex_pc;
                csr_mcause     <= 32'd11;
                csr_mstatus[7] <= csr_mstatus[3];
                csr_mstatus[3] <= 1'b0;
            end else if (ex_return_fire) begin
                csr_mstatus[3] <= csr_mstatus[7];
                csr_mstatus[7] <= 1'b1;
            end
        end
    end

endmodule

module isa_priv_unit
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ex_valid,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,
    input  logic        ex_redirect_fire,
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_inst,
    input  logic [31:0] ex_src0_data,
    input  logic [31:0] ex_src1_data,
    input  priv_op_t    ex_priv_op,
    input  logic        ex_priv_uses_imm,
    input  priv_cmd_t   ex_priv_cmd,
    input  logic [PRIV_ADDR_W-1:0] ex_priv_addr,
    input  logic [ 4:0] ex_priv_imm,
    input  decode_exception_t ex_exception,
    input  logic        ex_mem_read_en,
    input  logic        ex_mem_write_en,
    input  mem_size_t   ex_mem_size,
    input  logic [31:0] ex_mem_addr,
    input  logic        ex_s1_valid,
    input  logic        ex_s1_mem_read_en,
    input  logic        ex_s1_mem_write_en,
    input  mem_size_t   ex_s1_mem_size,
    input  logic [31:0] ex_s1_mem_addr,
    input  logic        timer_irq_pending,
    input  logic        timer_irq_take,
    input  logic [31:0] timer_irq_mepc,
    output logic        ex_priv_flow,
    output logic        ex_priv_redirect,
    output logic [31:0] ex_priv_target,
    output logic        ex_priv_trap,
    output logic        ex_priv_wait_older,
    output logic        ex_s1_addr_replay,
    output logic        timer_irq_request,
    output logic        timer_irq_redirect,
    output logic [31:0] timer_irq_target,
    output logic [31:0] ex_priv_rdata,
    output logic        debug_excp_valid,
    output logic        debug_ertn,
    output logic [31:0] debug_intr_no,
    output logic [ 5:0] debug_cause,
    output logic [31:0] debug_exception_pc,
    output logic [31:0] debug_exception_inst,
    output logic [PRIV_DEBUG_STATE_W-1:0] debug_priv_state
);
    riscv_priv_unit u_impl (
        .clk                  (clk),
        .rst_n                (rst_n),
        .ex_valid             (ex_valid),
        .ex_ready_go          (ex_ready_go),
        .mem_allowin          (mem_allowin),
        .mem_branch_flush     (mem_branch_flush),
        .ex_redirect_fire     (ex_redirect_fire),
        .ex_pc                (ex_pc),
        .ex_inst              (ex_inst),
        .ex_src0_data         (ex_src0_data),
        .ex_src1_data         (ex_src1_data),
        .ex_priv_op           (ex_priv_op),
        .ex_priv_uses_imm     (ex_priv_uses_imm),
        .ex_priv_cmd          (ex_priv_cmd),
        .ex_priv_addr         (ex_priv_addr),
        .ex_priv_imm          (ex_priv_imm),
        .ex_exception         (ex_exception),
        .ex_mem_read_en       (ex_mem_read_en),
        .ex_mem_write_en      (ex_mem_write_en),
        .ex_mem_size          (ex_mem_size),
        .ex_mem_addr          (ex_mem_addr),
        .ex_s1_valid          (ex_s1_valid),
        .ex_s1_mem_read_en    (ex_s1_mem_read_en),
        .ex_s1_mem_write_en   (ex_s1_mem_write_en),
        .ex_s1_mem_size       (ex_s1_mem_size),
        .ex_s1_mem_addr       (ex_s1_mem_addr),
        .timer_irq_pending    (timer_irq_pending),
        .timer_irq_take       (timer_irq_take),
        .timer_irq_mepc       (timer_irq_mepc),
        .ex_priv_flow         (ex_priv_flow),
        .ex_priv_redirect     (ex_priv_redirect),
        .ex_priv_target       (ex_priv_target),
        .ex_priv_trap         (ex_priv_trap),
        .ex_priv_wait_older   (ex_priv_wait_older),
        .ex_s1_addr_replay    (ex_s1_addr_replay),
        .timer_irq_request    (timer_irq_request),
        .timer_irq_redirect   (timer_irq_redirect),
        .timer_irq_target     (timer_irq_target),
        .ex_priv_rdata        (ex_priv_rdata),
        .debug_excp_valid     (debug_excp_valid),
        .debug_ertn           (debug_ertn),
        .debug_intr_no        (debug_intr_no),
        .debug_cause          (debug_cause),
        .debug_exception_pc   (debug_exception_pc),
        .debug_exception_inst (debug_exception_inst),
        .debug_priv_state     (debug_priv_state)
    );
endmodule
