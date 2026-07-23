`timescale 1ns/1ps

module tb_loongarch_cpu_smoke;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam logic [31:0] LOONGARCH_NOP = 32'h0340_0000;
    localparam int IROM_WORDS = 4096;
    localparam int DATA_WORDS = 256;

    logic clk;
    logic rst_n;

    logic [11:0] irom_addr;
    logic [63:0] irom_data;
    logic [31:0] irom [0:IROM_WORDS-1];

    logic cache_req;
    logic cache_wr;
    logic [31:0] cache_addr;
    logic [3:0] cache_wea;
    logic [31:0] cache_wdata;
    logic [3:0] cache_load_mask;
    logic [31:0] cache_rdata;
    logic cache_ready;
    logic cache_flush;
    logic cache_pipeline_stall;

    logic [31:0] mmio_addr;
    logic [31:0] mmio_wr_addr;
    logic [3:0] mmio_wea;
    logic [31:0] mmio_wdata;

    logic [31:0] data_mem [0:DATA_WORDS-1];
    logic cache_req_q;
    logic cache_wr_q;
    logic [31:0] cache_addr_q;
    logic [3:0] cache_wea_q;
    logic bad_path_committed;
    logic bad_path_store_committed;
    integer cache_store_count;
    integer cache_load_count;

    cpu_top u_cpu (
        .clk(clk),
        .rst_n(rst_n),
        .irom_addr(irom_addr),
        .irom_req_valid(),
        .irom_req_addr(),
        .irom_req_ready(1'b0),
        .irom_resp_valid(1'b0),
        .irom_data(irom_data),
        .cache_req(cache_req),
        .cache_wr(cache_wr),
        .cache_addr(cache_addr),
        .cache_wea(cache_wea),
        .cache_wdata(cache_wdata),
        .cache_load_mask(cache_load_mask),
        .cache_uncached(),
        .cache_rdata(cache_rdata),
        .cache_ready(cache_ready),
        .cache_flush(cache_flush),
        .cache_pipeline_stall(cache_pipeline_stall),
        .mmio_addr(mmio_addr),
        .mmio_wr_addr(mmio_wr_addr),
        .mmio_wea(mmio_wea),
        .mmio_wdata(mmio_wdata),
        .mmio_rdata(32'd0),
        .timer_irq_pending(1'b0),
        .debug0_wb_valid(),
        .debug0_wb_pc(),
        .debug0_wb_rf_wen(),
        .debug0_wb_rf_wnum(),
        .debug0_wb_rf_wdata(),
        .debug1_wb_valid(),
        .debug1_wb_pc(),
        .debug1_wb_rf_wen(),
        .debug1_wb_rf_wnum(),
        .debug1_wb_rf_wdata(),
        .debug0_wb_inst          (),
        .debug0_wb_exception     (),
        .debug0_wb_mem_read      (),
        .debug0_wb_mem_write     (),
        .debug0_wb_mem_size      (),
        .debug0_wb_mem_unsigned  (),
        .debug0_wb_mem_addr      (),
        .debug0_wb_store_data    (),
        .debug0_wb_csr_rstat     (),
        .debug0_wb_csr_data      (),
        .debug1_wb_inst          (),
        .debug1_wb_mem_read      (),
        .debug1_wb_mem_write     (),
        .debug1_wb_mem_size      (),
        .debug1_wb_mem_unsigned  (),
        .debug1_wb_mem_addr      (),
        .debug1_wb_store_data    (),
        .debug_gpr_state         (),
        .debug_priv_state        (),
        .debug_excp_valid        (),
        .debug_ertn              (),
        .debug_intr_no           (),
        .debug_cause             (),
        .debug_exception_pc      (),
        .debug_exception_inst    ()
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    wire [12:0] irom_word0_addr = {irom_addr, 1'b0};
    wire [12:0] irom_word1_addr = {irom_addr, 1'b1};

    always @(posedge clk) begin
        if (!rst_n)
            irom_data <= {LOONGARCH_NOP, LOONGARCH_NOP};
        else begin
            irom_data <= {
                (irom_word1_addr < IROM_WORDS)
                    ? irom[irom_word1_addr] : LOONGARCH_NOP,
                (irom_word0_addr < IROM_WORDS)
                    ? irom[irom_word0_addr] : LOONGARCH_NOP
            };
        end
    end

    // The request address/strobes are sampled at the EX1/EX2 edge. Store data
    // is finalized during EX2 and is therefore consumed with the registered
    // request one cycle later, matching the real DCache.
    wire [31:0] cache_wdata_aligned =
        cache_wdata << {cache_addr_q[1:0], 3'b0};
    wire [$clog2(DATA_WORDS)-1:0] cache_word_index = cache_addr[9:2];
    wire [$clog2(DATA_WORDS)-1:0] cache_word_index_q = cache_addr_q[9:2];

    assign cache_ready = 1'b1;
    assign cache_rdata = data_mem[cache_word_index_q];

    always @(posedge clk) begin
        if (!rst_n) begin
            cache_addr_q <= 32'd0;
            cache_req_q <= 1'b0;
            cache_wr_q <= 1'b0;
            cache_wea_q <= 4'd0;
            cache_store_count <= 0;
            cache_load_count <= 0;
        end else begin
            cache_req_q <= cache_req & ~cache_flush;
            cache_wr_q <= cache_wr;
            cache_addr_q <= cache_addr;
            cache_wea_q <= cache_wea;

            if (cache_req_q && cache_wr_q && !cache_flush) begin
                cache_store_count <= cache_store_count + 1;
                for (int byte_lane = 0; byte_lane < 4; byte_lane++) begin
                    if (cache_wea_q[byte_lane])
                        data_mem[cache_word_index_q][byte_lane*8 +: 8]
                            <= cache_wdata_aligned[byte_lane*8 +: 8];
                end
            end
            if (cache_req && !cache_wr)
                cache_load_count <= cache_load_count + 1;
        end
    end

    function automatic logic [31:0] enc_rr(
        input logic [1:0] op_21_20,
        input logic [4:0] op_19_15,
        input logic [4:0] rk,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_rr = {6'h00, 4'h0, op_21_20, op_19_15, rk, rj, rd};
    endfunction

    function automatic logic [31:0] enc_i12(
        input logic [5:0] op_31_26,
        input logic [3:0] op_25_22,
        input logic [11:0] immediate,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_i12 = {op_31_26, op_25_22, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] enc_upper(
        input logic [5:0] op_31_26,
        input logic [19:0] immediate,
        input logic [4:0] rd
    );
        enc_upper = {op_31_26, 1'b0, immediate, rd};
    endfunction

    function automatic logic [31:0] enc_i16(
        input logic [5:0] op_31_26,
        input logic [15:0] immediate,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_i16 = {op_31_26, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] enc_i26(
        input logic [5:0] op_31_26,
        input logic [25:0] immediate
    );
        enc_i26 = {op_31_26, immediate[15:0], immediate[25:16]};
    endfunction

    function automatic logic [31:0] add_w(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [4:0] rk
    );
        add_w = enc_rr(2'h1, 5'h00, rk, rj, rd);
    endfunction

    function automatic logic [31:0] nor_op(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [4:0] rk
    );
        nor_op = enc_rr(2'h1, 5'h08, rk, rj, rd);
    endfunction

    function automatic logic [31:0] mul_w(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [4:0] rk
    );
        mul_w = enc_rr(2'h1, 5'h18, rk, rj, rd);
    endfunction

    function automatic logic [31:0] div_w(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [4:0] rk
    );
        div_w = enc_rr(2'h2, 5'h00, rk, rj, rd);
    endfunction

    function automatic logic [31:0] addi_w(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [11:0] immediate
    );
        addi_w = enc_i12(6'h00, 4'ha, immediate, rj, rd);
    endfunction

    function automatic logic [31:0] lu12i_w(
        input logic [4:0] rd,
        input logic [19:0] immediate
    );
        lu12i_w = enc_upper(6'h05, immediate, rd);
    endfunction

    function automatic logic [31:0] pcaddu12i(
        input logic [4:0] rd,
        input logic [19:0] immediate
    );
        pcaddu12i = enc_upper(6'h07, immediate, rd);
    endfunction

    function automatic logic [31:0] st_w(
        input logic [4:0] data_rd,
        input logic [4:0] base_rj,
        input logic [11:0] immediate
    );
        st_w = enc_i12(6'h0a, 4'h6, immediate, base_rj, data_rd);
    endfunction

    function automatic logic [31:0] ld_w(
        input logic [4:0] rd,
        input logic [4:0] base_rj,
        input logic [11:0] immediate
    );
        ld_w = enc_i12(6'h0a, 4'h2, immediate, base_rj, rd);
    endfunction

    function automatic logic [31:0] load_i12(
        input logic [3:0] op_25_22,
        input logic [4:0] rd,
        input logic [4:0] base_rj,
        input logic [11:0] immediate
    );
        load_i12 = enc_i12(6'h0a, op_25_22, immediate, base_rj, rd);
    endfunction

    function automatic logic [31:0] store_i12(
        input logic [3:0] op_25_22,
        input logic [4:0] data_rd,
        input logic [4:0] base_rj,
        input logic [11:0] immediate
    );
        store_i12 = enc_i12(6'h0a, op_25_22, immediate,
                            base_rj, data_rd);
    endfunction

    function automatic logic [31:0] beq(
        input logic [4:0] rj,
        input logic [4:0] compare_rd,
        input logic [15:0] immediate
    );
        beq = enc_i16(6'h16, immediate, rj, compare_rd);
    endfunction

    function automatic logic [31:0] bne(
        input logic [4:0] rj,
        input logic [4:0] compare_rd,
        input logic [15:0] immediate
    );
        bne = enc_i16(6'h17, immediate, rj, compare_rd);
    endfunction

    function automatic logic [31:0] jirl(
        input logic [4:0] rd,
        input logic [4:0] rj,
        input logic [15:0] immediate
    );
        jirl = enc_i16(6'h13, immediate, rj, rd);
    endfunction

    function automatic logic [31:0] branch_always(
        input logic [25:0] immediate
    );
        branch_always = enc_i26(6'h14, immediate);
    endfunction

    function automatic logic [31:0] branch_link(
        input logic [25:0] immediate
    );
        branch_link = enc_i26(6'h15, immediate);
    endfunction

    task automatic put_instruction(
        input logic [31:0] byte_offset,
        input logic [31:0] instruction
    );
        irom[byte_offset[13:2]] = instruction;
    endtask

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "[FAIL] %s", message);
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            bad_path_committed <= 1'b0;
            bad_path_store_committed <= 1'b0;
        end else begin
            if (u_cpu.wb_valid && u_cpu.wb_reg_write_en
                && (u_cpu.wb_rd == 5'd31)
                && (u_cpu.wb_write_data != 32'd1))
                bad_path_committed <= 1'b1;
            if (u_cpu.wb_s1_valid && u_cpu.wb_s1_reg_write_en
                && (u_cpu.wb_s1_rd == 5'd31)
                && (u_cpu.wb_s1_write_data != 32'd1))
                bad_path_committed <= 1'b1;
            if (|mmio_wea)
                bad_path_store_committed <= 1'b1;
        end
    end

    initial begin
        bit completed;

        rst_n = 1'b0;
        irom_data = {LOONGARCH_NOP, LOONGARCH_NOP};
        cache_addr_q = 32'd0;
        bad_path_committed = 1'b0;
        bad_path_store_committed = 1'b0;
        cache_store_count = 0;
        cache_load_count = 0;

        for (int i = 0; i < IROM_WORDS; i++)
            irom[i] = LOONGARCH_NOP;
        for (int i = 0; i < DATA_WORDS; i++)
            data_mem[i] = 32'd0;
        data_mem[8'h41] = 32'h80ff_7f01;

        // Arithmetic and both encoding-leak guards.  MUL uses rk=20 so
        // inst[14]=1; DIV uses rk=5 so inst[14]=0.
        put_instruction(32'h00, addi_w(5'd2, 5'd0, 12'd7));
        put_instruction(32'h04, addi_w(5'd20, 5'd0, 12'd3));
        put_instruction(32'h08, mul_w(5'd3, 5'd2, 5'd20));
        put_instruction(32'h0c, addi_w(5'd4, 5'd3, 12'd1));
        put_instruction(32'h10, addi_w(5'd5, 5'd0, 12'd3));
        put_instruction(32'h14, div_w(5'd6, 5'd3, 5'd5));
        put_instruction(32'h18, addi_w(5'd7, 5'd6, 12'd1));
        put_instruction(32'h1c, nor_op(5'd8, 5'd7, 5'd0));

        // Taken Slot-0 branch and younger Slot-1 store share EX2.  The branch
        // decision must suppress the store before it can reach MMIO.
        put_instruction(32'h20, beq(5'd7, 5'd7, 16'd2));
        put_instruction(32'h24, st_w(5'd7, 5'd0, 12'd0));

        // Ordinary JIRL checks target formation and link writeback.
        put_instruction(32'h28, pcaddu12i(5'd10, 20'd0));
        put_instruction(32'h2c, addi_w(5'd10, 5'd10, 12'd16));
        put_instruction(32'h30, jirl(5'd11, 5'd10, 16'd0));
        put_instruction(32'h34, addi_w(5'd31, 5'd0, 12'h02b));

        // Cacheable aligned store/load plus a load-use, not-taken branch.
        put_instruction(32'h38, lu12i_w(5'd12, 20'h80100));
        put_instruction(32'h3c, addi_w(5'd12, 5'd12, 12'h100));
        put_instruction(32'h40, st_w(5'd7, 5'd12, 12'd0));
        put_instruction(32'h44, ld_w(5'd13, 5'd12, 12'd0));
        put_instruction(32'h48, bne(5'd13, 5'd7, 16'd2));
        put_instruction(32'h4c, add_w(5'd14, 5'd13, 5'd0));

        // Signed/unsigned load formatting and byte/half store lanes.
        put_instruction(32'h50,
                        load_i12(4'h0, 5'd17, 5'd12, 12'd7));
        put_instruction(32'h54,
                        load_i12(4'h8, 5'd18, 5'd12, 12'd6));
        put_instruction(32'h58,
                        load_i12(4'h1, 5'd19, 5'd12, 12'd6));
        put_instruction(32'h5c,
                        load_i12(4'h9, 5'd21, 5'd12, 12'd4));
        put_instruction(32'h60,
                        store_i12(4'h4, 5'd8, 5'd12, 12'd8));
        put_instruction(32'h64,
                        store_i12(4'h5, 5'd7, 5'd12, 12'd10));
        put_instruction(32'h68, ld_w(5'd22, 5'd12, 12'd8));

        // A write to r0 must not alter the following source value.
        put_instruction(32'h6c, addi_w(5'd0, 5'd0, 12'd123));
        put_instruction(32'h70, add_w(5'd16, 5'd0, 5'd7));

        // rd==rj requires the old r15 value for the target, then writes link.
        // Jump to an aligned pair at 0x88 so its same-pair dependencies are
        // deterministic rather than relying on cross-packet pairing.
        put_instruction(32'h74, pcaddu12i(5'd15, 20'd0));
        put_instruction(32'h78, addi_w(5'd15, 5'd15, 12'd20));
        put_instruction(32'h7c, jirl(5'd15, 5'd15, 16'd0));
        put_instruction(32'h80, addi_w(5'd31, 5'd0, 12'h02c));
        put_instruction(32'h84, addi_w(5'd31, 5'd0, 12'h02f));

        // Same-pair ALU->ALU, same-pair ALU->store-data, then an adjacent
        // load-use followed by a consumer->producer dependency chain.
        put_instruction(32'h88, addi_w(5'd23, 5'd0, 12'd9));
        put_instruction(32'h8c, add_w(5'd24, 5'd23, 5'd7));
        put_instruction(32'h90, addi_w(5'd26, 5'd0, 12'h055));
        put_instruction(32'h94, st_w(5'd26, 5'd12, 12'd12));
        put_instruction(32'h98, ld_w(5'd27, 5'd12, 12'd12));
        put_instruction(32'h9c, add_w(5'd28, 5'd27, 5'd7));
        put_instruction(32'ha0, add_w(5'd29, 5'd28, 5'd7));
        put_instruction(32'ha4, add_w(5'd30, 5'd29, 5'd7));

        // Slot-1 branch consumes the Slot-0 ALU result in the same pair.
        // If that local EX2 path is wrong, the bad-path marker at 0xb0 retires.
        put_instruction(32'ha8, addi_w(5'd9, 5'd0, 12'd1));
        put_instruction(32'hac, bne(5'd9, 5'd0, 16'd2));
        put_instruction(32'hb0, addi_w(5'd31, 5'd0, 12'h02e));

        // BL must write its architectural link to r1 and squash its follower.
        put_instruction(32'hb4, branch_link(26'd2));
        put_instruction(32'hb8, addi_w(5'd31, 5'd0, 12'h02d));
        put_instruction(32'hbc, addi_w(5'd31, 5'd0, 12'd1));
        put_instruction(32'hc0, branch_always(26'd0));

        check(irom[32'h08 >> 2][14] == 1'b1,
              "CPU MUL leak guard must set inst[14]");
        check(irom[32'h14 >> 2][14] == 1'b0,
              "CPU DIV leak guard must clear inst[14]");

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        completed = 1'b0;
        for (int cycle = 0; cycle < 1200; cycle++) begin
            @(posedge clk);
            if ((u_cpu.wb_valid && u_cpu.wb_reg_write_en
                 && (u_cpu.wb_rd == 5'd31)
                 && (u_cpu.wb_write_data == 32'd1))
                || (u_cpu.wb_s1_valid && u_cpu.wb_s1_reg_write_en
                    && (u_cpu.wb_s1_rd == 5'd31)
                    && (u_cpu.wb_s1_write_data == 32'd1))) begin
                completed = 1'b1;
                break;
            end
        end
        check(completed, "CPU smoke program timed out before completion marker");
        repeat (4) @(posedge clk);

        check(!bad_path_committed,
              "a squashed branch/JIRL bad-path marker reached writeback");
        check(!bad_path_store_committed,
              "a younger same-pair store survived an older taken branch");
        check(u_cpu.u_regfile.regs[3] == 32'd21,
              "MUL.W architectural result");
        check(u_cpu.u_regfile.regs[4] == 32'd22,
              "MUL dependency/forwarding result");
        check(u_cpu.u_regfile.regs[6] == 32'd7,
              "DIV.W architectural result");
        check(u_cpu.u_regfile.regs[7] == 32'd8,
              "DIV dependency/forwarding result");
        check(u_cpu.u_regfile.regs[8] == 32'hffff_fff7,
              "NOR architectural result");
        check(u_cpu.u_regfile.regs[11] == (RESET_PC + 32'h34),
              "JIRL link result");
        check(data_mem[8'h40] == 32'd8,
              "ST.W memory result");
        check(u_cpu.u_regfile.regs[13] == 32'd8,
              "LD.W architectural result");
        check(u_cpu.u_regfile.regs[14] == 32'd8,
              "load-use forwarding result");
        check(u_cpu.u_regfile.regs[17] == 32'hffff_ff80,
              "LD.B sign extension result");
        check(u_cpu.u_regfile.regs[18] == 32'h0000_00ff,
              "LD.BU zero extension result");
        check(u_cpu.u_regfile.regs[19] == 32'hffff_80ff,
              "LD.H sign extension result");
        check(u_cpu.u_regfile.regs[21] == 32'h0000_7f01,
              "LD.HU zero extension result");
        check(data_mem[8'h42] == 32'h0008_00f7,
              "ST.B/ST.H byte-lane result");
        check(u_cpu.u_regfile.regs[22] == 32'h0008_00f7,
              "load after byte/half stores");
        check(u_cpu.u_regfile.regs[16] == 32'd8,
              "r0 write suppression result");
        check(u_cpu.u_regfile.regs[15] == (RESET_PC + 32'h80),
              "JIRL rd==rj source-before-destination result");
        check(u_cpu.u_regfile.regs[23] == 32'd9,
              "same-pair producer architectural result");
        check(u_cpu.u_regfile.regs[24] == 32'd17,
              "same-pair ALU-to-ALU forwarding result");
        check(data_mem[8'h43] == 32'h0000_0055,
              "same-pair ALU-to-store-data forwarding result");
        check(u_cpu.u_regfile.regs[27] == 32'h0000_0055,
              "load after same-pair forwarded store");
        check(u_cpu.u_regfile.regs[28] == 32'd93,
              "adjacent load-use forwarding result");
        check(u_cpu.u_regfile.regs[29] == 32'd101,
              "consumer-to-producer first chained result");
        check(u_cpu.u_regfile.regs[30] == 32'd109,
              "consumer-to-producer same-pair chained result");
        check(u_cpu.u_regfile.regs[9] == 32'd1,
              "same-pair ALU-to-branch producer result");
        check(u_cpu.u_regfile.regs[1] == (RESET_PC + 32'hb8),
              "BL fixed-r1 link result");
        check(u_cpu.u_regfile.regs[31] == 32'd1,
              "completion marker register");
        check((cache_store_count >= 1) && (cache_load_count >= 1),
              "cacheable load/store requests were not observed");
        check(mmio_wea == 4'b0000,
              "smoke program unexpectedly issued an MMIO store");

        $display("[PASS] LoongArch cpu_top execution smoke test (stores=%0d loads=%0d)",
                 cache_store_count, cache_load_count);
        $finish;
    end

endmodule
