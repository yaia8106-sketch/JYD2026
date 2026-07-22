`timescale 1ns/1ps

module tb_loongarch_privileged;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam logic [31:0] NOP = 32'h0340_0000;

    logic clk;
    logic rst_n;
    logic [11:0] irom_addr;
    logic [63:0] irom_data;
    logic [31:0] irom [0:255];
    logic debug0_valid;
    logic [31:0] debug0_pc;
    logic [3:0] debug0_wen;
    logic [4:0] debug0_wnum;
    logic [31:0] debug0_wdata;
    logic debug1_valid;
    logic [3:0] debug1_wen;
    logic [4:0] debug1_wnum;
    logic [31:0] debug1_wdata;
    logic [863:0] priv_state;
    logic excp_valid;
    logic ertn_event;
    logic [5:0] excp_cause;
    logic [31:0] excp_pc;
    logic [31:0] excp_inst;
    integer excp_count;
    integer ertn_count;

    cpu_top #(.RESET_PC(RESET_PC)) u_cpu (
        .clk(clk), .rst_n(rst_n),
        .irom_addr(irom_addr), .irom_req_valid(), .irom_req_addr(),
        .irom_req_ready(1'b0), .irom_resp_valid(1'b0), .irom_data(irom_data),
        .cache_req(), .cache_wr(), .cache_addr(), .cache_wea(),
        .cache_wdata(), .cache_load_mask(), .cache_uncached(),
        .cache_rdata(32'd0), .cache_ready(1'b1), .cache_flush(),
        .cache_pipeline_stall(), .mmio_addr(), .mmio_wr_addr(),
        .mmio_wea(), .mmio_wdata(), .mmio_rdata(32'd0),
        .timer_irq_pending(1'b0),
        .debug0_wb_valid(debug0_valid), .debug0_wb_pc(debug0_pc),
        .debug0_wb_rf_wen(debug0_wen), .debug0_wb_rf_wnum(debug0_wnum),
        .debug0_wb_rf_wdata(debug0_wdata), .debug0_wb_inst(),
        .debug0_wb_exception(), .debug0_wb_mem_read(),
        .debug0_wb_mem_write(), .debug0_wb_mem_size(),
        .debug0_wb_mem_unsigned(), .debug0_wb_mem_addr(),
        .debug0_wb_store_data(), .debug0_wb_csr_rstat(),
        .debug0_wb_csr_data(),
        .debug1_wb_valid(debug1_valid), .debug1_wb_pc(),
        .debug1_wb_rf_wen(debug1_wen), .debug1_wb_rf_wnum(debug1_wnum),
        .debug1_wb_rf_wdata(debug1_wdata), .debug1_wb_inst(),
        .debug1_wb_mem_read(), .debug1_wb_mem_write(),
        .debug1_wb_mem_size(), .debug1_wb_mem_unsigned(),
        .debug1_wb_mem_addr(), .debug1_wb_store_data(),
        .debug_gpr_state(), .debug_priv_state(priv_state),
        .debug_excp_valid(excp_valid), .debug_ertn(ertn_event),
        .debug_intr_no(), .debug_cause(excp_cause),
        .debug_exception_pc(excp_pc), .debug_exception_inst(excp_inst)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (!rst_n)
            irom_data <= {NOP, NOP};
        else
            irom_data <= {irom[{irom_addr, 1'b1}],
                          irom[{irom_addr, 1'b0}]};
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            excp_count <= 0;
            ertn_count <= 0;
        end else begin
            if (excp_valid) begin
                excp_count <= excp_count + 1;
                if (excp_cause !== 6'h0b || excp_pc !== RESET_PC + 32'h18
                    || excp_inst !== 32'h002b_0000)
                    $fatal(1, "[FAIL] malformed SYSCALL exception event");
            end
            if (ertn_event)
                ertn_count <= ertn_count + 1;
        end
    end

    function automatic logic [31:0] enc_i12(
        input logic [11:0] imm,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_i12 = {6'h00, 4'ha, imm, rj, rd};
    endfunction

    function automatic logic [31:0] enc_lu12i(
        input logic [19:0] imm,
        input logic [4:0] rd
    );
        enc_lu12i = {6'h05, 1'b0, imm, rd};
    endfunction

    function automatic logic [31:0] enc_csr(
        input logic [13:0] addr,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_csr = {8'h04, addr, rj, rd};
    endfunction

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "[FAIL] %s", message);
    endtask

    initial begin
        bit completed;

        rst_n = 1'b0;
        irom_data = {NOP, NOP};
        excp_count = 0;
        ertn_count = 0;
        for (int i = 0; i < 256; i++)
            irom[i] = NOP;

        irom['h00 >> 2] = enc_lu12i(20'h80000, 5'd2);
        irom['h04 >> 2] = enc_i12(12'h100, 5'd2, 5'd2);
        irom['h08 >> 2] = enc_csr(14'h00c, 5'd1, 5'd2); // EENTRY
        irom['h0c >> 2] = enc_i12(12'd3, 5'd0, 5'd3);
        irom['h10 >> 2] = enc_i12(12'd7, 5'd0, 5'd4);
        irom['h14 >> 2] = enc_csr(14'h000, 5'd4, 5'd3); // CRMD xchg
        irom['h18 >> 2] = 32'h002b_0000;                // SYSCALL
        irom['h1c >> 2] = enc_i12(12'd1, 5'd0, 5'd31);
        irom['h20 >> 2] = 32'h5000_0000;

        irom['h100 >> 2] = enc_csr(14'h006, 5'd0, 5'd10); // ERA
        irom['h104 >> 2] = enc_csr(14'h005, 5'd0, 5'd11); // ESTAT
        irom['h108 >> 2] = enc_csr(14'h000, 5'd0, 5'd12); // CRMD
        irom['h10c >> 2] = enc_csr(14'h001, 5'd0, 5'd13); // PRMD
        irom['h110 >> 2] = enc_i12(12'd4, 5'd10, 5'd14);
        irom['h114 >> 2] = enc_csr(14'h006, 5'd1, 5'd14); // ERA = PC+4
        irom['h118 >> 2] = 32'h0648_3800;                 // ERTN

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        completed = 1'b0;
        for (int cycle = 0; cycle < 1000; cycle++) begin
            @(posedge clk);
            if ((debug0_valid && debug0_wen != 4'd0
                 && debug0_wnum == 5'd31 && debug0_wdata == 32'd1)
                || (debug1_valid && debug1_wen != 4'd0
                    && debug1_wnum == 5'd31 && debug1_wdata == 32'd1)) begin
                completed = 1'b1;
                break;
            end
        end

        check(completed, "privileged sequence timed out");
        repeat (3) @(posedge clk);
        check(excp_count == 1, "exactly one SYSCALL trap");
        check(ertn_count == 1, "exactly one ERTN event");
        check(u_cpu.u_regfile.regs[10] == RESET_PC + 32'h18,
              "ERA captured the faulting SYSCALL PC");
        check(u_cpu.u_regfile.regs[11][21:16] == 6'h0b,
              "ESTAT contains SYS ECODE");
        check(u_cpu.u_regfile.regs[12][2:0] == 3'd0,
              "trap entry forced PLV0 with interrupts disabled");
        check(u_cpu.u_regfile.regs[13][2:0] == 3'd3,
              "PRMD captured user PLV and IE");
        check(priv_state[0*32 +: 3] == 3'd3,
              "ERTN restored CRMD PLV/IE");
        check(priv_state[5*32 +: 32] == RESET_PC + 32'h1c,
              "handler advanced ERA before ERTN");
        $display("[PASS] LoongArch CSR/SYSCALL/ERTN regression");
        $finish;
    end
endmodule
