// ============================================================
// 中文说明：保存已经取回并完成前端标记的指令，向译码阶段提供有序的指令表项。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：该模块只负责实现取指队列的存储、入队、出队和占用量管理。
// 指令能否配对由模块外的配对策略计算；队列中保存配对元数据，入队时
// 只记录 PC 是否连续，完整的配对判断在队首使用已经寄存的元数据完成。
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

    input  logic                       enq0_valid,
    input  logic                       enq1_valid,
    input  frontend_fq_entry_t         enq_entry0, // 这个结构体包含了fq entry需要的所有信息。
    input  frontend_fq_entry_t         enq_entry1,
    input  frontend_pair_meta_t        enq_pair_meta0, // 预译码信息。
    input  frontend_pair_meta_t        enq_pair_meta1,
    // 判断旧 tail 和本次取指包第一条指令的 PC 是否连续；同一取指包
    // 内两条指令天然连续。
    input  logic                       prev_tail_contiguous,

    // 将末端的接受事件和已经知道的取指包宽度分开。deq_two 先决定
    // 一次出队一条还是两条的候选状态，deq_fire 只负责在候选状态间做
    // 最后的选择。
    input  logic                       deq_fire,
    input  logic                       deq_two,

    output logic [FQ_PTR_W-1:0]        head,
    output logic [FQ_PTR_W-1:0]        head_p1, // head plus 1
    output logic [FQ_PTR_W-1:0]        tail,
    output logic [FQ_PTR_W-1:0]        tail_p1,
    output logic [FQ_PTR_W:0]          count,
    output logic [31:0]                tail_next_pc,

    output frontend_fq_entry_t         head0_entry,
    output frontend_fq_entry_t         head1_entry,
    output frontend_pair_meta_t        head0_pair_meta,
    output frontend_pair_meta_t        head1_pair_meta,
    output logic                       head_pair_contiguous
);

    localparam int FQ_BANK_DEPTH = FQ_DEPTH / 2;
    localparam int FQ_BANK_ROW_W = FQ_PTR_W - 1;

    // 入队端和出队端状态在物理上独立。后端产生的出队事件只使能
    // head_q/deq_total_q，不参与入队数据端的选择路径。
    (* extract_enable = "yes" *) logic [FQ_PTR_W-1:0] head_q;
    (* extract_enable = "yes" *) logic [FQ_PTR_W:0] enq_total_q;
    (* extract_enable = "yes" *) logic [FQ_PTR_W:0] deq_total_q;

    assign head = head_q;
    // 队列最多保存 FQ_DEPTH 个表项，因此生产者和消费者指针在
    // 2*FQ_DEPTH 模空间中的差值就是精确的占用量。
    assign count = enq_total_q - deq_total_q;

    // 队列只保存出队后仍会使用的字段。配对元数据已经包含预测结果、
    // 串行属性、乘除法/ALU 类型、寄存器读写属性以及 LSU/控制流属性，
    // 因此不再在宽表项中复制一份。仅供 F0 兼容或调试使用的特权、
    // fence、非法指令和精确 CFI 类型不会越过队列边界。
    typedef struct packed {
        logic [31:0]          pc;
        logic [31:0]          inst;
        logic [31:0]          pred_target;
        logic                 pred_source_abtb;
        logic                 stage1_branch_owned;
        logic [7:0]           stage1_pht_index;
        logic [1:0]           stage1_pht_counter;
        logic                 is_conditional_branch;
        logic                 is_indirect_jump;
        logic                 is_mul;
        logic                 is_load;
        logic                 is_store;
        frontend_pair_meta_t  pair_meta;
    } fq_storage_t;
    localparam int FQ_STORAGE_W = $bits(fq_storage_t);

    // 队列每次读取两个相邻表项，最多写入两个相邻表项。相邻指针的
    // 奇偶性相反，所以按偶数 bank 和奇数 bank 拆分后，原来的逻辑
    // 2R2W 数组变成两个紧凑的 1R1W bank，有利于 RAM 推断，也能去掉
    // 原来占据左侧热点的大型读写选择网络。
    (* ram_style = "distributed" *)
    logic [FQ_STORAGE_W-1:0] even_bank [0:FQ_BANK_DEPTH-1];
    (* ram_style = "distributed" *)
    logic [FQ_STORAGE_W-1:0] odd_bank [0:FQ_BANK_DEPTH-1];

    // pair_contiguous_mem[i] 会在当前 tail 和前一个取指包边界分别更新。
    // 将这八个一位标志独立存放，可以避免把任一 payload bank 重新变成
    // 双写端口存储器。
    logic pair_contiguous_mem [0:FQ_DEPTH-1];

    function automatic fq_storage_t compress_entry(
        input frontend_fq_entry_t  entry,
        input frontend_pair_meta_t pair_meta
    );
        begin
            compress_entry = '0;
            compress_entry.pc = entry.pc;
            compress_entry.inst = entry.inst;
            compress_entry.pred_target = entry.pred_target;
            compress_entry.pred_source_abtb = entry.pred_source_abtb;
            compress_entry.stage1_branch_owned =
                entry.stage1_branch_owned;
            compress_entry.stage1_pht_index = entry.stage1_pht_index;
            compress_entry.stage1_pht_counter = entry.stage1_pht_counter;
            compress_entry.is_conditional_branch =
                entry.is_conditional_branch;
            compress_entry.is_indirect_jump = entry.is_indirect_jump;
            compress_entry.is_mul = entry.is_mul;
            compress_entry.is_load = entry.is_load;
            compress_entry.is_store = entry.is_store;
            compress_entry.pair_meta = pair_meta;
        end
    endfunction

    function automatic frontend_fq_entry_t expand_entry(
        input fq_storage_t stored
    );
        logic reconstructed_direct_jump;
        begin
            // count 是队列有效性的唯一所有者，因此只要表项被暴露就一定有效；
            // 队列为空时，RAM 中的旧数据会被忽略。
            reconstructed_direct_jump = stored.pair_meta.is_cfi
                                      & ~stored.is_conditional_branch
                                      & ~stored.is_indirect_jump;
            expand_entry = '0;
            expand_entry.valid = 1'b1;
            expand_entry.pc = stored.pc;
            expand_entry.inst = stored.inst;
            expand_entry.pred_taken = stored.pair_meta.pred_taken;
            expand_entry.pred_target = stored.pred_target;
            expand_entry.pred_source_abtb = stored.pred_source_abtb;
            expand_entry.stage1_branch_owned =
                stored.stage1_branch_owned;
            expand_entry.stage1_pht_index = stored.stage1_pht_index;
            expand_entry.stage1_pht_counter = stored.stage1_pht_counter;
            expand_entry.is_conditional_branch =
                stored.is_conditional_branch;
            expand_entry.is_direct_jump = reconstructed_direct_jump;
            expand_entry.is_indirect_jump = stored.is_indirect_jump;
            expand_entry.is_muldiv = stored.pair_meta.is_muldiv;
            expand_entry.is_mul = stored.is_mul;
            expand_entry.is_load = stored.is_load;
            expand_entry.is_store = stored.is_store;
            expand_entry.is_alu_type = stored.pair_meta.is_alu_type;
            expand_entry.writes_dst = stored.pair_meta.writes_dst;
            expand_entry.uses_src0 = stored.pair_meta.uses_src0;
            expand_entry.uses_src1 = stored.pair_meta.uses_src1;
            expand_entry.is_jump = reconstructed_direct_jump
                                 | stored.is_indirect_jump;
            expand_entry.is_control = stored.pair_meta.is_cfi;
            expand_entry.is_lsu = stored.pair_meta.is_lsu;
            expand_entry.force_single = stored.pair_meta.force_single;
        end
    endfunction

    wire [FQ_PTR_W-1:0] head_p2 =
        head + {{(FQ_PTR_W-2){1'b0}}, 2'd2};
    wire [FQ_PTR_W-1:0] tail_p2 =
        tail + {{(FQ_PTR_W-2){1'b0}}, 2'd2};
    wire [FQ_PTR_W-1:0] tail_m1 =
        tail - {{(FQ_PTR_W-1){1'b0}}, 1'b1};

    assign head_p1 = head + {{(FQ_PTR_W-1){1'b0}}, 1'b1};
    assign tail_p1 = tail + {{(FQ_PTR_W-1){1'b0}}, 1'b1};

    wire [FQ_BANK_ROW_W-1:0] even_read_row =
        head[0] ? head_p1[FQ_PTR_W-1:1] : head[FQ_PTR_W-1:1];
    wire [FQ_BANK_ROW_W-1:0] odd_read_row = head[FQ_PTR_W-1:1];
    wire fq_storage_t even_read_data =
        fq_storage_t'(even_bank[even_read_row]);
    wire fq_storage_t odd_read_data =
        fq_storage_t'(odd_bank[odd_read_row]);
    wire fq_storage_t head0_stored = head[0]
                                          ? odd_read_data
                                          : even_read_data;
    wire fq_storage_t head1_stored = head[0]
                                          ? even_read_data
                                          : odd_read_data;

    assign head0_entry = expand_entry(head0_stored);
    assign head1_entry = expand_entry(head1_stored);
    assign head0_pair_meta = head0_stored.pair_meta;
    assign head1_pair_meta = head1_stored.pair_meta;
    assign head_pair_contiguous = pair_contiguous_mem[head];

    wire enq_two = enq1_valid;
    wire enq_fire = enq0_valid;
    wire [FQ_PTR_W:0] enq_total_next = enq_total_q
        + (enq_two ? {{(FQ_PTR_W-1){1'b0}}, 2'd2}
                   : {{FQ_PTR_W{1'b0}}, 1'b1});
    wire [FQ_PTR_W:0] deq_total_next = deq_total_q
        + (deq_two ? {{(FQ_PTR_W-1){1'b0}}, 2'd2}
                   : {{FQ_PTR_W{1'b0}}, 1'b1});

    wire [31:0] enq_last_next_pc =
        enq_two ? (enq_entry1.pc + 32'd4) : (enq_entry0.pc + 32'd4);
    // 只有这些指针和计数器决定哪些队列表项有效。payload 存储故意不复位：
    // count 为零时旧数据不可见，而新分配的槽位一定会先写入，再由 count
    // 对外暴露。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head_q <= '0;
        end else if (flush) begin
            head_q <= '0;
        end else if (deq_fire)
            // 后端接受事件只连接到寄存器 CE。寄存器被使能后，数据输入
            // 只由前面产生的一条/两条出队候选决定。
            head_q <= deq_two ? head_p2 : head_p1;
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
            enq_total_q <= '0;
        else if (flush)
            enq_total_q <= '0;
        else if (enq_fire)
            enq_total_q <= enq_total_next;
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            deq_total_q <= '0;
        else if (flush)
            deq_total_q <= '0;
        else if (deq_fire)
            deq_total_q <= deq_total_next;
    end

    // 复位或冲刷后 count==0 会屏蔽这个连续性字段；下一次接受的取指包
    // 会在它被观察之前将其覆盖。
    always_ff @(posedge clk) begin
        if (enq_fire)
            tail_next_pc <= enq_last_next_pc;
    end

    // 将包边界标志的写地址译成每个表项的独立使能。每个包的第一条
    // 表项先无条件标记为连续；如果后面没有有效 slot1，count 会阻止
    // 错误配对，下一包随后会用真实的跨包连续性覆盖该位。因此 IROM
    // 指令位不会进入这部分存储的 D 输入。
    generate
        for (genvar pair_idx = 0; pair_idx < FQ_DEPTH; pair_idx++) begin : g_pair_contiguous_write
            localparam logic [FQ_PTR_W-1:0] PAIR_INDEX = pair_idx;
            wire pair_write_current = enq0_valid & (tail == PAIR_INDEX);
            wire pair_write_previous = enq0_valid & (count != 0)
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

    wire even_write_entry0 = enq0_valid & ~tail[0];
    wire even_write_entry1 = enq1_valid & tail[0];
    wire odd_write_entry0 = enq0_valid & tail[0];
    wire odd_write_entry1 = enq1_valid & ~tail[0];
    wire even_write = even_write_entry0 | even_write_entry1;
    wire odd_write = odd_write_entry0 | odd_write_entry1;
    wire [FQ_BANK_ROW_W-1:0] even_write_row = even_write_entry0
        ? tail[FQ_PTR_W-1:1] : tail_p1[FQ_PTR_W-1:1];
    wire [FQ_BANK_ROW_W-1:0] odd_write_row = odd_write_entry0
        ? tail[FQ_PTR_W-1:1] : tail_p1[FQ_PTR_W-1:1];
    wire fq_storage_t even_write_data = even_write_entry0
        ? compress_entry(enq_entry0, enq_pair_meta0)
        : compress_entry(enq_entry1, enq_pair_meta1);
    wire fq_storage_t odd_write_data = odd_write_entry0
        ? compress_entry(enq_entry0, enq_pair_meta0)
        : compress_entry(enq_entry1, enq_pair_meta1);

    // payload bank 不连接复位/冲刷的高扇出网络。与冲刷同周期的写入
    // 是安全的，因为 count 已经清零；后续分配会在暴露该行前覆盖它。
    always_ff @(posedge clk) begin
        if (even_write)
            even_bank[even_write_row] <= even_write_data;
        if (odd_write)
            odd_bank[odd_write_row] <= odd_write_data;
    end

`ifndef SYNTHESIS
    logic [FQ_PTR_W:0] count_reference_q;

    // 保留原来的整体占用量方程作为可执行参考模型，用来验证拆分生产者
    // 和消费者状态后，同时入队/出队、指针回绕、复位和冲刷仍保持周期一致。
    always_ff @(posedge clk) begin
        if (!rst_n)
            count_reference_q <= '0;
        else if (flush)
            count_reference_q <= '0;
        else begin
            count_reference_q <= count_reference_q
                + (enq_fire
                    ? (enq_two
                        ? {{(FQ_PTR_W-1){1'b0}}, 2'd2}
                        : {{FQ_PTR_W{1'b0}}, 1'b1})
                    : '0)
                - (deq_fire
                    ? (deq_two
                        ? {{(FQ_PTR_W-1){1'b0}}, 2'd2}
                        : {{FQ_PTR_W{1'b0}}, 1'b1})
                    : '0);
        end

        if (rst_n && !flush && (count !== count_reference_q))
            $fatal(1, "FQ split producer/consumer count changed occupancy");
        if (rst_n && (count > FQ_DEPTH))
            $fatal(1, "FQ occupancy exceeded configured depth");
    end

    // 压缩表项依赖 packet builder 保证的元数据等价关系。这里保留可执行
    // 检查，防止以后前端修改后让被删除的重复字段重新影响架构行为。
    // entry.is_control 故意不参与压缩：静态冲刷、非法或特权表项可能置位
    // 它但并不一定是控制流指令，FQ 后的消费者也不会读取这个兼容字段。
    always_ff @(posedge clk) begin
        if (rst_n && enq0_valid) begin
            if ((enq_entry0.pred_taken !== enq_pair_meta0.pred_taken)
                || (enq_entry0.force_single
                    !== enq_pair_meta0.force_single)
                || (enq_entry0.is_muldiv !== enq_pair_meta0.is_muldiv)
                || (enq_entry0.is_alu_type !== enq_pair_meta0.is_alu_type)
                || (enq_entry0.is_lsu !== enq_pair_meta0.is_lsu)
                || (enq_entry0.writes_dst !== enq_pair_meta0.writes_dst)
                || (enq_entry0.uses_src0 !== enq_pair_meta0.uses_src0)
                || (enq_entry0.uses_src1 !== enq_pair_meta0.uses_src1))
                $fatal(1, "FQ slot 0 duplicate metadata disagrees");
        end
        if (rst_n && enq1_valid) begin
            if ((enq_entry1.pred_taken !== enq_pair_meta1.pred_taken)
                || (enq_entry1.force_single
                    !== enq_pair_meta1.force_single)
                || (enq_entry1.is_muldiv !== enq_pair_meta1.is_muldiv)
                || (enq_entry1.is_alu_type !== enq_pair_meta1.is_alu_type)
                || (enq_entry1.is_lsu !== enq_pair_meta1.is_lsu)
                || (enq_entry1.writes_dst !== enq_pair_meta1.writes_dst)
                || (enq_entry1.uses_src0 !== enq_pair_meta1.uses_src0)
                || (enq_entry1.uses_src1 !== enq_pair_meta1.uses_src1))
                $fatal(1, "FQ slot 1 duplicate metadata disagrees");
        end
    end
`endif

endmodule
