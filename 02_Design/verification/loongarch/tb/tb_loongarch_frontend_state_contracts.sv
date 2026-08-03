`timescale 1ns/1ps

module tb_loongarch_frontend_state_contracts;
    import cpu_defs::*;

    localparam int FQ_DEPTH = 8;
    localparam int FQ_PTR_W = $clog2(FQ_DEPTH);

    logic clk;

    logic fq_rst_n;
    logic fq_flush;
    logic fq_enq0_payload;
    logic fq_enq1_payload;
    logic fq_enq0_valid;
    logic fq_enq1_valid;
    frontend_fq_entry_t fq_enq_entry0;
    frontend_fq_entry_t fq_enq_entry1;
    frontend_pair_meta_t fq_enq_pair_meta0;
    frontend_pair_meta_t fq_enq_pair_meta1;
    logic fq_prev_tail_contiguous;
    logic fq_deq_fire;
    logic fq_deq_two;
    logic [FQ_PTR_W-1:0] fq_head;
    logic [FQ_PTR_W-1:0] fq_head_p1;
    logic [FQ_PTR_W-1:0] fq_tail;
    logic [FQ_PTR_W-1:0] fq_tail_p1;
    logic [FQ_PTR_W:0] fq_count;
    logic [31:0] fq_tail_next_pc;
    frontend_fq_entry_t fq_head0_entry;
    frontend_fq_entry_t fq_head1_entry;
    frontend_pair_meta_t fq_head0_pair_meta;
    frontend_pair_meta_t fq_head1_pair_meta;
    logic fq_head_pair_contiguous;

    logic ifid_rst_n;
    logic if_valid;
    logic if_ready_go;
    logic id_allowin;
    logic id_valid;
    logic id_flush;
    logic if_s1_valid;
    logic id_s1_valid;
    if_id_payload_t if_payload;
    if_id_payload_t id_payload;
    logic [4:0] id_s1_rf_rs1_addr;

    frontend_fq_entry_t fq_model_entry [0:FQ_DEPTH-1];
    integer fq_model_head;
    integer fq_model_tail;
    integer fq_model_count;
    logic [31:0] fq_model_tail_next_pc;
    logic fq_model_tail_next_pc_valid;
    logic [31:0] fq_next_pc;

    if_id_payload_t ifid_model_payload;
    logic [4:0] ifid_model_rf_addr;
    logic ifid_model_payload_valid;
    logic ifid_model_valid;
    logic ifid_model_s1_valid;

    integer fq_case_count;
    integer ifid_case_count;

    frontend_fetch_queue #(
        .FQ_DEPTH(FQ_DEPTH),
        .FQ_PTR_W(FQ_PTR_W)
    ) u_fq (
        .clk                  (clk),
        .rst_n                (fq_rst_n),
        .flush                (fq_flush),
        .enq0_payload         (fq_enq0_payload),
        .enq1_payload         (fq_enq1_payload),
        .enq0_valid           (fq_enq0_valid),
        .enq1_valid           (fq_enq1_valid),
        .enq_entry0           (fq_enq_entry0),
        .enq_entry1           (fq_enq_entry1),
        .enq_pair_meta0       (fq_enq_pair_meta0),
        .enq_pair_meta1       (fq_enq_pair_meta1),
        .prev_tail_contiguous (fq_prev_tail_contiguous),
        .deq_fire             (fq_deq_fire),
        .deq_two              (fq_deq_two),
        .head                 (fq_head),
        .head_p1              (fq_head_p1),
        .tail                 (fq_tail),
        .tail_p1              (fq_tail_p1),
        .count                (fq_count),
        .tail_next_pc         (fq_tail_next_pc),
        .head0_entry          (fq_head0_entry),
        .head1_entry          (fq_head1_entry),
        .head0_pair_meta      (fq_head0_pair_meta),
        .head1_pair_meta      (fq_head1_pair_meta),
        .head_pair_contiguous (fq_head_pair_contiguous)
    );

    if_id_reg u_if_id_reg (
        .clk                (clk),
        .rst_n              (ifid_rst_n),
        .if_valid           (if_valid),
        .if_ready_go        (if_ready_go),
        .id_allowin         (id_allowin),
        .id_valid           (id_valid),
        .id_flush           (id_flush),
        .if_s1_valid        (if_s1_valid),
        .id_s1_valid        (id_s1_valid),
        .if_payload         (if_payload),
        .id_payload         (id_payload),
        .id_s1_rf_rs1_addr  (id_s1_rf_rs1_addr)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check(input logic condition, input string message);
        begin
            if (condition !== 1'b1)
                $fatal(1, "[FAIL] %s at time %0t", message, $time);
        end
    endtask

    task automatic clear_fq_controls;
        begin
            fq_flush = 1'b0;
            fq_enq0_payload = 1'b0;
            fq_enq1_payload = 1'b0;
            fq_enq0_valid = 1'b0;
            fq_enq1_valid = 1'b0;
            fq_enq_entry0 = '0;
            fq_enq_entry1 = '0;
            fq_enq_pair_meta0 = '0;
            fq_enq_pair_meta1 = '0;
            fq_prev_tail_contiguous = 1'b0;
            fq_deq_fire = 1'b0;
            fq_deq_two = 1'b0;
        end
    endtask

    task automatic reset_fq;
        begin
            @(negedge clk);
            fq_rst_n = 1'b0;
            clear_fq_controls();
            repeat (2) @(posedge clk);
            fq_model_head = 0;
            fq_model_tail = 0;
            fq_model_count = 0;
            fq_model_tail_next_pc_valid = 1'b0;
            fq_next_pc = 32'h1c00_0000;
            @(negedge clk);
            fq_rst_n = 1'b1;
            #1;
            check(fq_head == 0, "FQ reset head");
            check(fq_tail == 0, "FQ reset tail");
            check(fq_count == 0, "FQ reset count");
        end
    endtask

    task automatic check_fq_model(input string name);
        begin
            check(fq_head == FQ_PTR_W'(fq_model_head),
                  {name, ": head mismatch"});
            check(fq_tail == FQ_PTR_W'(fq_model_tail),
                  {name, ": tail mismatch"});
            check(fq_count == (FQ_PTR_W+1)'(fq_model_count),
                  {name, ": count mismatch"});
            check(fq_head_p1 == FQ_PTR_W'((fq_model_head + 1) % FQ_DEPTH),
                  {name, ": head+1 mismatch"});
            check(fq_tail_p1 == FQ_PTR_W'((fq_model_tail + 1) % FQ_DEPTH),
                  {name, ": tail+1 mismatch"});
            if (fq_model_tail_next_pc_valid)
                check(fq_tail_next_pc == fq_model_tail_next_pc,
                      {name, ": tail next-PC mismatch"});
            if (fq_model_count > 0)
                check(fq_head0_entry.pc
                      == fq_model_entry[fq_model_head].pc,
                      {name, ": head entry mismatch"});
            if (fq_model_count > 1)
                check(fq_head1_entry.pc
                      == fq_model_entry[(fq_model_head + 1) % FQ_DEPTH].pc,
                      {name, ": head+1 entry mismatch"});
        end
    endtask

    task automatic fq_step(
        input integer enq_count,
        input integer deq_count,
        input logic   idle_deq_two,
        input logic   do_flush,
        input string  name
    );
        integer old_tail;
        integer next_count;
        logic [31:0] enq_pc0;
        logic [31:0] enq_pc1;
        begin
            check((enq_count >= 0) && (enq_count <= 2),
                  {name, ": invalid enqueue count"});
            check((deq_count >= 0) && (deq_count <= 2),
                  {name, ": invalid dequeue count"});
            if (!do_flush) begin
                check(deq_count <= fq_model_count,
                      {name, ": model underflow"});
                next_count = fq_model_count - deq_count + enq_count;
                check((next_count >= 0) && (next_count <= FQ_DEPTH),
                      {name, ": model overflow"});
            end

            @(negedge clk);
            clear_fq_controls();
            fq_flush = do_flush;
            fq_enq0_payload = enq_count >= 1;
            fq_enq0_valid = enq_count >= 1;
            fq_enq1_payload = enq_count == 2;
            fq_enq1_valid = enq_count == 2;
            fq_deq_fire = deq_count != 0;
            fq_deq_two = (deq_count == 2)
                       | ((deq_count == 0) & idle_deq_two);

            enq_pc0 = fq_next_pc;
            enq_pc1 = fq_next_pc + 32'd4;
            fq_enq_entry0 = '0;
            fq_enq_entry1 = '0;
            fq_enq_entry0.pc = enq_pc0;
            fq_enq_entry1.pc = enq_pc1;
            fq_enq_pair_meta0 = '0;
            fq_enq_pair_meta1 = '0;
            fq_enq_pair_meta0.src0_addr = enq_pc0[6:2];
            fq_enq_pair_meta1.src0_addr = enq_pc1[6:2];
            fq_prev_tail_contiguous = 1'b1;

            old_tail = fq_model_tail;
            if (enq_count >= 1)
                fq_model_entry[old_tail] = fq_enq_entry0;
            if (enq_count == 2)
                fq_model_entry[(old_tail + 1) % FQ_DEPTH] = fq_enq_entry1;

            @(posedge clk);
            if (do_flush) begin
                fq_model_head = 0;
                fq_model_tail = 0;
                fq_model_count = 0;
            end else begin
                fq_model_head = (fq_model_head + deq_count) % FQ_DEPTH;
                fq_model_tail = (fq_model_tail + enq_count) % FQ_DEPTH;
                fq_model_count = next_count;
            end
            if (enq_count != 0) begin
                fq_model_tail_next_pc = (enq_count == 2)
                                      ? enq_pc1 + 32'd4
                                      : enq_pc0 + 32'd4;
                fq_model_tail_next_pc_valid = 1'b1;
                fq_next_pc = fq_next_pc + ((enq_count == 2) ? 32'd8 : 32'd4);
            end

            @(negedge clk);
            #1;
            fq_case_count = fq_case_count + 1;
            check_fq_model(name);
            clear_fq_controls();
        end
    endtask

    task automatic prefill_fq;
        begin
            fq_step(2, 0, 1'b0, 1'b0, "prefill first pair");
            fq_step(2, 0, 1'b1, 1'b0, "prefill second pair");
            check(fq_model_count == 4, "FQ prefill count");
        end
    endtask

    task automatic clear_ifid_controls;
        begin
            if_valid = 1'b0;
            if_ready_go = 1'b0;
            id_allowin = 1'b0;
            id_flush = 1'b0;
            if_s1_valid = 1'b0;
            if_payload = '0;
        end
    endtask

    task automatic reset_ifid;
        begin
            @(negedge clk);
            ifid_rst_n = 1'b0;
            clear_ifid_controls();
            repeat (2) @(posedge clk);
            ifid_model_valid = 1'b0;
            ifid_model_s1_valid = 1'b0;
            ifid_model_payload_valid = 1'b0;
            @(negedge clk);
            ifid_rst_n = 1'b1;
            #1;
            check(!id_valid && !id_s1_valid, "IF/ID reset valid bits");
        end
    endtask

    task automatic ifid_step(
        input logic       allowin,
        input logic       flush,
        input logic       input_valid,
        input logic       input_ready,
        input logic       input_s1_valid,
        input logic [4:0] slot1_rs1,
        input logic [31:0] marker,
        input string      name
    );
        begin
            @(negedge clk);
            clear_ifid_controls();
            id_allowin = allowin;
            id_flush = flush;
            if_valid = input_valid;
            if_ready_go = input_ready;
            if_s1_valid = input_s1_valid;
            if_payload.pc = marker;
            if_payload.slot0.inst = marker ^ 32'h1357_9bdf;
            if_payload.slot1.inst = marker ^ 32'h2468_ace0;
            if_payload.slot1.issue_hint.src0_addr = slot1_rs1;
            if_payload.slot1.issue_hint.src1_addr = ~slot1_rs1;

            if (allowin) begin
                ifid_model_payload = if_payload;
                ifid_model_rf_addr = slot1_rs1;
                ifid_model_payload_valid = 1'b1;
            end
            if (flush) begin
                ifid_model_valid = 1'b0;
                ifid_model_s1_valid = 1'b0;
            end else if (allowin) begin
                ifid_model_valid = input_valid & input_ready;
                ifid_model_s1_valid = input_valid & input_ready
                                    & input_s1_valid;
            end

            @(posedge clk);
            @(negedge clk);
            #1;
            ifid_case_count = ifid_case_count + 1;
            check(id_valid == ifid_model_valid,
                  {name, ": Slot0 valid mismatch"});
            check(id_s1_valid == ifid_model_s1_valid,
                  {name, ": Slot1 valid mismatch"});
            if (ifid_model_payload_valid) begin
                check(id_payload === ifid_model_payload,
                      {name, ": payload CE/hold mismatch"});
                check(id_s1_rf_rs1_addr === ifid_model_rf_addr,
                      {name, ": RF address copy CE/hold mismatch"});
                check(id_s1_rf_rs1_addr
                      === id_payload.slot1.issue_hint.src0_addr,
                      {name, ": RF address copy diverged from payload"});
            end
            clear_ifid_controls();
        end
    endtask

    initial begin
        integer enq_count;
        integer deq_count;
        integer random_deq;
        integer random_enq;
        integer remaining_capacity;
        logic idle_width;

        fq_rst_n = 1'b0;
        ifid_rst_n = 1'b0;
        fq_case_count = 0;
        ifid_case_count = 0;
        clear_fq_controls();
        clear_ifid_controls();

        // Every enqueue/dequeue amount combination starts from the same
        // four-entry state. For no-dequeue cases, exercise both values of the
        // deliberately independent width bit.
        for (deq_count = 0; deq_count <= 2; deq_count = deq_count + 1) begin
            for (enq_count = 0; enq_count <= 2; enq_count = enq_count + 1) begin
                reset_fq();
                prefill_fq();
                fq_step(enq_count, deq_count, 1'b0, 1'b0,
                        $sformatf("matrix enq=%0d deq=%0d width=0",
                                  enq_count, deq_count));
                if (deq_count == 0) begin
                    reset_fq();
                    prefill_fq();
                    fq_step(enq_count, 0, 1'b1, 1'b0,
                            $sformatf("matrix enq=%0d idle width=1",
                                      enq_count));
                end
            end
        end

        // Force pointer wrap and then flush while a dequeue request is also
        // present. Flush must own head/tail/count; stale payload remains masked.
        reset_fq();
        repeat (3)
            fq_step(2, (fq_model_count >= 2) ? 2 : 0,
                    1'b0, 1'b0, "pointer-wrap traffic");
        if (fq_model_count < 2)
            fq_step(2, 0, 1'b0, 1'b0, "flush prefill");
        fq_step(0, 2, 1'b0, 1'b1, "flush beats dequeue");

        // Random legal traffic stresses simultaneous update and wrap-around.
        reset_fq();
        for (int cycle = 0; cycle < 300; cycle++) begin
            if ((cycle != 0) && ((cycle % 73) == 0)) begin
                fq_step(0, (fq_model_count >= 2) ? 2 : fq_model_count,
                        1'b0, 1'b1, "random flush boundary");
            end else begin
                if (fq_model_count == 0)
                    random_deq = 0;
                else if (fq_model_count == 1)
                    random_deq = $urandom_range(0, 1);
                else
                    random_deq = $urandom_range(0, 2);
                remaining_capacity = FQ_DEPTH
                                   - (fq_model_count - random_deq);
                random_enq = $urandom_range(0, 2);
                if (random_enq > remaining_capacity)
                    random_enq = remaining_capacity;
                idle_width = $urandom_range(0, 1);
                fq_step(random_enq, random_deq, idle_width, 1'b0,
                        "random legal FQ traffic");
            end
        end

        reset_ifid();
        ifid_step(1'b1, 1'b0, 1'b1, 1'b1, 1'b1,
                  5'd7, 32'h1000_0001, "initial capture");
        ifid_step(1'b0, 1'b0, 1'b1, 1'b1, 1'b1,
                  5'd19, 32'h2000_0002, "stall holds payload and copy");
        ifid_step(1'b0, 1'b1, 1'b1, 1'b1, 1'b1,
                  5'd23, 32'h3000_0003, "flush clears only valid while stalled");
        ifid_step(1'b1, 1'b1, 1'b1, 1'b1, 1'b1,
                  5'd29, 32'h4000_0004, "flush with CE captures masked payload");
        ifid_step(1'b1, 1'b0, 1'b1, 1'b1, 1'b1,
                  5'd31, 32'h5000_0005, "post-flush recapture");

        for (int cycle = 0; cycle < 300; cycle++) begin
            ifid_step(
                $urandom_range(0, 1),
                ($urandom_range(0, 15) == 0),
                $urandom_range(0, 1),
                $urandom_range(0, 1),
                $urandom_range(0, 1),
                $urandom_range(0, 31),
                32'h6000_0000 + cycle,
                "random IF/ID CE/flush traffic"
            );
        end

        $display("[PASS] LoongArch frontend state contracts FQ=%0d IFID=%0d",
                 fq_case_count, ifid_case_count);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "[FAIL] frontend state contract test timeout");
    end

endmodule
