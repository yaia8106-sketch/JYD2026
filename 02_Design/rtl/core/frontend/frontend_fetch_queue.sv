// ============================================================
// Module: frontend_fetch_queue
// Description:
// Domain: frontend.
// 指令是否能被配对的信息会在模块外进行计算，这个模块是用来实现“队列”的
// Pair eligibility is computed outside this module and stored with the entry.
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
    // 这两个信号本质都是frontend_pair_policy这个模块算出来的配对信息
    input  logic                       enq_entry0_pair_ok, // 用来判断当前周期的entry0是否有配对资格
    input  logic                       prev_tail_pair_ok, // 用来判断

    // These mutually-exclusive controls fully describe dequeue acceptance.
    // No separate deq_valid is needed; deq_none is their complement.
    input  logic                       deq_single,
    input  logic                       deq_dual,

    output logic [FQ_PTR_W-1:0]        head,
    output logic [FQ_PTR_W-1:0]        head_p1, // head plus 1
    output logic [FQ_PTR_W-1:0]        tail,
    output logic [FQ_PTR_W-1:0]        tail_p1,
    output logic [FQ_PTR_W:0]          count,
    output logic [31:0]                tail_next_pc,

    output frontend_fq_entry_t         head0_entry,
    output frontend_fq_entry_t         head1_entry,
    output frontend_fq_entry_t         tail_prev_entry,
    output frontend_pair_meta_t        head0_pair_meta,
    output frontend_pair_meta_t        head1_pair_meta,
    output frontend_pair_meta_t        tail_prev_pair_meta,
    output logic                       head_pair_ok
);

    // Circular queue storage. pair_ok_mem[i] describes whether entry i can
    // issue together with entry i+1 when i reaches the head.
    frontend_fq_entry_t entry_mem [0:FQ_DEPTH-1];
    frontend_pair_meta_t pair_meta_mem [0:FQ_DEPTH-1];
    logic pair_ok_mem [0:FQ_DEPTH-1];

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
    assign tail_prev_entry = entry_mem[tail_m1];
    assign head0_pair_meta = pair_meta_mem[head];
    assign head1_pair_meta = pair_meta_mem[head_p1];
    assign tail_prev_pair_meta = pair_meta_mem[tail_m1];
    assign head_pair_ok = pair_ok_mem[head];

    wire enq_two = enq1_valid;
    wire enq_one = enq0_valid && !enq1_valid;
    wire enq_none = !enq0_valid;

    // Head/tail/count are computed independently so enqueue and dequeue can
    // occur in the same cycle.
    wire deq_none = ~(deq_single | deq_dual);

    wire [FQ_PTR_W-1:0] head_next =
        ({FQ_PTR_W{deq_dual}}   & head_p2) |
        ({FQ_PTR_W{deq_single}} & head_p1) |
        ({FQ_PTR_W{deq_none}}   & head);

    wire [FQ_PTR_W-1:0] tail_next =
        ({FQ_PTR_W{enq_two}}  & tail_p2) |
        ({FQ_PTR_W{enq_one}}  & tail_p1) |
        ({FQ_PTR_W{enq_none}} & tail);

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

    wire [FQ_PTR_W:0] count_next =
        ({(FQ_PTR_W+1){deq_dual}}   & count_if_deq_dual) |
        ({(FQ_PTR_W+1){deq_single}} & count_if_deq_single) |
        ({(FQ_PTR_W+1){deq_none}}   & count_if_deq_none);

    wire [31:0] enq_last_next_pc =
        enq_two ? (enq_entry1.pc + 32'd4) : (enq_entry0.pc + 32'd4);
    wire [31:0] tail_next_pc_next =
        enq0_valid ? enq_last_next_pc : tail_next_pc;

    integer entry_i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head <= '0;
            tail <= '0;
            count <= '0;
            tail_next_pc <= 32'd0;
            for (entry_i = 0; entry_i < FQ_DEPTH; entry_i = entry_i + 1) begin
                entry_mem[entry_i] <= '0;
                pair_meta_mem[entry_i] <= '0;
                pair_ok_mem[entry_i] <= 1'b0;
            end
        end else if (flush) begin
            head <= '0;
            tail <= '0;
            count <= '0;
            tail_next_pc <= 32'd0;
            for (entry_i = 0; entry_i < FQ_DEPTH; entry_i = entry_i + 1)
                pair_ok_mem[entry_i] <= 1'b0;
        end else begin
            // A speculative payload write is harmless until count exposes it.
            // A later cross-packet enqueue overwrites the previous tail policy.
            if (enq0_payload && (count != 0))
                pair_ok_mem[tail_m1] <= prev_tail_pair_ok;
            if (enq0_payload) begin
                entry_mem[tail] <= enq_entry0;
                pair_meta_mem[tail] <= enq_pair_meta0;
                pair_ok_mem[tail] <= enq_entry0_pair_ok;
            end
            if (enq1_payload) begin
                entry_mem[tail_p1] <= enq_entry1;
                pair_meta_mem[tail_p1] <= enq_pair_meta1;
                pair_ok_mem[tail_p1] <= 1'b0;
            end

            head <= head_next;
            tail <= tail_next;
            count <= count_next;
            tail_next_pc <= tail_next_pc_next;
        end
    end

endmodule
