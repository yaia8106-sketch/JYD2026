`timescale 1ns/1ps

module tb_dcache_writeback;
    logic clk;
    logic rst_n;

    logic        cpu_req;
    logic        cpu_wr;
    logic [31:0] cpu_addr;
    logic [ 3:0] cpu_wea;
    logic [31:0] cpu_wdata;
    logic [ 1:0] cpu_load_size;
    logic        cpu_load_unsigned;
    logic        cpu_uncached;
    logic [31:0] cpu_rdata;
    logic [31:0] cpu_rdata_ex;
    logic        cpu_ready;
    logic        flush;

    logic        mem_req_valid;
    logic        mem_req_ready;
    logic        mem_req_write;
    logic        mem_req_writeback;
    logic [31:0] mem_req_addr;
    logic [ 7:0] mem_req_len;
    logic [ 1:0] mem_req_burst;
    logic        mem_w_valid;
    logic        mem_w_ready;
    logic [31:0] mem_w_data;
    logic [ 3:0] mem_w_strb;
    logic        mem_w_last;
    logic        mem_rd_valid;
    logic        mem_rd_ready;
    logic [31:0] mem_rd_data;
    logic        mem_rd_last;
    logic [ 1:0] mem_rd_resp;
    logic        mem_wr_valid;
    logic        mem_wr_ready;
    logic [ 1:0] mem_wr_resp;

    integer errors;
    integer write_commands;
    integer read_commands;

    wire pipeline_stall = ~cpu_ready;

    dcache dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_req(cpu_req),
        .cpu_wr(cpu_wr),
        .cpu_addr(cpu_addr),
        .cpu_lookup_addr(cpu_addr[11:2]),
        .cpu_wea(cpu_wea),
        .cpu_wdata(cpu_wdata),
        .cpu_load_size(cpu_load_size),
        .cpu_load_unsigned(cpu_load_unsigned),
        .cpu_uncached(cpu_uncached),
        .cpu_rdata(cpu_rdata),
        .cpu_rdata_ex(cpu_rdata_ex),
        .cpu_ready(cpu_ready),
        .pipeline_stall(pipeline_stall),
        .flush(flush),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_writeback(mem_req_writeback),
        .mem_req_addr(mem_req_addr),
        .mem_req_len(mem_req_len),
        .mem_req_burst(mem_req_burst),
        .mem_w_valid(mem_w_valid),
        .mem_w_ready(mem_w_ready),
        .mem_w_data(mem_w_data),
        .mem_w_strb(mem_w_strb),
        .mem_w_last(mem_w_last),
        .mem_rd_valid(mem_rd_valid),
        .mem_rd_ready(mem_rd_ready),
        .mem_rd_data(mem_rd_data),
        .mem_rd_last(mem_rd_last),
        .mem_rd_resp(mem_rd_resp),
        .mem_rd_cancel(),
        .mem_wr_valid(mem_wr_valid),
        .mem_wr_ready(mem_wr_ready),
        .mem_wr_resp(mem_wr_resp)
    );

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        begin
            if (!condition) begin
                errors = errors + 1;
                $display("[FAIL] %s at %0t", message, $time);
            end
        end
    endtask

    task automatic launch_cpu(
        input logic        write,
        input logic [31:0] addr,
        input logic [ 3:0] wea,
        input logic [31:0] data
    );
        begin
            @(negedge clk);
            cpu_wr = write;
            cpu_addr = addr;
            cpu_wea = wea;
            cpu_wdata = data;
            cpu_uncached = 1'b0;
            cpu_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cpu_req = 1'b0;
        end
    endtask

    task automatic store_then_load_no_stall(
        input logic [31:0] store_addr,
        input logic [ 3:0] store_wea,
        input logic [31:0] store_data,
        input logic [31:0] load_addr,
        input logic [31:0] expected,
        input logic        expected_bypass
    );
        begin
            // Cycle N EX: present the store.
            @(negedge clk);
            cpu_wr = 1'b1;
            cpu_addr = store_addr;
            cpu_wea = store_wea;
            cpu_wdata = store_data;
            cpu_uncached = 1'b0;
            cpu_req = 1'b1;
            @(posedge clk);

            // Cycle N+1: store is in MEM while the dependent load is in EX.
            // The store must retire and the collision decision is registered
            // at the following edge.
            @(negedge clk);
            #1;
            check(dut.mem_req && cpu_ready,
                  "store before dependent load did not retire");
            check(!mem_req_valid,
                  "store hit before dependent load emitted an AXI request");
            cpu_wr = 1'b0;
            cpu_addr = load_addr;
            cpu_wea = 4'b0000;
            cpu_wdata = 32'd0;
            cpu_req = 1'b1;
            @(posedge clk);

            // Cycle N+2: a same-word READ_FIRST collision needs the registered
            // payload; a different-tag access must leave the bypass invalid.
            @(negedge clk);
            #1;
            check(dut.mem_req && cpu_ready,
                  "dependent load stalled behind a store hit");
            check(dut.raw_bypass_valid == expected_bypass,
                  "BRAM RAW collision bypass validity mismatch");
            check(cpu_rdata == expected,
                  "load after store observed the wrong cache data");
            check(!mem_req_valid,
                  "dependent load hit emitted an AXI request");
            cpu_req = 1'b0;
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic wait_idle;
        begin
            while (!(dut.state_idle && !dut.mem_req))
                @(negedge clk);
        end
    endtask

    task automatic accept_command(
        input logic        expected_write,
        input logic [31:0] expected_addr,
        input logic [ 7:0] expected_len
    );
        begin
            while (!mem_req_valid)
                @(negedge clk);
            check(mem_req_write == expected_write,
                  "backend command direction mismatch");
            check(mem_req_writeback == expected_write,
                  "backend writeback command attribute mismatch");
            check(mem_req_addr == expected_addr,
                  $sformatf("backend command address mismatch: got=%08x expected=%08x",
                            mem_req_addr, expected_addr));
            check(mem_req_len == expected_len,
                  "backend command burst length mismatch");
            check(mem_req_burst == (expected_write ? 2'b01 : 2'b10),
                  "backend command burst type mismatch");
            if (expected_write)
                write_commands = write_commands + 1;
            else
                read_commands = read_commands + 1;
            mem_req_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mem_req_ready = 1'b0;
        end
    endtask

    task automatic send_read_beat(
        input logic [31:0] data,
        input logic        last
    );
        begin
            while (!mem_rd_ready)
                @(negedge clk);
            mem_rd_data = data;
            mem_rd_last = last;
            mem_rd_resp = 2'b00;
            mem_rd_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mem_rd_valid = 1'b0;
            mem_rd_last = 1'b0;
        end
    endtask

    task automatic send_read_line(
        input logic [ 2:0] start_word,
        input logic [31:0] word0,
        input logic [31:0] word1,
        input logic [31:0] word2,
        input logic [31:0] word3,
        input logic [31:0] word4,
        input logic [31:0] word5,
        input logic [31:0] word6,
        input logic [31:0] word7
    );
        logic [2:0] word_index;
        begin
            for (int beat = 0; beat < 8; beat++) begin
                word_index = start_word + beat;
                case (word_index)
                    3'd0: send_read_beat(word0, beat == 7);
                    3'd1: send_read_beat(word1, beat == 7);
                    3'd2: send_read_beat(word2, beat == 7);
                    3'd3: send_read_beat(word3, beat == 7);
                    3'd4: send_read_beat(word4, beat == 7);
                    3'd5: send_read_beat(word5, beat == 7);
                    3'd6: send_read_beat(word6, beat == 7);
                    default: send_read_beat(word7, beat == 7);
                endcase
            end
        end
    endtask

    task automatic receive_write_line(
        input logic [31:0] word0,
        input logic [31:0] word1,
        input logic [31:0] word2,
        input logic [31:0] word3,
        input logic [31:0] word4,
        input logic [31:0] word5,
        input logic [31:0] word6,
        input logic [31:0] word7
    );
        logic [31:0] expected;
        begin
            for (int beat = 0; beat < 8; beat++) begin
                case (beat)
                    0: expected = word0;
                    1: expected = word1;
                    2: expected = word2;
                    3: expected = word3;
                    4: expected = word4;
                    5: expected = word5;
                    6: expected = word6;
                    default: expected = word7;
                endcase

                while (!mem_w_valid)
                    @(negedge clk);

                // Backpressure alternating beats and require the selected
                // local word to remain stable throughout the stall.
                if (beat[0]) begin
                    check(mem_w_data == expected,
                          "writeback data changed before ready");
                    @(posedge clk);
                    @(negedge clk);
                    check(mem_w_valid && (mem_w_data == expected),
                          "writeback beat was not held under backpressure");
                end

                check(mem_w_strb == 4'b1111,
                      "writeback beat did not enable all byte lanes");
                check(mem_w_last == (beat == 7),
                      "writeback LAST position mismatch");
                check(mem_w_data == expected,
                      "writeback data payload mismatch");
                mem_w_ready = 1'b1;
                @(posedge clk);
                @(negedge clk);
                mem_w_ready = 1'b0;
            end
        end
    endtask

    task automatic return_write_response(input logic [1:0] response);
        begin
            while (!mem_wr_ready)
                @(negedge clk);
            mem_wr_resp = response;
            mem_wr_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mem_wr_valid = 1'b0;
        end
    endtask

    task automatic load_miss(
        input logic [31:0] addr,
        input logic [31:0] word0,
        input logic [31:0] word1,
        input logic [31:0] word2,
        input logic [31:0] word3,
        input logic [31:0] word4,
        input logic [31:0] word5,
        input logic [31:0] word6,
        input logic [31:0] word7,
        output logic [31:0] result
    );
        logic request_seen;
        begin
            request_seen = 1'b0;
            fork
                begin
                    launch_cpu(1'b0, addr, 4'b0000, 32'd0);
                    #1;
                    while (!(dut.mem_req && !cpu_ready)) begin
                        @(negedge clk);
                        #1;
                    end
                    request_seen = 1'b1;
                    while (!(dut.mem_req && cpu_ready)) begin
                        @(negedge clk);
                        #1;
                    end
                    result = cpu_rdata;
                    @(posedge clk);
                end
                begin
                    accept_command(
                        1'b0, {addr[31:2], 2'b00}, 8'd7
                    );
                    send_read_line(
                        addr[4:2], word0, word1, word2, word3,
                        word4, word5, word6, word7
                    );
                end
            join
            check(request_seen, "load miss never backpressured the CPU");
            wait_idle();
        end
    endtask

    task automatic load_dirty_miss(
        input logic [31:0] addr,
        input logic [31:0] victim_addr,
        input logic [31:0] victim0,
        input logic [31:0] victim1,
        input logic [31:0] victim2,
        input logic [31:0] victim3,
        input logic [31:0] victim4,
        input logic [31:0] victim5,
        input logic [31:0] victim6,
        input logic [31:0] victim7,
        input logic [31:0] refill0,
        input logic [31:0] refill1,
        input logic [31:0] refill2,
        input logic [31:0] refill3,
        input logic [31:0] refill4,
        input logic [31:0] refill5,
        input logic [31:0] refill6,
        input logic [31:0] refill7,
        input logic        response_before_refill,
        input logic        retry_once,
        output logic [31:0] result
    );
        begin
            fork
                begin
                    launch_cpu(1'b0, addr, 4'b0000, 32'd0);
                    while (!(dut.mem_req && cpu_ready)) begin
                        // A delayed B response may make cpu_ready true only
                        // for the consuming clock edge; sample that architectural
                        // handshake directly instead of one half-cycle later.
                        @(posedge clk);
                    end
                    result = cpu_rdata;
                    @(posedge clk);
                end
                begin
                    accept_command(1'b1, victim_addr, 8'd7);
                    if (response_before_refill) begin
                        receive_write_line(
                            victim0, victim1, victim2, victim3,
                            victim4, victim5, victim6, victim7
                        );
                        return_write_response(2'b00);
                        accept_command(
                            1'b0, {addr[31:2], 2'b00}, 8'd7
                        );
                        send_read_line(
                            addr[4:2], refill0, refill1, refill2, refill3,
                            refill4, refill5, refill6, refill7
                        );
                    end else begin
                        // The refill command and all R beats are allowed while
                        // the old line is still being written.  The W checker
                        // also proves that refill traffic never overwrites the
                        // dedicated victim buffer.
                        fork
                            receive_write_line(
                                victim0, victim1, victim2, victim3,
                                victim4, victim5, victim6, victim7
                            );
                            begin
                                accept_command(
                                    1'b0, {addr[31:2], 2'b00}, 8'd7
                                );
                                send_read_line(
                                    addr[4:2], refill0, refill1,
                                    refill2, refill3, refill4,
                                    refill5, refill6, refill7
                                );
                            end
                        join
                        #1;
                        check(!cpu_ready,
                              "dirty load miss retired before B success");

                        if (retry_once) begin
                            return_write_response(2'b10);
                            accept_command(1'b1, victim_addr, 8'd7);
                            receive_write_line(
                                victim0, victim1, victim2, victim3,
                                victim4, victim5, victim6, victim7
                            );
                        end
                        return_write_response(2'b00);
                    end
                end
            join
            wait_idle();
        end
    endtask

    task automatic load_hit(
        input logic [31:0] addr,
        input logic [31:0] expected
    );
        begin
            launch_cpu(1'b0, addr, 4'b0000, 32'd0);
            #1;
            check(dut.mem_req && cpu_ready,
                  "expected load hit did not complete immediately");
            check(cpu_rdata == expected, "load hit data mismatch");
            check(!mem_req_valid, "load hit emitted a backend command");
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic load_hit_formatted(
        input logic [31:0] addr,
        input logic [ 1:0] size,
        input logic        load_unsigned,
        input logic [31:0] expected
    );
        begin
            cpu_load_size = size;
            cpu_load_unsigned = load_unsigned;
            load_hit(addr, expected);
            cpu_load_size = 2'b10;
            cpu_load_unsigned = 1'b0;
        end
    endtask

    task automatic store_then_load_formatted_no_stall(
        input logic [31:0] store_addr,
        input logic [ 3:0] store_wea,
        input logic [31:0] store_data,
        input logic [31:0] load_addr,
        input logic [ 1:0] load_size,
        input logic        load_unsigned,
        input logic [31:0] expected
    );
        begin
            cpu_load_size = load_size;
            cpu_load_unsigned = load_unsigned;
            store_then_load_no_stall(
                store_addr, store_wea, store_data,
                load_addr, expected, 1'b1
            );
            cpu_load_size = 2'b10;
            cpu_load_unsigned = 1'b0;
        end
    endtask

    task automatic store_hit(
        input logic [31:0] addr,
        input logic [ 3:0] wea,
        input logic [31:0] data
    );
        begin
            launch_cpu(1'b1, addr, wea, data);
            #1;
            check(dut.mem_req && cpu_ready,
                  "store hit did not retire immediately");
            check(!mem_req_valid,
                  "write-back store hit emitted a backend command");
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic store_miss_with_following_load(
        input logic [31:0] store_addr,
        input logic [ 3:0] store_wea,
        input logic [31:0] store_data,
        input logic [31:0] store_word0,
        input logic [31:0] store_word1,
        input logic [31:0] store_word2,
        input logic [31:0] store_word3,
        input logic [31:0] store_word4,
        input logic [31:0] store_word5,
        input logic [31:0] store_word6,
        input logic [31:0] store_word7,
        input logic [31:0] load_addr,
        input logic [31:0] load_word0,
        input logic [31:0] load_word1,
        input logic [31:0] load_word2,
        input logic [31:0] load_word3,
        input logic [31:0] load_word4,
        input logic [31:0] load_word5,
        input logic [31:0] load_word6,
        input logic [31:0] load_word7,
        output logic [31:0] load_result
    );
        begin
            fork
                begin
                    launch_cpu(
                        1'b1, store_addr, store_wea, store_data
                    );
                    #1;
                    check(dut.mem_req && cpu_ready,
                          "store miss was not captured for early retirement");
                    @(posedge clk);

                    // Model the immediately following pipeline memory request.
                    // It is captured while refill runs, then replayed after the
                    // miss-only BRAM victim/refill accesses finish.
                    launch_cpu(1'b0, load_addr, 4'b0000, 32'd0);
                    #1;
                    while (!(dut.mem_req && !cpu_ready)) begin
                        @(negedge clk);
                        #1;
                    end
                    while (!(dut.mem_req && cpu_ready)) begin
                        @(negedge clk);
                        #1;
                    end
                    load_result = cpu_rdata;
                    @(posedge clk);
                end
                begin
                    accept_command(
                        1'b0, {store_addr[31:2], 2'b00}, 8'd7
                    );
                    send_read_line(
                        store_addr[4:2],
                        store_word0, store_word1,
                        store_word2, store_word3,
                        store_word4, store_word5,
                        store_word6, store_word7
                    );
                    accept_command(
                        1'b0, {load_addr[31:2], 2'b00}, 8'd7
                    );
                    send_read_line(
                        load_addr[4:2],
                        load_word0, load_word1,
                        load_word2, load_word3,
                        load_word4, load_word5,
                        load_word6, load_word7
                    );
                end
            join
            wait_idle();
        end
    endtask

    task automatic committed_store_survives_flush(
        input logic [31:0] addr,
        input logic [31:0] word0,
        input logic [31:0] word1,
        input logic [31:0] word2,
        input logic [31:0] word3,
        input logic [31:0] word4,
        input logic [31:0] word5,
        input logic [31:0] word6,
        input logic [31:0] word7
    );
        begin
            fork
                begin
                    launch_cpu(1'b1, addr, 4'b1111, 32'hcafe_babe);
                    #1;
                    check(dut.mem_req && cpu_ready,
                          "committed store miss did not retire");
                    @(posedge clk);
                end
                begin
                    accept_command(
                        1'b0, {addr[31:2], 2'b00}, 8'd7
                    );
                    fork
                        send_read_line(
                            addr[4:2], word0, word1, word2, word3,
                            word4, word5, word6, word7
                        );
                        begin
                            while (!dut.state_refill_data)
                                @(negedge clk);
                            @(posedge clk);
                            @(negedge clk);
                            flush = 1'b1;
                            @(posedge clk);
                            @(negedge clk);
                            flush = 1'b0;
                        end
                    join
                end
            join
            wait_idle();
        end
    endtask

    logic [31:0] result;
    integer writes_before;

    localparam logic [31:0] A = 32'h1c08_0040;
    // A/B/C and S/T/U use the same set in the 128-set cache. One way holds
    // 4KB, so identical set indices are 0x1000 bytes apart. A_INDEX_HI differs
    // only in index bit addr[11] and must coexist with all three same-set lines.
    localparam logic [31:0] A_INDEX_HI = 32'h1c08_0840;
    localparam logic [31:0] B = 32'h1c08_1040;
    localparam logic [31:0] C = 32'h1c08_2040;
    localparam logic [31:0] S = 32'h1c08_0060;
    localparam logic [31:0] T = 32'h1c08_1060;
    localparam logic [31:0] U = 32'h1c08_2060;
    localparam logic [31:0] V = 32'h1c08_0080;
    localparam logic [31:0] CACHE_LOWER = 32'h1c08_0000;
    localparam logic [31:0] CACHE_UPPER = 32'h1c0f_ffe0;
    localparam logic [31:0] CACHE_UPPER_PEER = 32'h1c08_0fe0;
    localparam logic [31:0] CACHE_UPPER_REPL = 32'h1c08_1fe0;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cpu_req = 1'b0;
        cpu_wr = 1'b0;
        cpu_addr = 32'd0;
        cpu_wea = 4'd0;
        cpu_wdata = 32'd0;
        cpu_load_size = 2'b10;
        cpu_load_unsigned = 1'b0;
        cpu_uncached = 1'b0;
        flush = 1'b0;
        mem_req_ready = 1'b0;
        mem_w_ready = 1'b0;
        mem_rd_valid = 1'b0;
        mem_rd_data = 32'd0;
        mem_rd_last = 1'b0;
        mem_rd_resp = 2'b00;
        mem_wr_valid = 1'b0;
        mem_wr_resp = 2'b00;
        errors = 0;
        write_commands = 0;
        read_commands = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("[INFO] fill A, dirty it with a partial store, retain locally");
        cpu_load_size = 2'b01;
        cpu_load_unsigned = 1'b0;
        load_miss(
            A + 10,
            32'h1111_0000, 32'h2222_0001,
            32'h3333_4444, 32'h4444_0003,
            32'h5555_0004, 32'h6666_0005,
            32'h7777_0006, 32'h8888_0007,
            result
        );
        check(result == 32'h0000_3333,
              "initial A refill halfword formatting mismatch");
        cpu_load_size = 2'b10;
        cpu_load_unsigned = 1'b0;
        writes_before = write_commands;
        store_then_load_no_stall(
            A + 9, 4'b0010, 32'h0000_00aa,
            A + 8, 32'h3333_aa44, 1'b1
        );
        check(write_commands == writes_before,
              "store hit reached memory before eviction");
        load_hit_formatted(A + 9, 2'b00, 1'b0, 32'hffff_ffaa);
        load_hit_formatted(A + 9, 2'b00, 1'b1, 32'h0000_00aa);
        load_hit_formatted(A + 10, 2'b01, 1'b1, 32'h0000_3333);

        $display("[INFO] addr[11] selects an independent 4KB way half");
        load_miss(
            A_INDEX_HI,
            32'h5800_0000, 32'h5800_0001,
            32'h5800_0002, 32'h5800_0003,
            32'h5800_0004, 32'h5800_0005,
            32'h5800_0006, 32'h5800_0007,
            result
        );
        check(result == 32'h5800_0000,
              "upper-index-half refill result mismatch");
        load_hit(A + 8, 32'h3333_aa44);

        $display("[INFO] use invalid way for B, then dirty B");
        load_miss(
            B,
            32'haaaa_0000, 32'hbbbb_0001,
            32'hcccc_0002, 32'hdddd_0003,
            32'heeee_0004, 32'hffff_0005,
            32'habcd_0006, 32'hdcba_0007,
            result
        );
        check(result == 32'haaaa_0000, "B refill result mismatch");
        // A and B share the same set and word offset but have different tags.
        // The younger B load must use its BRAM result, not A's store payload.
        store_then_load_no_stall(
            A, 4'b0001, 32'h0000_0000,
            B, 32'haaaa_0000, 1'b0
        );
        store_hit(B + 4, 4'b1111, 32'hdead_beef);

        $display("[INFO] exhaustive hit formatting across all byte offsets");
        load_hit_formatted(B + 4, 2'b00, 1'b0, 32'hffff_ffef);
        load_hit_formatted(B + 5, 2'b00, 1'b0, 32'hffff_ffbe);
        load_hit_formatted(B + 6, 2'b00, 1'b0, 32'hffff_ffad);
        load_hit_formatted(B + 7, 2'b00, 1'b0, 32'hffff_ffde);
        load_hit_formatted(B + 4, 2'b00, 1'b1, 32'h0000_00ef);
        load_hit_formatted(B + 5, 2'b00, 1'b1, 32'h0000_00be);
        load_hit_formatted(B + 6, 2'b00, 1'b1, 32'h0000_00ad);
        load_hit_formatted(B + 7, 2'b00, 1'b1, 32'h0000_00de);

        load_hit_formatted(B + 4, 2'b01, 1'b0, 32'hffff_beef);
        load_hit_formatted(B + 5, 2'b01, 1'b0, 32'hffff_adbe);
        load_hit_formatted(B + 6, 2'b01, 1'b0, 32'hffff_dead);
        load_hit_formatted(B + 7, 2'b01, 1'b0, 32'h0000_00de);
        load_hit_formatted(B + 4, 2'b01, 1'b1, 32'h0000_beef);
        load_hit_formatted(B + 5, 2'b01, 1'b1, 32'h0000_adbe);
        load_hit_formatted(B + 6, 2'b01, 1'b1, 32'h0000_dead);
        load_hit_formatted(B + 7, 2'b01, 1'b1, 32'h0000_00de);

        load_hit_formatted(B + 4, 2'b10, 1'b0, 32'hdead_beef);
        load_hit_formatted(B + 5, 2'b10, 1'b0, 32'h00de_adbe);
        load_hit_formatted(B + 6, 2'b10, 1'b0, 32'h0000_dead);
        load_hit_formatted(B + 7, 2'b10, 1'b0, 32'h0000_00de);
        load_hit_formatted(B + 4, 2'b11, 1'b0, 32'h0000_0000);

        $display("[INFO] formatted load consumes registered BRAM RAW bypass");
        store_then_load_formatted_no_stall(
            B + 7, 4'b1000, 32'h0000_0080,
            B + 7, 2'b00, 1'b0, 32'hffff_ff80
        );
        store_then_load_formatted_no_stall(
            B + 6, 4'b1100, 32'h0000_8001,
            B + 6, 2'b01, 1'b0, 32'hffff_8001
        );

        $display("[INFO] C evicts dirty A as one eight-beat write burst");
        load_dirty_miss(
            C, A,
            32'h1111_0000, 32'h2222_0001,
            32'h3333_aa44, 32'h4444_0003,
            32'h5555_0004, 32'h6666_0005,
            32'h7777_0006, 32'h8888_0007,
            32'hc000_0000, 32'hc000_0001,
            32'hc000_0002, 32'hc000_0003,
            32'hc000_0004, 32'hc000_0005,
            32'hc000_0006, 32'hc000_0007,
            1'b0, 1'b0,
            result
        );
        check(result == 32'hc000_0000, "C refill result mismatch");
        load_hit(A_INDEX_HI, 32'h5800_0000);

        $display("[INFO] store miss allocates and merges only selected bytes");
        writes_before = write_commands;
        store_miss_with_following_load(
            S + 5, 4'b0010, 32'h0000_005a,
            32'h0102_0304, 32'h1122_3344,
            32'h5566_7788, 32'h99aa_bbcc,
            32'h0a0b_0c0d, 32'h1a1b_1c1d,
            32'h2a2b_2c2d, 32'h3a3b_3c3d,
            T,
            32'h7000_0000, 32'h7000_0001,
            32'h7000_0002, 32'h7000_0003,
            32'h7000_0004, 32'h7000_0005,
            32'h7000_0006, 32'h7000_0007,
            result
        );
        check(write_commands == writes_before,
              "write-allocate store miss wrote memory before eviction");
        check(result == 32'h7000_0000,
              "request held behind store allocation returned wrong data");
        load_hit(S + 4, 32'h1122_5a44);

        $display("[INFO] dirty line allocated by a store is written back");
        // Make S the LRU victim again after checking its merged store data.
        load_hit(T, 32'h7000_0000);
        load_dirty_miss(
            U, S,
            32'h0102_0304, 32'h1122_5a44,
            32'h5566_7788, 32'h99aa_bbcc,
            32'h0a0b_0c0d, 32'h1a1b_1c1d,
            32'h2a2b_2c2d, 32'h3a3b_3c3d,
            32'he000_0000, 32'he000_0001,
            32'he000_0002, 32'he000_0003,
            32'he000_0004, 32'he000_0005,
            32'he000_0006, 32'he000_0007,
            1'b1, 1'b0,
            result
        );
        check(result == 32'he000_0000, "U refill result mismatch");

        $display("[INFO] pipeline flush cannot cancel an acknowledged store");
        committed_store_survives_flush(
            V + 28,
            32'h8100_0000, 32'h8100_0001,
            32'h8100_0002, 32'h8100_0003,
            32'h8100_0004, 32'h8100_0005,
            32'h8100_0006, 32'h8100_0007
        );
        load_hit(V + 28, 32'hcafe_babe);

        $display("[INFO] shortened tag covers the exact lower cache window");
        load_miss(
            CACHE_LOWER,
            32'h1000_0000, 32'h1000_0001,
            32'h1000_0002, 32'h1000_0003,
            32'h1000_0004, 32'h1000_0005,
            32'h1000_0006, 32'h1000_0007,
            result
        );
        check(result == 32'h1000_0000,
              "lower cache-window boundary refill mismatch");
        load_hit(CACHE_LOWER + 28, 32'h1000_0007);

        $display("[INFO] upper-bound dirty tag reconstructs full AXI address");
        load_miss(
            CACHE_UPPER,
            32'hf000_0000, 32'hf000_0001,
            32'hf000_0002, 32'hf000_0003,
            32'hf000_0004, 32'hf000_0005,
            32'hf000_0006, 32'hf000_0007,
            result
        );
        check(result == 32'hf000_0000,
              "upper cache-window boundary refill mismatch");
        store_hit(CACHE_UPPER + 12, 4'b1111, 32'hface_cafe);
        load_miss(
            CACHE_UPPER_PEER,
            32'h2000_0000, 32'h2000_0001,
            32'h2000_0002, 32'h2000_0003,
            32'h2000_0004, 32'h2000_0005,
            32'h2000_0006, 32'h2000_0007,
            result
        );
        load_dirty_miss(
            CACHE_UPPER_REPL, CACHE_UPPER,
            32'hf000_0000, 32'hf000_0001,
            32'hf000_0002, 32'hface_cafe,
            32'hf000_0004, 32'hf000_0005,
            32'hf000_0006, 32'hf000_0007,
            32'h3000_0000, 32'h3000_0001,
            32'h3000_0002, 32'h3000_0003,
            32'h3000_0004, 32'h3000_0005,
            32'h3000_0006, 32'h3000_0007,
            1'b0, 1'b1,
            result
        );
        check(result == 32'h3000_0000,
              "upper-bound replacement refill mismatch");

        check(write_commands == 4,
              "unexpected number of dirty writeback commands");
        check(read_commands == 12,
              "unexpected number of cache-line refill commands");

        repeat (3) @(posedge clk);
        if (errors == 0) begin
            $display("[PASS] NSCSCC DCache WB+WA directed test");
            $finish;
        end else begin
            $fatal(1, "[FAIL] NSCSCC DCache WB+WA errors=%0d", errors);
        end
    end

    initial begin
        #30000;
        $display("[DEBUG] state=%0d wb_state=%0d req=%b/%b/%b w=%b/%b last=%b r=%b/%b/%b b=%b/%b pending=%b wb_required=%b wb_done=%b",
                 dut.state, dut.wb_state,
                 mem_req_valid, mem_req_write, mem_req_ready,
                 mem_w_valid, mem_w_ready, mem_w_last,
                 mem_rd_valid, mem_rd_ready, mem_rd_last,
                 mem_wr_valid, mem_wr_ready,
                 dut.refill_cpu_pending, dut.wb_required, dut.wb_done);
        $fatal(1, "[FAIL] DCache WB+WA test timeout");
    end

endmodule
