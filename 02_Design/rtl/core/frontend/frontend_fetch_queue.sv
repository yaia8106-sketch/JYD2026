// ============================================================
// Module: frontend_fetch_queue
// Description:
// Domain: frontend.
// 指令是否能被配对的信息会在模块外进行计算，这个模块是用来实现“队列”的
// Pair metadata is stored with each entry. Only PC continuity is recorded at
// enqueue time; the complete pairing policy is evaluated from registered
// queue-head metadata.
// ============================================================

module frontend_fetch_queue
    import cpu_defs::*;
#(
    parameter int FQ_DEPTH = 8,
    parameter int FQ_PTR_W = $clog2(FQ_DEPTH)
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       flush, // redirect信号，由于当前没有二级预测，因此flush会对fq内的所有指令进行冲刷

    input  logic                       enq0_payload, // enq0_payload = accept_base(本质是个valid信号) && base_mask[0](看取指块的这条指令能不能用，比如当取指的PC[2]=1的时候enq1就不为valid)，和enq0_valid本质是一个信号
    input  logic                       enq1_payload,
    input  logic                       enq0_valid,
    input  logic                       enq1_valid,
    input  frontend_fq_entry_t         enq_entry0, // 这个结构体包含了fq entry需要的所有信息。
    input  frontend_fq_entry_t         enq_entry1,
    input  frontend_pair_meta_t        enq_pair_meta0, // 预译码信息。
    input  frontend_pair_meta_t        enq_pair_meta1,
    // Whether the old tail and this packet's first entry are consecutive.
    // Same-packet entries are consecutive by construction.
    input  logic                       prev_tail_contiguous,

    // Keep the late acceptance event separate from the already-known packet
    // width. deq_two selects the early one-entry/two-entry next-state
    // candidates; deq_fire is only the final select between those candidates.
    input  logic                       deq_fire,
    input  logic                       deq_two,

    output logic [FQ_PTR_W-1:0]        head,
    output logic [FQ_PTR_W-1:0]        head_p1, // head plus 1
    output logic [FQ_PTR_W-1:0]        tail,
    output logic [FQ_PTR_W-1:0]        tail_p1,
    // Keep the late dequeue decision on the count D cone. Without this local
    // attribute Vivado recognizes the self-hold arm below and recreates the
    // original backend-to-CE path during synthesis.
    (* extract_enable = "no" *)
    output logic [FQ_PTR_W:0]          count,
    output logic [31:0]                tail_next_pc,

    output frontend_fq_entry_t         head0_entry,
    output frontend_fq_entry_t         head1_entry,
    output frontend_pair_meta_t        head0_pair_meta,
    output frontend_pair_meta_t        head1_pair_meta,
    output logic                       head_pair_contiguous
);

    // Circular queue storage. pair_contiguous_mem[i] describes only whether
    // entry i and entry i+1 are consecutive in the instruction stream. It is
    // deliberately independent of instruction bits and pairing policy.
    frontend_fq_entry_t entry_mem [0:FQ_DEPTH-1];
    frontend_pair_meta_t pair_meta_mem [0:FQ_DEPTH-1];
    logic pair_contiguous_mem [0:FQ_DEPTH-1];

    wire [FQ_PTR_W-1:0] head_p2 =
        head + {{(FQ_PTR_W-2){1'b0}}, 2'd2};
    wire [FQ_PTR_W-1:0] tail_p2 =
        tail + {{(FQ_PTR_W-2){1'b0}}, 2'd2};
    wire [FQ_PTR_W-1:0] tail_m1 =
        tail - {{(FQ_PTR_W-1){1'b0}}, 1'b1};

    assign head_p1 = head + {{(FQ_PTR_W-1){1'b0}}, 1'b1};
    assign tail_p1 = tail + {{(FQ_PTR_W-1){1'b0}}, 1'b1};

    assign head0_entry = entry_mem[head];
    assign head1_entry = entry_mem[head_p1];
    assign head0_pair_meta = pair_meta_mem[head];
    assign head1_pair_meta = pair_meta_mem[head_p1];
    assign head_pair_contiguous = pair_contiguous_mem[head];

    wire enq_two = enq1_valid;
    wire enq_one = enq0_valid && !enq1_valid;
    wire enq_none = !enq0_valid;
    wire enq_fire = enq0_valid;

    // Head/tail/count are computed independently so enqueue and dequeue can
    // occur in the same cycle.
    wire deq_none = ~deq_fire;

    wire [FQ_PTR_W:0] count_p2 =
        count + {{(FQ_PTR_W-1){1'b0}}, 2'd2};
    wire [FQ_PTR_W:0] count_p1 =
        count + {{FQ_PTR_W{1'b0}}, 1'b1};
    wire [FQ_PTR_W:0] count_m1 =
        count - {{FQ_PTR_W{1'b0}}, 1'b1};
    wire [FQ_PTR_W:0] count_m2 =
        count - {{(FQ_PTR_W-1){1'b0}}, 2'd2};

    // Enqueue-dependent candidates are built in parallel.  The late dequeue
    // decision then selects only once, keeping backend id_allowin out of the
    // old inc/dec predicate tree.
    wire [FQ_PTR_W:0] count_if_deq_none =
        ({(FQ_PTR_W+1){enq_two}}  & count_p2) |
        ({(FQ_PTR_W+1){enq_one}}  & count_p1) |
        ({(FQ_PTR_W+1){enq_none}} & count);
    wire [FQ_PTR_W:0] count_if_deq_single =
        ({(FQ_PTR_W+1){enq_two}}  & count_p1) |
        ({(FQ_PTR_W+1){enq_one}}  & count) |
        ({(FQ_PTR_W+1){enq_none}} & count_m1);
    wire [FQ_PTR_W:0] count_if_deq_dual =
        ({(FQ_PTR_W+1){enq_two}}  & count) |
        ({(FQ_PTR_W+1){enq_one}}  & count_m1) |
        ({(FQ_PTR_W+1){enq_none}} & count_m2);

    // Packet width is known from the registered queue head before backend
    // acceptance arrives. Select that candidate first, then let the late fire
    // bit choose only between dequeue and no-dequeue results.
    wire [FQ_PTR_W:0] count_if_deq =
        deq_two ? count_if_deq_dual : count_if_deq_single;
    // Complete the hold case in the D input instead of using the late
    // backend-derived dequeue event as the count register's clock enable.
    // The explicit enq_fire arm also preserves the old hold behavior for an
    // invalid enq1-without-enq0 input combination; legal packets are still
    // exactly zero, one or two entries wide.
    wire [FQ_PTR_W:0] count_next =
        deq_fire ? count_if_deq
      : enq_fire ? count_if_deq_none
                 : count;

    wire [31:0] enq_last_next_pc =
        enq_two ? (enq_entry1.pc + 32'd4) : (enq_entry0.pc + 32'd4);
    // Only these pointers/counters define which queue entries are valid.
    // Payload storage is intentionally left unreset: stale words cannot be
    // observed while count is zero, and every newly allocated slot is written
    // before count exposes it.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head <= '0;
        end else if (flush) begin
            head <= '0;
        end else if (deq_fire)
            // Backend acceptance reaches only CE.  Once enabled, the data
            // input depends solely on the early one-entry/two-entry choice.
            head <= deq_two ? head_p2 : head_p1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            tail <= '0;
        else if (flush)
            tail <= '0;
        else if (enq_fire)
            tail <= enq_two ? tail_p2 : tail_p1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            count <= '0;
        else if (flush)
            count <= '0;
        else
            count <= count_next;
    end

    // count==0 masks this continuity payload after reset/flush.  The next
    // accepted packet overwrites it before it is observed.
    always_ff @(posedge clk) begin
        if (enq_fire)
            tail_next_pc <= enq_last_next_pc;
    end

    // Decode boundary-bit write addresses into per-entry enables. A packet's
    // first entry is marked contiguous unconditionally: when no valid slot 1
    // follows it, count prevents pairing and the next packet overwrites this
    // bit with the real cross-packet continuity result. Consequently no IROM
    // instruction bit reaches this storage D input.
    generate
        for (genvar pair_idx = 0; pair_idx < FQ_DEPTH; pair_idx++) begin : g_pair_contiguous_write
            localparam logic [FQ_PTR_W-1:0] PAIR_INDEX = pair_idx;
            wire pair_write_current = enq0_payload & (tail == PAIR_INDEX);
            wire pair_write_previous = enq0_payload & (count != 0)
                                     & (tail_m1 == PAIR_INDEX);
            wire pair_write_enable = pair_write_current
                                   | pair_write_previous;
            wire pair_write_data = pair_write_current
                                 ? 1'b1
                                 : prev_tail_contiguous;

            always_ff @(posedge clk) begin
                if (pair_write_enable)
                    pair_contiguous_mem[pair_idx] <= pair_write_data;
            end
        end
    endgenerate

    // Keep payload arrays off the reset/flush fanout. The boundary bit belonging
    // to packet slot 1 is not initialized: it is ignored while that entry has
    // no successor, then overwritten through the per-entry block above when
    // the next packet arrives.
    always_ff @(posedge clk) begin
        // A speculative reset/flush-coincident write is harmless until count
        // exposes it; a later allocation overwrites the selected slot.
        if (enq0_payload) begin
            entry_mem[tail] <= enq_entry0;
            pair_meta_mem[tail] <= enq_pair_meta0;
        end
        if (enq1_payload) begin
            entry_mem[tail_p1] <= enq_entry1;
            pair_meta_mem[tail_p1] <= enq_pair_meta1;
        end
    end

endmodule
