// ============================================================
// 中文说明：保存已经接受但尚未完成的 store，隔离写入请求与流水线前端。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：dcache_store_buffer。
// 说明：保存两项尚未完成的写直达 store，并查询最近的 store。
// 职责：
//   - 保留待处理 store，直到存储后端确认；
//   - 保留最近两项 store，用于完全覆盖的 load-miss 旁路；
//   - cache line refill 开始时保存同 line 的最近 store 快照；
//   - 将快照合并到每个被接受的 refill word 中。
// ============================================================

module dcache_store_buffer (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        push,
    input  logic [31:0] push_addr,
    input  logic [ 3:0] push_wea,
    input  logic [31:0] push_data,
    input  logic        pop,

    output logic        any_pending,
    output logic        full,
    output logic [31:0] drain_addr,
    output logic [ 3:0] drain_wea,
    output logic [31:0] drain_data,

    // 两个独立预计算的读地址候选。拆开 line 和 word 字段，避免较晚的
    // word/beat 算术在完整 line 等值比较前串行展开。
    input  logic [13:0] drain_compare_line0,
    input  logic [ 1:0] drain_compare_word0,
    input  logic [13:0] drain_compare_line1,
    input  logic [ 1:0] drain_compare_word1,
    output logic        drain_addr_match0,
    output logic        drain_addr_match1,

    input  logic [31:0] lookup_addr,
    input  logic [ 3:0] lookup_mask,
    output logic        lookup_covers,
    output logic [31:0] lookup_data,

    input  logic        refill_capture,
    input  logic [31:0] refill_line_addr,
    input  logic [ 1:0] refill_word,
    input  logic [31:0] refill_base_data,
    output logic [31:0] refill_merged_data,

    // 保留在 DCache 边界上的兼容和观测输出。
    output logic [ 1:0] pending_q,
    output logic [ 1:0] recent_valid_q,
    output logic        alloc_sel,
    output logic        drain_sel
);

    logic [31:0] addr_q [1:0];
    logic [ 3:0] wea_q  [1:0];
    logic [31:0] data_q [1:0];

    logic        refill_merge_valid [1:0];
    logic [ 1:0] refill_merge_word  [1:0];
    logic [ 3:0] refill_merge_wea   [1:0];
    logic [31:0] refill_merge_data  [1:0];

    function automatic [31:0] merge_bytes (
        input logic [31:0] base,
        input logic [31:0] overlay,
        input logic [ 3:0] strobe
    );
        begin
            merge_bytes[ 7: 0] = strobe[0] ? overlay[ 7: 0] : base[ 7: 0];
            merge_bytes[15: 8] = strobe[1] ? overlay[15: 8] : base[15: 8];
            merge_bytes[23:16] = strobe[2] ? overlay[23:16] : base[23:16];
            merge_bytes[31:24] = strobe[3] ? overlay[31:24] : base[31:24];
        end
    endfunction

    // ================================================================
    //  排空选择。
    // ================================================================
    assign any_pending = |pending_q;
    assign full        = &pending_q;

    // 两项都待处理时，alloc_sel 根据交替分配规则指出较老的项；只有一项时，
    // 直接选择该物理槽位。
    assign drain_sel  = (pending_q == 2'b11) ? alloc_sel : pending_q[1];
    assign drain_addr = drain_sel ? addr_q[1] : addr_q[0];
    assign drain_wea  = drain_sel ? wea_q[1]  : wea_q[0];
    assign drain_data = drain_sel ? data_q[1] : data_q[0];

    // 两个物理表项和两个读候选并行比较。KEEP 防止综合在末级候选选择之后
    // 重新构造 16 位等值比较；该逻辑曾经位于报告中的 BRAM-enable 时序锥上。
    (* keep = "true" *) wire entry0_line0_match =
        addr_q[0][17:4] == drain_compare_line0;
    (* keep = "true" *) wire entry1_line0_match =
        addr_q[1][17:4] == drain_compare_line0;
    (* keep = "true" *) wire entry0_line1_match =
        addr_q[0][17:4] == drain_compare_line1;
    (* keep = "true" *) wire entry1_line1_match =
        addr_q[1][17:4] == drain_compare_line1;
    wire entry0_word0_match = addr_q[0][3:2] == drain_compare_word0;
    wire entry1_word0_match = addr_q[1][3:2] == drain_compare_word0;
    wire entry0_word1_match = addr_q[0][3:2] == drain_compare_word1;
    wire entry1_word1_match = addr_q[1][3:2] == drain_compare_word1;
    wire entry0_addr0_match = entry0_line0_match & entry0_word0_match;
    wire entry1_addr0_match = entry1_line0_match & entry1_word0_match;
    wire entry0_addr1_match = entry0_line1_match & entry0_word1_match;
    wire entry1_addr1_match = entry1_line1_match & entry1_word1_match;
    assign drain_addr_match0 = drain_sel ? entry1_addr0_match
                                         : entry0_addr0_match;
    assign drain_addr_match1 = drain_sel ? entry1_addr1_match
                                         : entry0_addr1_match;

    // ================================================================
    //  最近 store 的 load-miss 查询。
    // ================================================================
    // DCache 只服务比赛 DRAM 窗口 0x8010_0000..0x8013_FFFF，因此 [31:18]
    // 恒定；Cache 用 address[17:2] 的 {tag,index,word} 标识一个字。
    // store buffer 使用相同的 key，不在 CPU-ready 关键路径上重复构造
    // 30 位等值比较链。
    wire lookup_match0 = recent_valid_q[0]
                       & (addr_q[0][17:2] == lookup_addr[17:2]);
    wire lookup_match1 = recent_valid_q[1]
                       & (addr_q[1][17:2] == lookup_addr[17:2]);

    // 覆盖信息和数据候选不依赖较晚的地址匹配。将匹配结果移出字节掩码/合并
    // 逻辑锥后，地址等值比较和 DCache cpu_ready 之间只剩一个小选择器。
    wire lookup_mask_nonzero = |lookup_mask;
    (* keep = "true" *) wire lookup_cover_entry0_candidate =
        lookup_mask_nonzero
        & ((wea_q[0] & lookup_mask) == lookup_mask);
    (* keep = "true" *) wire lookup_cover_entry1_candidate =
        lookup_mask_nonzero
        & ((wea_q[1] & lookup_mask) == lookup_mask);
    (* keep = "true" *) wire lookup_cover_both_candidate =
        lookup_mask_nonzero
        & (((wea_q[0] | wea_q[1]) & lookup_mask) == lookup_mask);

    wire [31:0] lookup_entry0_candidate =
        merge_bytes(32'd0, data_q[0], wea_q[0]);
    wire [31:0] lookup_entry1_candidate =
        merge_bytes(32'd0, data_q[1], wea_q[1]);

    // alloc=0：entry0 较老，entry1 较新。
    // alloc=1：entry1 较老，entry0 较新。
    wire [31:0] lookup_both_0_then_1_candidate =
        merge_bytes(lookup_entry0_candidate, data_q[1], wea_q[1]);
    wire [31:0] lookup_both_1_then_0_candidate =
        merge_bytes(lookup_entry1_candidate, data_q[0], wea_q[0]);
    wire [31:0] lookup_both_candidate = alloc_sel
        ? lookup_both_1_then_0_candidate
        : lookup_both_0_then_1_candidate;

    always_comb begin
        case ({lookup_match1, lookup_match0})
            2'b01: begin
                lookup_covers = lookup_cover_entry0_candidate;
                lookup_data = lookup_entry0_candidate;
            end
            2'b10: begin
                lookup_covers = lookup_cover_entry1_candidate;
                lookup_data = lookup_entry1_candidate;
            end
            2'b11: begin
                lookup_covers = lookup_cover_both_candidate;
                lookup_data = lookup_both_candidate;
            end
            default: begin
                lookup_covers = 1'b0;
                lookup_data = 32'd0;
            end
        endcase
    end

    // ================================================================
    //  Refill 覆盖。
    // ================================================================
    wire recent_old_valid = alloc_sel ? recent_valid_q[1] : recent_valid_q[0];
    wire [31:0] recent_old_addr = alloc_sel ? addr_q[1] : addr_q[0];
    wire [ 3:0] recent_old_wea  = alloc_sel ? wea_q[1]  : wea_q[0];
    wire [31:0] recent_old_data = alloc_sel ? data_q[1] : data_q[0];
    wire recent_new_valid = alloc_sel ? recent_valid_q[0] : recent_valid_q[1];
    wire [31:0] recent_new_addr = alloc_sel ? addr_q[0] : addr_q[1];
    wire [ 3:0] recent_new_wea  = alloc_sel ? wea_q[0]  : wea_q[1];
    wire [31:0] recent_new_data = alloc_sel ? data_q[0] : data_q[1];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int e = 0; e < 2; e++) begin
                refill_merge_valid[e] <= 1'b0;
                refill_merge_word[e]  <= 2'd0;
                refill_merge_wea[e]   <= 4'd0;
                refill_merge_data[e]  <= 32'd0;
            end
        end else if (refill_capture) begin
            // 保持年龄顺序，使 entry1 在字节重叠时获胜。
            refill_merge_valid[0] <= recent_old_valid
                                   & (recent_old_addr[31:4] == refill_line_addr[31:4]);
            refill_merge_word[0]  <= recent_old_addr[3:2];
            refill_merge_wea[0]   <= recent_old_wea;
            refill_merge_data[0]  <= recent_old_data;
            refill_merge_valid[1] <= recent_new_valid
                                   & (recent_new_addr[31:4] == refill_line_addr[31:4]);
            refill_merge_word[1]  <= recent_new_addr[3:2];
            refill_merge_wea[1]   <= recent_new_wea;
            refill_merge_data[1]  <= recent_new_data;
        end
    end

    wire refill_match0 = refill_merge_valid[0]
                       & (refill_merge_word[0] == refill_word);
    wire refill_match1 = refill_merge_valid[1]
                       & (refill_merge_word[1] == refill_word);
    wire [3:0] refill_strobe0 = refill_match0 ? refill_merge_wea[0] : 4'b0000;
    wire [3:0] refill_strobe1 = refill_match1 ? refill_merge_wea[1] : 4'b0000;
    wire [31:0] refill_after_0 =
        merge_bytes(refill_base_data, refill_merge_data[0], refill_strobe0);

    assign refill_merged_data =
        merge_bytes(refill_after_0, refill_merge_data[1], refill_strobe1);

    // ================================================================
    //  队列状态。
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pending_q      <= 2'b00;
            recent_valid_q <= 2'b00;
            alloc_sel      <= 1'b0;
            for (int e = 0; e < 2; e++) begin
                addr_q[e] <= 32'd0;
                wea_q[e]  <= 4'd0;
                data_q[e] <= 32'd0;
            end
        end else begin
            if (pop)
                pending_q[drain_sel] <= 1'b0;

            if (push) begin
                pending_q[alloc_sel]      <= 1'b1;
                recent_valid_q[alloc_sel] <= 1'b1;
                addr_q[alloc_sel]         <= push_addr;
                wea_q[alloc_sel]          <= push_wea;
                data_q[alloc_sel]         <= push_data;
                alloc_sel                 <= ~alloc_sel;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n) begin
            // 对于独立的直接 BRAM 排空，同周期 pop/push 是合法的。
            // 满队列可以用新写入替换刚排空的最老槽位；后面的 push 赋值
            // 有意保留该槽位的 pending 位。
            if (push && pending_q[alloc_sel]
                     && !(pop && (drain_sel == alloc_sel)))
                $error("DCache store buffer overwrote a pending entry");
            if (pop && !pending_q[drain_sel])
                $error("DCache store buffer popped a non-pending entry");
            if (|(pending_q & ~recent_valid_q))
                $error("DCache pending entry lost recent-store validity");
        end
    end
`endif

endmodule
