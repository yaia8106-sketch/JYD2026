// ============================================================
// Module: frontend_fetch_queue
// Description:
// TODO
// Domain: frontend.
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

    // enq是enqueue(入队)的缩写
    input  logic                       enq0_payload, // enq0_payload = accept_base(本质是个valid信号) && base_mask[0](看取指块的这条指令能不能用，比如当取指的PC[2]=1的时候enq1就不为valid)，和enq0_valid本质是一个信号
    input  logic                       enq1_payload,
    input  logic                       enq0_valid, // enq0_valid = enq0_payload
    input  logic                       enq1_valid,
    input  frontend_fq_entry_t         enq_entry0,
    input  frontend_fq_entry_t         enq_entry1,
    input  frontend_pair_meta_t        enq_pair_meta0, // 预译码信息。
    input  frontend_pair_meta_t        enq_pair_meta1,
    // 这两个信号都是由frontend_pair_policy模块算出来的配对信息
    // 用来判断slot0与slot1能否双发射(enq_entry0_pair_ok)
    // 以及判断slot0与上一拍遗留的slot1能否双发射(prev_tail_pair_ok)
    // 我们的fifo中，每个entry只存一条指令的信息，每个entry只会判断“这条指令能否与相邻的下一条指令配对”
    // prev_tail_pair_ok负责保证跨包配对，enq_entry0_pair_ok负责保证同包配对
    input  logic                       enq_entry0_pair_ok,
    input  logic                       prev_tail_pair_ok,

    // deq是dequeue(出队)的缩写
    // 这两个互斥信号已经完整描述出队行为；二者均为0就是没有出队。
    // 用于判断fq最终是出队了一条指令还是两条指令，并控制head增量。
    input  logic                       deq_single,
    input  logic                       deq_dual,

    output logic [FQ_PTR_W-1:0]        head,
    output logic [FQ_PTR_W-1:0]        head_p1, // head plus 1
    output logic [FQ_PTR_W-1:0]        tail,
    output logic [FQ_PTR_W-1:0]        tail_p1,
    output logic [FQ_PTR_W:0]          count, // 记录fifo深度
    output logic [31:0]                tail_next_pc, //? 用于判断指令能否配对，我怀疑是为了防止中断等情况导致redirect时fifo错误压入指令所做的

    output frontend_fq_entry_t         head0_entry, // 出队的entry，用于后续(F1)的RAW配对等操作
    output frontend_fq_entry_t         head1_entry,
    output frontend_fq_entry_t         tail_prev_entry, //这个entry是tail(入队)的entry，并没有任何的卵用，可以删除相关逻辑
    output frontend_pair_meta_t        head0_pair_meta, // 出队的entry，用于redirect和预测器update
    output frontend_pair_meta_t        head1_pair_meta,
    output frontend_pair_meta_t        tail_prev_pair_meta, // 这个entry很有用，我们在F0会对slot0能否与上一拍遗留的slot1双发射进行判定，这个entry的信息就是“上一拍遗留的slot1”所包含的信息
    output logic                       head_pair_ok // 如果出队的head0_entry能和head1_entry配对，则该信号拉高
);

    // fifo中具体存储的就是这三类数据
    frontend_fq_entry_t  entry_mem     [0:FQ_DEPTH-1];
    frontend_pair_meta_t pair_meta_mem [0:FQ_DEPTH-1];
    logic                pair_ok_mem   [0:FQ_DEPTH-1];

    // Pointer arithmetic
    // -- head 出队指针
    wire [FQ_PTR_W-1:0] head_p2;
    // -- tail 入队指针
    wire [FQ_PTR_W-1:0] tail_m1;   // tail minus 1
    wire [FQ_PTR_W-1:0] tail_p2;

    assign head_p1 = head + {{(FQ_PTR_W-1){1'b0}}, 1'b1}; // 如果出队一条指令，那head = head plus 1
    assign head_p2 = head + {{(FQ_PTR_W-2){1'b0}}, 2'd2}; // 如果出队两条指令，那head = head plus 2
    assign tail_m1 = tail - {{(FQ_PTR_W-1){1'b0}}, 1'b1}; // ptr minus1这里有三个作用：一是用于获取tail_prev_entry，二是用于获取tail_prev_pair_meta，用来给F0进行跨包配对检测，三是用来将prev_tail_pair_ok压入fifo中
    assign tail_p1 = tail + {{(FQ_PTR_W-1){1'b0}}, 1'b1}; // 如果入队一条指令，那tail = tail plus 1
    assign tail_p2 = tail + {{(FQ_PTR_W-2){1'b0}}, 2'd2}; // 如果入队两条指令，那tail = tail plus 2

    // entry_mem
    assign head0_entry = entry_mem[head];
    assign head1_entry = entry_mem[head_p1];
    assign tail_prev_entry = entry_mem[tail_m1];

    // pair_meta_mem
    assign head0_pair_meta = pair_meta_mem[head];
    assign head1_pair_meta = pair_meta_mem[head_p1];
    assign tail_prev_pair_meta = pair_meta_mem[tail_m1];

    // pair_ok_mem
    assign head_pair_ok = pair_ok_mem[head];

    wire enq_two = enq1_valid;
    wire enq_one = enq0_valid && !enq1_valid;
    wire enq_none = !enq0_valid;

    // 指针位置的变动逻辑
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

    // 按出队数量并行预计算三个候选值，让后端的晚到握手信号只经过
    // 最后一层选择，不再串行经过inc/dec谓词树。
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
