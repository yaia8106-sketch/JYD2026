`timescale 1ns/1ps

module tb_loongarch_priv_commit_boundaries;
    import cpu_defs::*;

    localparam logic [13:0] CSR_EENTRY = 14'h00c;
    localparam logic [5:0] ECODE_ADE = 6'h08;
    localparam logic [5:0] ECODE_ALE = 6'h09;
    localparam logic [5:0] ECODE_BRK = 6'h0c;
    localparam logic [5:0] ECODE_INE = 6'h0d;
    localparam logic [5:0] ECODE_IPE = 6'h0e;

    logic clk;
    logic rst_n;
    logic ex_valid;
    logic ex_ready_go;
    logic ex_priv_commit_ready;
    logic mem_allowin;
    logic mem_branch_flush;
    logic ex_redirect_fire;
    logic [31:0] ex_pc;
    logic [31:0] ex_inst;
    logic [31:0] ex_src0_data;
    logic [31:0] ex_src1_data;
    priv_op_t ex_priv_op;
    logic ex_priv_uses_imm;
    priv_cmd_t ex_priv_cmd;
    logic [PRIV_ADDR_W-1:0] ex_priv_addr;
    logic [4:0] ex_priv_imm;
    decode_exception_t ex_exception;
    logic ex_mem_read_en;
    logic ex_mem_write_en;
    mem_size_t ex_mem_size;
    logic [31:0] ex_mem_addr;
    logic ex_s1_valid;
    logic ex_s1_mem_read_en;
    logic ex_s1_mem_write_en;
    mem_size_t ex_s1_mem_size;
    logic [31:0] ex_s1_mem_addr;
    logic timer_irq_pending;
    logic timer_irq_take;
    logic [31:0] timer_irq_mepc;
    logic ex_priv_flow;
    logic ex_priv_redirect;
    logic [31:0] ex_priv_target;
    logic ex_priv_trap;
    logic ex_priv_wait_older;
    logic ex_s1_addr_replay;
    logic timer_irq_request;
    logic timer_irq_redirect;
    logic [31:0] timer_irq_target;
    logic [31:0] ex_priv_rdata;
    logic debug_excp_valid;
    logic debug_ertn;
    logic [31:0] debug_intr_no;
    logic [5:0] debug_cause;
    logic [31:0] debug_exception_pc;
    logic [31:0] debug_exception_inst;
    logic [PRIV_DEBUG_STATE_W-1:0] debug_priv_state;

    integer exception_count;
    integer ertn_count;
    integer csr_write_count;

    loongarch_priv_unit dut (.*);

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            exception_count <= 0;
            ertn_count <= 0;
            csr_write_count <= 0;
        end else begin
            if (debug_excp_valid)
                exception_count <= exception_count + 1;
            if (debug_ertn)
                ertn_count <= ertn_count + 1;
            if (dut.ex_csr_write_fire)
                csr_write_count <= csr_write_count + 1;
        end
    end

    task automatic clear_token;
        begin
            ex_valid = 1'b0;
            ex_ready_go = 1'b0;
            ex_priv_commit_ready = 1'b0;
            mem_allowin = 1'b1;
            mem_branch_flush = 1'b0;
            ex_redirect_fire = 1'b0;
            ex_pc = 32'h1c00_0000;
            ex_inst = 32'h0340_0000;
            ex_src0_data = 32'd0;
            ex_src1_data = 32'd0;
            ex_priv_op = PRIV_NONE;
            ex_priv_uses_imm = 1'b0;
            ex_priv_cmd = PRIV_CMD_NONE;
            ex_priv_addr = '0;
            ex_priv_imm = 5'd0;
            ex_exception = EXCEPTION_NONE;
            ex_mem_read_en = 1'b0;
            ex_mem_write_en = 1'b0;
            ex_mem_size = MEM_WORD;
            ex_mem_addr = 32'd0;
            ex_s1_valid = 1'b0;
            ex_s1_mem_read_en = 1'b0;
            ex_s1_mem_write_en = 1'b0;
            ex_s1_mem_size = MEM_WORD;
            ex_s1_mem_addr = 32'd0;
            timer_irq_pending = 1'b0;
            timer_irq_take = 1'b0;
            timer_irq_mepc = 32'd0;
        end
    endtask

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "[FAIL] %s", message);
    endtask

    task automatic commit_csr_write(
        input logic [13:0] address,
        input logic [31:0] value
    );
        integer writes_before;
        begin
            writes_before = csr_write_count;
            @(negedge clk);
            clear_token();
            ex_valid = 1'b1;
            ex_priv_op = PRIV_REG;
            ex_priv_cmd = PRIV_CMD_WRITE;
            ex_priv_addr = {{(PRIV_ADDR_W-14){1'b0}}, address};
            ex_src0_data = value;

            // Model a serializing token waiting for registered older state.
            repeat (3) begin
                @(posedge clk);
                @(negedge clk);
                check(csr_write_count == writes_before,
                      "CSR changed state before commit readiness");
                check(!debug_excp_valid,
                      "supported CSR unexpectedly trapped while waiting");
                check(ex_priv_wait_older,
                      "writing CSR did not request older-token serialization");
            end

            ex_ready_go = 1'b1;
            ex_priv_commit_ready = 1'b1;
            ex_redirect_fire = 1'b1;
            #1;
            check(!debug_excp_valid,
                  "supported CSR write unexpectedly raised an exception");
            @(posedge clk);
            @(negedge clk);
            check(csr_write_count == writes_before + 1,
                  "CSR did not commit exactly once");
            clear_token();
        end
    endtask

    task automatic fire_exception(
        input logic [5:0] expected_cause,
        input logic [31:0] expected_pc,
        input logic [31:0] expected_inst
    );
        integer exceptions_before;
        begin
            exceptions_before = exception_count;
            // Inputs describing the exception are prepared by the caller.
            ex_valid = 1'b1;
            ex_pc = expected_pc;
            ex_inst = expected_inst;
            ex_ready_go = 1'b0;
            ex_priv_commit_ready = 1'b0;
            ex_redirect_fire = 1'b0;

            repeat (2) begin
                @(posedge clk);
                @(negedge clk);
                check(exception_count == exceptions_before,
                      "exception committed before older tokens drained");
                check(!debug_excp_valid,
                      "exception event asserted without stage fire");
            end

            ex_ready_go = 1'b1;
            ex_priv_commit_ready = 1'b1;
            ex_redirect_fire = 1'b1;
            #1;
            check(debug_excp_valid, "expected exception event missing");
            check(ex_priv_redirect, "exception did not request redirect");
            check(debug_cause == expected_cause,
                  "exception cause mismatch");
            check(debug_exception_pc == expected_pc,
                  "exception PC mismatch");
            check(debug_exception_inst == expected_inst,
                  "exception instruction mismatch");
            check(ex_priv_target == 32'h1c00_1000,
                  "exception target did not use aligned EENTRY");
            @(posedge clk);
            @(negedge clk);
            check(exception_count == exceptions_before + 1,
                  "exception did not commit exactly once");
            clear_token();
        end
    endtask

    initial begin
        rst_n = 1'b0;
        exception_count = 0;
        ertn_count = 0;
        csr_write_count = 0;
        clear_token();
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        commit_csr_write(CSR_EENTRY, 32'h1c00_103f);
        check(debug_priv_state[7*32 +: 32] == 32'h1c00_1000,
              "EENTRY low six bits were not masked");

        // Word load with address[1:0]!=0: wait, then raise one ALE and record
        // the bad data address. No memory side effect is permitted by the CPU
        // once ex_priv_trap is asserted.
        @(negedge clk);
        clear_token();
        ex_mem_read_en = 1'b1;
        ex_mem_size = MEM_WORD;
        ex_mem_addr = 32'h8040_0002;
        fire_exception(ECODE_ALE, 32'h1c00_0200, 32'h2880_0001);
        check(debug_priv_state[6*32 +: 32] == 32'h8040_0002,
              "misaligned load did not update BADV");

        // Odd halfword store is the second data-alignment boundary.
        @(negedge clk);
        clear_token();
        ex_mem_write_en = 1'b1;
        ex_mem_size = MEM_HALF;
        ex_mem_addr = 32'h8040_0101;
        fire_exception(ECODE_ALE, 32'h1c00_0204, 32'h2540_0001);
        check(debug_priv_state[6*32 +: 32] == 32'h8040_0101,
              "misaligned store did not update BADV");

        // A bad fetch address has higher cause priority than all other
        // synchronous causes and records the PC in BADV.
        @(negedge clk);
        clear_token();
        fire_exception(ECODE_ADE, 32'h1c00_0302, 32'h0340_0000);
        check(debug_priv_state[6*32 +: 32] == 32'h1c00_0302,
              "misaligned fetch did not update BADV");

        @(negedge clk);
        clear_token();
        ex_exception = EXCEPTION_BREAKPOINT;
        fire_exception(ECODE_BRK, 32'h1c00_0400, 32'h002a_0000);

        @(negedge clk);
        clear_token();
        ex_exception = EXCEPTION_ILLEGAL;
        fire_exception(ECODE_INE, 32'h1c00_0404, 32'hffff_ffff);

        @(negedge clk);
        clear_token();
        ex_priv_op = PRIV_REG;
        ex_priv_cmd = PRIV_CMD_NONE;
        ex_priv_addr = 16'h3fff;
        fire_exception(ECODE_IPE, 32'h1c00_0408, 32'h0400_0000);

        // An older redirect/flush owns the architectural boundary. Even with
        // all local readiness inputs high, the wrong-path SYSCALL must not
        // emit an event or alter trap state.
        @(negedge clk);
        clear_token();
        ex_valid = 1'b1;
        ex_ready_go = 1'b1;
        ex_priv_commit_ready = 1'b1;
        mem_branch_flush = 1'b1;
        ex_redirect_fire = 1'b0;
        ex_priv_op = PRIV_SYSCALL;
        ex_pc = 32'h1c00_0500;
        ex_inst = 32'h002b_0000;
        #1;
        check(!debug_excp_valid && !ex_priv_redirect,
              "flushed SYSCALL emitted a trap event");
        @(posedge clk);
        @(negedge clk);
        check(exception_count == 6,
              "flushed SYSCALL changed the exception count");
        clear_token();

        // Slot 1 alignment is replayed into Slot 0 rather than taking a second
        // same-cycle exception. Cover byte/half/word and read/write forms.
        ex_valid = 1'b1;
        ex_s1_valid = 1'b1;
        ex_s1_mem_read_en = 1'b1;
        ex_s1_mem_size = MEM_BYTE;
        ex_s1_mem_addr = 32'h8040_0003;
        #1;
        check(!ex_s1_addr_replay, "byte load incorrectly requested replay");
        ex_s1_mem_size = MEM_HALF;
        #1;
        check(ex_s1_addr_replay, "odd halfword load missed replay");
        ex_s1_mem_addr = 32'h8040_0002;
        #1;
        check(!ex_s1_addr_replay, "aligned halfword load replayed");
        ex_s1_mem_read_en = 1'b0;
        ex_s1_mem_write_en = 1'b1;
        ex_s1_mem_size = MEM_WORD;
        #1;
        check(ex_s1_addr_replay, "misaligned word store missed replay");
        ex_s1_mem_addr = 32'h8040_0004;
        #1;
        check(!ex_s1_addr_replay, "aligned word store replayed");
        clear_token();

        // ERTN uses the ERA from the most recent committed exception and must
        // also be a one-shot event at the registered commit boundary.
        @(negedge clk);
        clear_token();
        ex_valid = 1'b1;
        ex_ready_go = 1'b1;
        ex_priv_commit_ready = 1'b1;
        ex_redirect_fire = 1'b1;
        ex_priv_op = PRIV_RETURN;
        #1;
        check(debug_ertn && ex_priv_redirect,
              "ERTN did not emit its redirect event");
        check(ex_priv_target == 32'h1c00_0408,
              "ERTN target did not use the latest ERA");
        @(posedge clk);
        @(negedge clk);
        clear_token();

        check(csr_write_count == 1,
              "unexpected or repeated CSR write count");
        check(exception_count == 6,
              "unexpected or repeated exception count");
        check(ertn_count == 1,
              "ERTN did not commit exactly once");

        $display("[PASS] LoongArch privileged commit/alignment boundary test");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "[FAIL] privileged boundary test timeout");
    end
endmodule
