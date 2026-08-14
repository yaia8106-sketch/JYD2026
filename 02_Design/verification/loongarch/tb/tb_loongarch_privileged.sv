`timescale 1ns/1ps

module tb_loongarch_privileged;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam logic [31:0] NOP = 32'h0340_0000;

    logic clk;
    logic rst_n;
    logic [11:0] irom_addr;
    logic [63:0] irom_data;
    logic [13:0] irom_predecode;
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
    logic cache_req;
    logic cache_wr;
    logic [31:0] cache_addr;
    logic cache_ready;
    logic [2:0] cache_phase;
    integer excp_count;
    integer ertn_count;
    integer csr_write_count;
    integer cache_wait_cycles;
    integer serializing_wait_cycles;
    integer csr_fire_while_cache_wait_count;
    integer trap_fire_while_cache_wait_count;
    integer ertn_fire_while_cache_wait_count;
    logic load_for_csr_observed;
    logic load_to_csr_wait_observed;
    logic csr_after_load_ex_observed;

    loongarch_icache_block_predecode u_irom_predecode (
        .block_data     (irom_data),
        .block_metadata (irom_predecode)
    );

    cpu_top #(.RESET_PC(RESET_PC)) u_cpu (
        .clk(clk), .rst_n(rst_n),
        .irom_addr(irom_addr), .irom_req_valid(), .irom_req_addr(),
        .irom_req_kill(),
        .irom_req_ready(1'b0), .irom_resp_valid(1'b0), .irom_data(irom_data),
        .irom_resp_predecode(irom_predecode),
        .cache_req(cache_req), .cache_wr(cache_wr),
        .cache_addr(cache_addr), .cache_lookup_addr(), .cache_wea(),
        .cache_wdata(), .cache_load_mask(), .cache_load_size(),
        .cache_load_unsigned(), .cache_uncached(),
        .cache_rdata(RESET_PC + 32'h100),
        .cache_rdata_ex(RESET_PC + 32'h100),
        .cache_ready(cache_ready), .cache_flush(),
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

    // Exercise the class-specific privileged commit cone independently of
    // the generic DCache-ready selector. Ordinary MEM tokens see periodic
    // backpressure. Once a privileged instruction legally reaches an empty
    // EX/backend boundary, force cache_ready low for that cycle: it must still
    // commit exactly once because an empty MEM stage has mem_allowin=1.
    always_comb begin
        if (!rst_n)
            cache_ready = 1'b1;
        else if (u_cpu.ex_valid && (u_cpu.ex_priv_op != PRIV_NONE))
            cache_ready = 1'b0;
        else
            cache_ready = cache_phase[1:0] != 2'b00;
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
            csr_write_count <= 0;
            cache_phase <= 3'd0;
            cache_wait_cycles <= 0;
            serializing_wait_cycles <= 0;
            csr_fire_while_cache_wait_count <= 0;
            trap_fire_while_cache_wait_count <= 0;
            ertn_fire_while_cache_wait_count <= 0;
            load_for_csr_observed <= 1'b0;
            load_to_csr_wait_observed <= 1'b0;
            csr_after_load_ex_observed <= 1'b0;
        end else begin
            cache_phase <= cache_phase + 3'd1;
            if (!cache_ready)
                cache_wait_cycles <= cache_wait_cycles + 1;
            if (u_cpu.id_valid && !u_cpu.id_serializing_ready)
                serializing_wait_cycles <= serializing_wait_cycles + 1;
            if (cache_req && !cache_wr
                && (cache_addr == 32'h8010_0000))
                load_for_csr_observed <= 1'b1;
            if (u_cpu.id_valid
                && (u_cpu.id_pc == RESET_PC + 32'h08)
                && !u_cpu.id_serializing_ready)
                load_to_csr_wait_observed <= 1'b1;
            if (u_cpu.ex_valid
                && (u_cpu.ex_pc == RESET_PC + 32'h08)
                && (u_cpu.ex_priv_op == PRIV_REG)) begin
                csr_after_load_ex_observed <= 1'b1;
                if (u_cpu.ex_rs1_wb_repair | u_cpu.ex_rs2_wb_repair)
                    $fatal(1,
                           "[FAIL] load-dependent CSR entered EX with WB repair");
                if (u_cpu.ex_rs1_data !== (RESET_PC + 32'h100))
                    $fatal(1,
                           "[FAIL] load-dependent CSR captured stale source data");
            end
            if (u_cpu.u_isa_priv_unit.ex_csr_write_fire) begin
                csr_write_count <= csr_write_count + 1;
                if (!cache_ready)
                    csr_fire_while_cache_wait_count <=
                        csr_fire_while_cache_wait_count + 1;
            end
            if (excp_valid) begin
                excp_count <= excp_count + 1;
                if (!cache_ready)
                    trap_fire_while_cache_wait_count <=
                        trap_fire_while_cache_wait_count + 1;
                if (excp_cause !== 6'h0b || excp_pc !== RESET_PC + 32'h18
                    || excp_inst !== 32'h002b_0000)
                    $fatal(1, "[FAIL] malformed SYSCALL exception event");
            end
            if (ertn_event) begin
                ertn_count <= ertn_count + 1;
                if (!cache_ready)
                    ertn_fire_while_cache_wait_count <=
                        ertn_fire_while_cache_wait_count + 1;
            end
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

    function automatic logic [31:0] enc_load(
        input logic [11:0] imm,
        input logic [4:0]  rj,
        input logic [4:0]  rd
    );
        enc_load = {6'h0a, 4'h2, imm, rj, rd};
    endfunction

    function automatic logic [31:0] enc_csr(
        input logic [13:0] addr,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_csr = {8'h04, addr, rj, rd};
    endfunction

    function automatic logic [31:0] enc_cpucfg(
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_cpucfg = {17'd0, 5'd27, rj, rd};
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
        csr_write_count = 0;
        cache_phase = 3'd0;
        cache_wait_cycles = 0;
        serializing_wait_cycles = 0;
        csr_fire_while_cache_wait_count = 0;
        trap_fire_while_cache_wait_count = 0;
        ertn_fire_while_cache_wait_count = 0;
        load_for_csr_observed = 1'b0;
        load_to_csr_wait_observed = 1'b0;
        csr_after_load_ex_observed = 1'b0;
        for (int i = 0; i < 256; i++)
            irom[i] = NOP;

        // The immediately following CSRWR consumes a cacheable load result.
        // Because CSR operations serialize, the load must fully leave WB and
        // update r2 before the CSR token enters EX; generic WB-repair muxes are
        // therefore neither necessary nor legal on the CSR operand path.
        irom['h00 >> 2] = enc_lu12i(20'h80100, 5'd2);
        irom['h04 >> 2] = enc_load(12'h000, 5'd2, 5'd2);
        irom['h08 >> 2] = enc_csr(14'h00c, 5'd1, 5'd2); // EENTRY
        irom['h0c >> 2] = enc_i12(12'd3, 5'd0, 5'd3);
        irom['h10 >> 2] = enc_i12(12'd7, 5'd0, 5'd4);
        irom['h14 >> 2] = enc_csr(14'h000, 5'd4, 5'd3); // CRMD xchg
        irom['h18 >> 2] = 32'h002b_0000;                // SYSCALL
        // ERTN resumes in PLV3. Exercise CPUCFG there as an unprivileged
        // register-indexed query, including the producer-to-consumer hazard.
        irom['h1c >> 2] = enc_i12(12'h010, 5'd0, 5'd15);
        irom['h20 >> 2] = enc_cpucfg(5'd15, 5'd16);
        irom['h24 >> 2] = enc_i12(12'h001, 5'd0, 5'd15);
        irom['h28 >> 2] = enc_cpucfg(5'd15, 5'd17);
        irom['h2c >> 2] = enc_i12(12'd1, 5'd0, 5'd31);
        irom['h30 >> 2] = 32'h5000_0000;

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
        check(csr_write_count == 3,
              "exactly three architectural CSR writes");
        check(cache_wait_cycles > 0,
              "privileged regression did not exercise MEM backpressure");
        check(serializing_wait_cycles > 0,
              "privileged regression did not wait behind an older token");
        check(load_for_csr_observed,
              "load-dependent CSR setup never issued its cacheable load");
        check(load_to_csr_wait_observed,
              "CSR did not visibly serialize behind the older load");
        check(csr_after_load_ex_observed,
              "load-dependent CSR never reached EX with committed data");
        check(csr_fire_while_cache_wait_count == 3,
              "CSR commit still depends on DCache ready or repeated");
        check(trap_fire_while_cache_wait_count == 1,
              "SYSCALL commit still depends on DCache ready or repeated");
        check(ertn_fire_while_cache_wait_count == 1,
              "ERTN commit still depends on DCache ready or repeated");
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
        check(u_cpu.u_regfile.regs[16] == 32'd0,
              "CPUCFG.0x10 hides caches without CACOP maintenance");
        check(u_cpu.u_regfile.regs[17] == 32'h0001_f1f0,
              "CPUCFG.1 reports simplified 32-bit LA32");
        $display("[PASS] LoongArch CSR/CPUCFG/SYSCALL/ERTN regression");
        $finish;
    end
endmodule
