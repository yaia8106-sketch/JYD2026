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

    // Producer and consumer state are physically independent.  In particular,
    // the backend-derived dequeue event only enables head_q/deq_total_q; it
    // never selects a value on the enqueue-side D cone.
    (* extract_enable = "yes" *) logic [FQ_PTR_W-1:0] head_q;
    (* extract_enable = "yes" *) logic [FQ_PTR_W:0] enq_total_q;
    (* extract_enable = "yes" *) logic [FQ_PTR_W:0] deq_total_q;

    assign head = head_q;
    // The queue never contains more than FQ_DEPTH entries, so the modulo
    // (2 * FQ_DEPTH) producer-consumer difference is the exact occupancy.
    assign count = enq_total_q - deq_total_q;

    // Only fields consumed after the queue are stored.  Pair-policy metadata
    // already contains pred_taken, force_single, is_muldiv, is_alu_type,
    // writes/uses-register and is_lsu/is_cfi, so keeping a second copy of those
    // bits in the wide entry array merely creates more flops and routing.
    // Fields used only by the F0 compatibility/debug aliases (privileged,
    // fence, illegal and exact CFI type) never cross the queue boundary.
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

    // The queue always reads two adjacent entries and writes at most two
    // adjacent entries.  Adjacent pointers have opposite parity, therefore an
    // even/odd split turns the old logical 2R2W array into two compact 1R1W
    // banks.  This is both a better RAM inference shape and removes the large
    // read/write mux fabric that previously occupied the left-side hotspot.
    (* ram_style = "distributed" *)
    logic [FQ_STORAGE_W-1:0] even_bank [0:FQ_BANK_DEPTH-1];
    (* ram_style = "distributed" *)
    logic [FQ_STORAGE_W-1:0] odd_bank [0:FQ_BANK_DEPTH-1];

    // pair_contiguous_mem[i] is updated both at the current tail and at the
    // preceding packet boundary.  Keeping these eight one-bit flags separate
    // avoids turning either payload bank back into a two-write-port memory.
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
            // count is the validity owner, so an exposed queue entry is valid
            // by construction.  Stale RAM contents are ignored while empty.
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
    // Only these pointers/counters define which queue entries are valid.
    // Payload storage is intentionally left unreset: stale words cannot be
    // observed while count is zero, and every newly allocated slot is written
    // before count exposes it.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head_q <= '0;
        end else if (flush) begin
            head_q <= '0;
        end else if (deq_fire)
            // Backend acceptance reaches only CE.  Once enabled, the data
            // input depends solely on the early one-entry/two-entry choice.
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

    // Keep payload banks off reset/flush fanout.  A flush-coincident write is
    // harmless because count is cleared, and a later allocation overwrites the
    // selected row before exposing it.
    always_ff @(posedge clk) begin
        if (even_write)
            even_bank[even_write_row] <= even_write_data;
        if (odd_write)
            odd_bank[odd_write_row] <= odd_write_data;
    end

`ifndef SYNTHESIS
    logic [FQ_PTR_W:0] count_reference_q;

    // Retain the former monolithic occupancy equation as an executable model.
    // This proves simultaneous enqueue/dequeue, wrap, reset and flush behavior
    // remain cycle-identical after separating producer and consumer state.
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

    // Compression deliberately relies on metadata equality that the packet
    // builder guarantees.  Keep that contract executable so future frontend
    // edits cannot silently make a removed duplicate field architecturally
    // observable. entry.is_control is intentionally excluded: static-kill
    // illegal/privileged entries may set it without being a CFI, and no
    // post-FQ consumer observes that retired compatibility field.
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
