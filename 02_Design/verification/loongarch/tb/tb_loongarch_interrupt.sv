`timescale 1ns/1ps

module tb_loongarch_interrupt;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam logic [31:0] NOP = 32'h0340_0000;

    logic clk;
    logic rst_n;
    logic [11:0] irom_addr;
    logic [63:0] irom_data;
    logic [31:0] irom [0:255];
    logic debug0_valid;
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
    logic [31:0] intr_no;
    logic [5:0] excp_cause;
    logic [31:0] excp_pc;
    integer excp_count;
    integer ertn_count;
    integer soft_count;
    integer timer_count;

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
        .debug0_wb_valid(debug0_valid), .debug0_wb_pc(),
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
        .debug_intr_no(intr_no), .debug_cause(excp_cause),
        .debug_exception_pc(excp_pc), .debug_exception_inst()
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
            soft_count <= 0;
            timer_count <= 0;
        end else begin
            if (excp_valid) begin
                excp_count <= excp_count + 1;
                $display("[INFO] interrupt pc=%08x intrNo=%08x ESTAT=%08x",
                         excp_pc, intr_no, priv_state[4*32 +: 32]);
                if (excp_cause !== 6'h00)
                    $fatal(1, "[FAIL] interrupt event has a non-INT ECODE");
                if (priv_state[4*32 + 0]) begin
                    soft_count <= soft_count + 1;
                    if (intr_no !== 32'd0)
                        $fatal(1, "[FAIL] software interrupt number encoding");
                end else if (priv_state[4*32 + 11]) begin
                    timer_count <= timer_count + 1;
                    if (intr_no !== 32'h0000_0200)
                        $fatal(1, "[FAIL] timer interrupt number encoding");
                end else begin
                    $fatal(1, "[FAIL] interrupt event has no pending ESTAT bit");
                end
                if (excp_pc[1:0] !== 2'b00)
                    $fatal(1, "[FAIL] interrupt ERA is not instruction aligned");
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
        soft_count = 0;
        timer_count = 0;
        for (int i = 0; i < 256; i++)
            irom[i] = NOP;

        // Common interrupt setup: EENTRY=RESET_PC+0x100, enable SWI0, then
        // enable global interrupts and raise ESTAT.IS[0].
        irom['h00 >> 2] = enc_lu12i(20'h80000, 5'd2);
        irom['h04 >> 2] = enc_i12(12'h100, 5'd2, 5'd2);
        irom['h08 >> 2] = enc_csr(14'h00c, 5'd1, 5'd2); // EENTRY
        irom['h0c >> 2] = enc_i12(12'd1, 5'd0, 5'd3);
        irom['h10 >> 2] = enc_csr(14'h004, 5'd1, 5'd3); // ECFG.IS0
        irom['h14 >> 2] = enc_i12(12'd4, 5'd0, 5'd4);
        irom['h18 >> 2] = enc_csr(14'h000, 5'd4, 5'd4); // CRMD.IE=1
        // CSRWR returns the previous CSR value in its source/destination
        // register, so reload r3 after using it for ECFG.
        irom['h1c >> 2] = enc_i12(12'd1, 5'd0, 5'd3);
        irom['h20 >> 2] = enc_csr(14'h005, 5'd1, 5'd3); // ESTAT.IS0=1

        // The first ERTN resumes here. Reconfigure ECFG for TI, start a
        // one-shot timer, then keep a legal instruction at the interrupt
        // boundary.  -2048 leaves ECFG.LIE[11] set after its architectural
        // write mask is applied; bit 12 is harmless with no IPI source.
        irom['h24 >> 2] = enc_i12(12'd1, 5'd0, 5'd31);
        irom['h28 >> 2] = enc_i12(12'h800, 5'd0, 5'd5);
        irom['h2c >> 2] = enc_csr(14'h004, 5'd1, 5'd5); // ECFG.TI
        irom['h30 >> 2] = enc_i12(12'd17, 5'd0, 5'd6);
        irom['h34 >> 2] = enc_csr(14'h041, 5'd1, 5'd6); // TCFG=0x11
        irom['h38 >> 2] = 32'h5000_0000;                // b .

        // One handler services both sources. Software bits are cleared by
        // writing ESTAT, TI by TICLR, and TCFG is disabled before ERTN.
        irom['h100 >> 2] = enc_i12(12'd1, 5'd20, 5'd20);
        irom['h104 >> 2] = enc_csr(14'h005, 5'd1, 5'd0); // ESTAT.IS[1:0]=0
        irom['h108 >> 2] = enc_i12(12'd1, 5'd0, 5'd21);
        irom['h10c >> 2] = enc_csr(14'h044, 5'd1, 5'd21); // TICLR.TI=1
        irom['h110 >> 2] = enc_csr(14'h041, 5'd1, 5'd0);  // TCFG.En=0
        irom['h114 >> 2] = 32'h0648_3800;                 // ERTN

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        completed = 1'b0;
        for (int cycle = 0; cycle < 3000; cycle++) begin
            @(posedge clk);
            if ((debug0_valid && debug0_wen != 4'd0
                 && debug0_wnum == 5'd20 && debug0_wdata == 32'd2)
                || (debug1_valid && debug1_wen != 4'd0
                    && debug1_wnum == 5'd20 && debug1_wdata == 32'd2)) begin
                completed = 1'b1;
                break;
            end
        end

        if (!completed)
            $display("[INFO] timeout count=%0d excp=%0d ertn=%0d CRMD=%08x ECFG=%08x ESTAT=%08x TCFG=%08x TVAL=%08x",
                     u_cpu.u_regfile.regs[20], excp_count, ertn_count,
                     priv_state[0*32 +: 32], priv_state[3*32 +: 32],
                     priv_state[4*32 +: 32], priv_state[20*32 +: 32],
                     priv_state[21*32 +: 32]);
        check(completed, "software/timer interrupt sequence timed out");
        repeat (30) @(posedge clk);
        check(excp_count == 2, "exactly two interrupt entries");
        check(soft_count == 1, "exactly one software interrupt");
        check(timer_count == 1, "exactly one timer interrupt");
        check(ertn_count == 2, "exactly two ERTN events");
        check(u_cpu.u_regfile.regs[20] == 32'd2,
              "handler executed once for each source");
        check(priv_state[0*32 + 2] == 1'b1,
              "ERTN restored CRMD.IE");
        check(priv_state[1*32 + 2] == 1'b1,
              "PRMD captured enabled interrupts");
        check(priv_state[4*32 +: 13] == 13'd0,
              "handler cleared all interrupt-pending bits");
        check(priv_state[20*32 +: 32] == 32'd0,
              "handler disabled TCFG");
        $display("[PASS] LoongArch software/timer interrupt regression");
        $finish;
    end
endmodule
