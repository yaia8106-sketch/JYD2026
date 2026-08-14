// ============================================================
// 中文说明：实现只读 ICache，包括指令命中、缺失 refill、关键字优先返回和预译码元数据。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：这是位于可变延迟前端接口和共享 32 位存储后端之间的 ICache。
// 组织方式：
//   - 容量、路数和 line 大小由参数决定；当前比赛配置使用 16 字节 line；
//   - 数据使用简单双口 BRAM，way 被折叠进 BRAM 行地址，避免每一路重复
//     一份数据存储；
//   - 指令数据和 refill 时产生的预译码元数据共用 BRAM 的数据位；
//   - Tag、valid 和分类信息使用分布式存储，双路配置额外保存替换位；
//   - 缺失时从关键 64 位块开始进行四拍 WRAP refill。
// 当 irom_req_valid 和 irom_req_ready 同时为 1 时，请求被接受；同步
// 数据 RAM 的命中结果在下一周期返回。前端没有响应反压，会立即消费
// 每个 valid 响应。前端冲刷只清除当前查找/缺失的所有权；已经被后端
// 接受的 AXI 读仍会排空，但后续返回拍不会写入 cache，排空期间独立
// 的 cache 命中仍可继续服务。
// ============================================================

module icache #(
    // NSCSCC 程序在一个 1 MiB 的物理 PC 窗口内执行。只有窗口内请求
    // 可以在压缩 Tag 数组中分配或命中；AXI 侧始终保留完整 32 位地址。
    parameter logic [11:0] ICACHE_ADDR_PREFIX = 12'h1c0,
    parameter integer CACHE_BYTES =
`ifdef NSCSCC_ICACHE_BYTES
        `NSCSCC_ICACHE_BYTES,
`else
        16384,
`endif
    parameter integer WAYS =
`ifdef NSCSCC_ICACHE_WAYS
        `NSCSCC_ICACHE_WAYS
`else
        1
`endif
) (
    // 时钟和复位
    input  logic        clk,
    input  logic        rst_n,

    // 前端 64 位指令块接口
    input  logic        irom_req_valid,
    output logic        irom_req_ready,
    input  logic [31:0] irom_req_addr,
    input  logic        irom_req_kill,
    output logic        irom_resp_valid,
    output logic [63:0] irom_resp_data,
    output logic [13:0] irom_resp_predecode,
    output logic [ 1:0] irom_resp_resp,

    // 共享 32 位存储后端读接口
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic [ 7:0] mem_req_len,
    output logic [ 1:0] mem_req_burst,
    input  logic        mem_rd_valid,
    output logic        mem_rd_ready,
    input  logic [31:0] mem_rd_data,
    input  logic        mem_rd_last,
    input  logic [ 1:0] mem_rd_resp
);

    localparam integer LINE_BYTES = 16;
    localparam integer LINE_OFFSET_WIDTH = 4;
    localparam integer LINES = CACHE_BYTES / LINE_BYTES;
    localparam integer SETS = LINES / WAYS;
    localparam integer INDEX_WIDTH = $clog2(SETS);
    localparam integer WAY_WIDTH = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam integer TAG_WIDTH = 20 - LINE_OFFSET_WIDTH - INDEX_WIDTH;
    localparam integer BLOCK_CLASS_WIDTH = 6;
    localparam integer LINE_CLASS_WIDTH = 12;
    localparam integer TAG_RAM_WIDTH = TAG_WIDTH + LINE_CLASS_WIDTH;
    localparam integer DATA_ROWS_PER_WAY = SETS * 2;
    localparam integer DATA_ROWS = LINES * 2;
    localparam integer LINE_SLOT_WIDTH = $clog2(LINES);
    localparam integer DATA_ROW_WIDTH = $clog2(DATA_ROWS);

    localparam logic [1:0] REFILL_IDLE = 2'd0;
    localparam logic [1:0] REFILL_REQ  = 2'd1;
    localparam logic [1:0] REFILL_DATA = 2'd2;
    wire [1:0] refill_state_q;

    // ----------------------------------------------------------------
    // Cache 数组
    // ----------------------------------------------------------------

    // 分布式 Tag 查找完成后，把选中的 way 折叠进同步 BRAM 行地址。
    // 两条指令 lane 使用独立的 36 位存储：每 lane 保存一条 32 位指令
    // 和四个 parity 位的预译码信息。这样 16 KiB 配置仍使用四个 RAMB36，
    // 但每个返回 lane 只需在两个深度 bank 之间选择，不必经过一个 72 位
    // 四 bank 存储器的末端大选择器。
    (* ram_style = "block" *)
    logic [35:0] data_mem_slot0 [0:DATA_ROWS-1];
    (* ram_style = "block" *)
    logic [35:0] data_mem_slot1 [0:DATA_ROWS-1];
    (* ram_style = "distributed" *)
    logic [TAG_RAM_WIDTH-1:0] tag_mem [0:LINES-1];
    logic [LINES-1:0] line_valid_q;
    logic [SETS-1:0] replacement_way_q;

    logic [35:0] lookup_slot0_q;
    logic [35:0] lookup_slot1_q;
    wire  [71:0] lookup_payload_q = {
        lookup_slot1_q[35:32],
        lookup_slot0_q[35:32],
        lookup_slot1_q[31:0],
        lookup_slot0_q[31:0]
    };
    logic [BLOCK_CLASS_WIDTH-1:0] lookup_class_q;

    // ----------------------------------------------------------------
    // 一拍查找流水
    // ----------------------------------------------------------------

    logic        lookup_valid_q;
    logic        lookup_hit_q;
    logic        lookup_refill_hit_q;
    logic        lookup_refill_line_match_q;
    logic        lookup_commit_hit;
    logic [28:0] lookup_block_addr_q;
    wire         lookup_hit =
        lookup_valid_q & (lookup_hit_q | lookup_commit_hit);
    wire         lookup_miss = lookup_valid_q & ~lookup_hit;

    logic        pending_miss_valid_q;
    logic [28:0] pending_miss_block_addr_q;

    logic        miss_resp_valid_q;
    logic [71:0] miss_resp_payload_q;
    logic [BLOCK_CLASS_WIDTH-1:0] miss_resp_class_q;
    logic [ 1:0] miss_resp_resp_q;

    logic [27:0] refill_buffer_line_addr_q;
    logic [ 1:0] refill_buffer_filled_q;
    logic [71:0] refill_buffer_block0_q;
    logic [71:0] refill_buffer_block1_q;
    logic [BLOCK_CLASS_WIDTH-1:0] refill_buffer_block0_class_q;
    logic [BLOCK_CLASS_WIDTH-1:0] refill_buffer_block1_class_q;
    logic [ 1:0] refill_line_resp_q;

    wire [27:0] refill_line_addr_q;
    wire        refill_block_q;
    wire [WAY_WIDTH-1:0] refill_way_q;
    wire        refill_second_block_q;
    wire        refill_response_needed_q;
    wire        refill_drop_q;
    wire        refill_beat_q;
    wire [31:0] refill_word0_q;
    wire [ 1:0] refill_block_resp_q;
    wire         refill_block_commit;

    // 最后一拍 refill 先完成已寄存的 block 分类信息；下一时钟沿再提交
    // Tag/valid。这样 refill 译码器不会进入 LUTRAM 写数据路径。
    logic                   tag_commit_pending_q;
    logic [INDEX_WIDTH-1:0] tag_commit_index_q;
    logic [TAG_WIDTH-1:0]   tag_commit_tag_q;
    logic [WAY_WIDTH-1:0]   tag_commit_way_q;

    wire irom_req_fire = irom_req_valid & irom_req_ready;
    wire [INDEX_WIDTH-1:0] irom_req_index =
        irom_req_addr[LINE_OFFSET_WIDTH +: INDEX_WIDTH];
    wire [TAG_WIDTH-1:0] irom_req_tag =
        irom_req_addr[LINE_OFFSET_WIDTH + INDEX_WIDTH +: TAG_WIDTH];
    wire irom_req_in_window =
        irom_req_addr[31:20] == ICACHE_ADDR_PREFIX;
    wire irom_req_block = irom_req_addr[3];
    wire [WAY_WIDTH-1:0] irom_req_array_way;
    wire [DATA_ROW_WIDTH-1:0] irom_req_data_row;
    generate
        if (WAYS == 1) begin : g_request_row_one_way
            assign irom_req_data_row = {irom_req_index, irom_req_block};
        end else begin : g_request_row_two_ways
            assign irom_req_data_row = {
                irom_req_array_way[0], irom_req_index, irom_req_block
            };
        end
    endgenerate

    // 已寄存的本地命中会在当前周期被前端消费，因此同一时钟沿可以
    // 用下一条 BP 请求替换查找槽。缺失请求在复制到 pending_miss 前
    // 一直保持所有权。
    assign irom_req_ready =
        (~lookup_valid_q | lookup_hit_q | lookup_commit_hit)
        & ~pending_miss_valid_q
        & ~miss_resp_valid_q;

    // BP 阶段计算命中。所有 way 的 Tag 从分布式存储中并行读取，命中的
    // way 随后进入同步数据 RAM 的行地址，避免重复读取 BRAM。压缩 Tag
    // 比较拆成低位和高位两组，使综合工具可以并行计算，而不是形成
    // 串行比较器。
    wire [WAYS-1:0] irom_req_way_hit;
    wire [TAG_RAM_WIDTH-1:0] irom_req_way_tag_payload [0:WAYS-1];
    genvar lookup_way;
    generate
        for (lookup_way = 0; lookup_way < WAYS;
             lookup_way = lookup_way + 1) begin : g_lookup_way
            localparam logic [LINE_SLOT_WIDTH-1:0] WAY_LINE_BASE =
                LINE_SLOT_WIDTH'(lookup_way * SETS);
            wire [LINE_SLOT_WIDTH-1:0] line_slot =
                WAY_LINE_BASE | LINE_SLOT_WIDTH'(irom_req_index);
            wire [TAG_WIDTH-1:0] cached_tag =
                irom_req_way_tag_payload[lookup_way][TAG_WIDTH-1:0];
            wire [TAG_WIDTH-1:0] tag_diff = cached_tag ^ irom_req_tag;
            wire tag_eq_low = ~|tag_diff[3:0];
            wire tag_eq_high = ~|tag_diff[TAG_WIDTH-1:4];

            assign irom_req_way_tag_payload[lookup_way] =
                tag_mem[line_slot];
            assign irom_req_way_hit[lookup_way] =
                irom_req_in_window
                & line_valid_q[line_slot]
                & tag_eq_low & tag_eq_high;
        end
    endgenerate

    generate
        if (WAYS == 1) begin : g_select_one_way
            assign irom_req_array_way = '0;
        end else begin : g_select_two_ways
            // 同一个组中最多只有一路可以保存给定的压缩 Tag。
            assign irom_req_array_way =
                irom_req_way_hit[0] ? 0 : 1;
        end
    endgenerate

    wire [TAG_RAM_WIDTH-1:0] irom_req_tag_payload =
        irom_req_way_tag_payload[irom_req_array_way];
    wire [LINE_CLASS_WIDTH-1:0] irom_req_line_class =
        irom_req_tag_payload[TAG_RAM_WIDTH-1:TAG_WIDTH];
    wire irom_req_array_hit = |irom_req_way_hit;

    wire [27:0] irom_req_refill_diff =
        irom_req_addr[31:4] ^ refill_buffer_line_addr_q;
    wire irom_req_refill_eq0 = ~|irom_req_refill_diff[5:0];
    wire irom_req_refill_eq1 = ~|irom_req_refill_diff[11:6];
    wire irom_req_refill_eq2 = ~|irom_req_refill_diff[17:12];
    wire irom_req_refill_eq3 = ~|irom_req_refill_diff[23:18];
    wire irom_req_refill_eq4 = ~|irom_req_refill_diff[27:24];
    wire irom_req_refill_block_valid =
        irom_req_block ? refill_buffer_filled_q[1]
                       : refill_buffer_filled_q[0];
    // 在一拍原子 Tag 提交期间保持刚完成的 line 可见。这个窗口内的请求
    // 使用 refill 缓冲，而不是针对尚未发布的 Tag 再发起一次重复缺失。
    wire refill_buffer_lookup_active =
        (refill_state_q == REFILL_DATA) | tag_commit_pending_q;
    wire irom_req_refill_hit =
        refill_buffer_lookup_active
        & irom_req_refill_block_valid
        & irom_req_refill_eq0 & irom_req_refill_eq1
        & irom_req_refill_eq2 & irom_req_refill_eq3
        & irom_req_refill_eq4;
    wire irom_req_hit = irom_req_array_hit | irom_req_refill_hit;

    always_ff @(posedge clk) begin
        if (!rst_n || irom_req_kill)
            lookup_valid_q <= 1'b0;
        else if (irom_req_fire)
            lookup_valid_q <= 1'b1;
        else if (lookup_valid_q)
            lookup_valid_q <= 1'b0;
    end

    // 命中、来源和地址元数据只由 lookup_valid_q 管理。冲刷只清除这一
    // 个所有权位，旧的 payload 因此不会产生响应。
    always_ff @(posedge clk) begin
        if (irom_req_fire) begin
            lookup_hit_q <= irom_req_hit;
            lookup_refill_hit_q <= irom_req_refill_hit;
            // 请求握手时预先计算这个宽地址比较。最后一拍 refill 的提交
            // 可能在下一周期可见，但请求地址和 refill line 地址不会改变。
            lookup_refill_line_match_q <=
                irom_req_refill_eq0 & irom_req_refill_eq1
                & irom_req_refill_eq2 & irom_req_refill_eq3
                & irom_req_refill_eq4;
            lookup_block_addr_q <= irom_req_addr[31:3];
            lookup_class_q <= irom_req_block
                            ? irom_req_line_class[11:6]
                            : irom_req_line_class[5:0];
        end
    end

    // ----------------------------------------------------------------
    // Refill 事务和部分 line 缓冲
    // ----------------------------------------------------------------

    wire mem_req_fire;
    wire mem_rd_fire;
    wire refill_block_complete =
        (refill_state_q == REFILL_DATA)
        & mem_rd_fire
        & refill_beat_q;
    wire [63:0] refill_block_data =
        refill_beat_q
            ? {mem_rd_data, refill_word0_q}
            : {32'd0, mem_rd_data};
    wire [13:0] refill_block_predecode;
    // RAMB36 的 parity 位继续保存每条指令原有的四个控制位；新增的
    // 三位指令类别先单独累积，再和压缩 Tag 一起原子提交。
    wire [7:0] refill_block_control = {
        refill_block_predecode[13:10],
        refill_block_predecode[6:3]
    };
    wire [BLOCK_CLASS_WIDTH-1:0] refill_block_class = {
        refill_block_predecode[9:7],
        refill_block_predecode[2:0]
    };
    wire [71:0] refill_block_payload = {
        refill_block_control,
        refill_block_data
    };
    wire [1:0] refill_block_resp =
        refill_block_resp_q | mem_rd_resp;
    assign refill_block_commit =
        refill_block_complete
        & ~refill_drop_q
        & ~irom_req_kill;

    // 通常空闲时，查找阶段刚发现的缺失可以直接启动，不必先复制到
    // pending_miss 再在 REFILL_IDLE 多停一拍。若旧 refill 仍在排空，
    // 才使用 pending 槽保存新缺失。
    wire launch_lookup_miss =
        (refill_state_q == REFILL_IDLE)
        & ~pending_miss_valid_q
        & lookup_miss
        & ~irom_req_kill;
    wire launch_pending_miss =
        (refill_state_q == REFILL_IDLE)
        & pending_miss_valid_q
        & ~irom_req_kill;
    wire launch_refill = launch_pending_miss | launch_lookup_miss;
    wire [28:0] launch_miss_block_addr =
        launch_pending_miss ? pending_miss_block_addr_q
                            : lookup_block_addr_q;
    wire [INDEX_WIDTH-1:0] launch_miss_index =
        launch_miss_block_addr[1 +: INDEX_WIDTH];
    wire [WAY_WIDTH-1:0] miss_replacement_way;
    generate
        if (WAYS == 1) begin : g_replace_one_way
            assign miss_replacement_way = '0;
        end else begin : g_replace_two_ways
            wire [LINE_SLOT_WIDTH-1:0] way0_slot =
                {1'b0, launch_miss_index};
            wire [LINE_SLOT_WIDTH-1:0] way1_slot =
                {1'b1, launch_miss_index};
            wire way0_valid = line_valid_q[way0_slot];
            wire way1_valid = line_valid_q[way1_slot];
            assign miss_replacement_way =
                !way0_valid ? 0
                : !way1_valid ? 1
                : replacement_way_q[launch_miss_index];
        end
    endgenerate

    wire [INDEX_WIDTH-1:0] refill_index =
        refill_line_addr_q[0 +: INDEX_WIDTH];
    wire [TAG_WIDTH-1:0] refill_tag =
        refill_line_addr_q[INDEX_WIDTH +: TAG_WIDTH];
    wire refill_in_window =
        refill_line_addr_q[27:16] == ICACHE_ADDR_PREFIX;
    wire [DATA_ROW_WIDTH-1:0] refill_data_row;
    wire [LINE_SLOT_WIDTH-1:0] refill_line_slot;
    wire [LINE_SLOT_WIDTH-1:0] tag_commit_line_slot;
    generate
        if (WAYS == 1) begin : g_refill_row_one_way
            assign refill_data_row = {refill_index, refill_block_q};
            assign refill_line_slot = refill_index;
            assign tag_commit_line_slot = tag_commit_index_q;
        end else begin : g_refill_row_two_ways
            assign refill_data_row = {
                refill_way_q[0], refill_index, refill_block_q
            };
            assign refill_line_slot = {refill_way_q[0], refill_index};
            assign tag_commit_line_slot = {
                tag_commit_way_q[0], tag_commit_index_q
            };
        end
    endgenerate
    wire refill_line_start = mem_req_fire;
    wire refill_cache_block_commit =
        refill_block_commit & refill_in_window;
    wire [1:0] refill_complete_resp =
        refill_line_resp_q | refill_block_resp;
    wire refill_line_complete =
        refill_block_commit
        & refill_second_block_q;
    wire refill_line_complete_ok =
        refill_line_complete
        & (refill_complete_resp == 2'b00)
        & refill_in_window;
    wire [LINE_CLASS_WIDTH-1:0] tag_commit_line_class = {
        refill_buffer_block1_class_q,
        refill_buffer_block0_class_q
    };

    // 这个译码器不在命中路径上，只处理已经完成的 64 位 refill block，
    // 并在写入 RAMB36 前产生预译码类别。
    loongarch_icache_block_predecode u_refill_predecode (
        .block_data     (refill_block_data),
        .block_metadata (refill_block_predecode)
    );

    wire [35:0] refill_block_slot0 = {
        refill_block_payload[67:64],
        refill_block_payload[31:0]
    };
    wire [35:0] refill_block_slot1 = {
        refill_block_payload[71:68],
        refill_block_payload[63:32]
    };

    // 每条 lane 的数据读取和 refill 写入保持为 BRAM 的两个独立端口。
    // 同行读写冲突是安全的，因为该行还没有 valid line；部分 line 缓冲
    // 会提供对应的 refill 数据。
    always_ff @(posedge clk) begin
        if (irom_req_fire) begin
            lookup_slot0_q <= data_mem_slot0[irom_req_data_row];
            lookup_slot1_q <= data_mem_slot1[irom_req_data_row];
        end
        if (refill_cache_block_commit) begin
            data_mem_slot0[refill_data_row] <= refill_block_slot0;
            data_mem_slot1[refill_data_row] <= refill_block_slot1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            line_valid_q <= '0;
        end else begin
            if (refill_line_start && refill_in_window)
                line_valid_q[refill_line_slot] <= 1'b0;
            if (tag_commit_pending_q) begin
                tag_mem[tag_commit_line_slot] <= {
                    tag_commit_line_class,
                    tag_commit_tag_q
                };
                line_valid_q[tag_commit_line_slot] <= 1'b1;
            end
        end
    end

    // 双路配置下，该位表示两路都有效时下一次应选择的 victim。无效 way
    // 总是优先分配，因此 payload 本身不需要复位；命中和成功填充会把
    // 另一条 way 标记为更旧。
    generate
        if (WAYS == 2) begin : g_replacement_state
            always_ff @(posedge clk) begin
                if (irom_req_fire && irom_req_array_hit)
                    replacement_way_q[irom_req_index]
                        <= ~irom_req_array_way[0];
                if (tag_commit_pending_q)
                    replacement_way_q[tag_commit_index_q]
                        <= ~tag_commit_way_q[0];
            end
        end
    endgenerate

    // 这里只复位 pending 位。index/Tag payload 会在真正可见之前被事件
    // 覆盖。最后一拍之后发生的重定向不会取消延迟提交，这和原设计中
    // line 已在最后一拍时钟沿变为有效的行为一致。
    always_ff @(posedge clk) begin
        if (!rst_n)
            tag_commit_pending_q <= 1'b0;
        else
            tag_commit_pending_q <= refill_line_complete_ok;

        if (refill_line_complete_ok) begin
            tag_commit_index_q <= refill_index;
            tag_commit_tag_q <= refill_tag;
            tag_commit_way_q <= refill_way_q;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || irom_req_kill)
            refill_buffer_filled_q <= 2'b00;
        else begin
            if (refill_line_start)
                refill_buffer_filled_q <= 2'b00;
            if (refill_block_commit)
                refill_buffer_filled_q[refill_block_q] <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (refill_line_start) begin
            refill_buffer_line_addr_q <= refill_line_addr_q;
            refill_line_resp_q <= 2'b00;
        end else if (refill_block_commit) begin
            refill_line_resp_q <= refill_line_resp_q | refill_block_resp;
        end

        if (refill_block_commit) begin
            if (refill_block_q) begin
                refill_buffer_block1_q <= refill_block_payload;
                refill_buffer_block1_class_q <= refill_block_class;
            end else begin
                refill_buffer_block0_q <= refill_block_payload;
                refill_buffer_block0_class_q <= refill_block_class;
            end
        end
    end

    // ----------------------------------------------------------------
    // 查找结果和前端响应
    // ----------------------------------------------------------------

    wire lookup_block = lookup_block_addr_q[0];
    // 最后一拍 refill 同时接受的请求可能采样到旧的 buffer-valid。下一拍
    // 从已寄存的 refill 状态恢复它，而不是把 AXI RVALID/RRESP 组合地
    // 接入 BP 命中路径。这样既保持原来的一拍命中响应和背靠背请求，
    // 又不会形成从存储总线直达前端的长时序路径。
    always_comb begin
        lookup_commit_hit =
            lookup_valid_q
            & tag_commit_pending_q
            & lookup_refill_line_match_q
            & (lookup_block
                   ? refill_buffer_filled_q[1]
                   : refill_buffer_filled_q[0]);
    end
    wire [71:0] lookup_refill_payload =
        lookup_block
            ? refill_buffer_block1_q
            : refill_buffer_block0_q;
    wire [BLOCK_CLASS_WIDTH-1:0] lookup_refill_class =
        lookup_block
            ? refill_buffer_block1_class_q
            : refill_buffer_block0_class_q;
    wire [71:0] lookup_hit_payload =
        (lookup_refill_hit_q | lookup_commit_hit)
            ? lookup_refill_payload
            : lookup_payload_q;
    wire [BLOCK_CLASS_WIDTH-1:0] lookup_hit_class =
        (lookup_refill_hit_q | lookup_commit_hit)
            ? lookup_refill_class
            : lookup_class_q;

    wire refill_matches_lookup =
        refill_block_commit
        & lookup_miss
        & (lookup_block_addr_q[28:1] == refill_line_addr_q)
        & (lookup_block_addr_q[0] == refill_block_q);
    wire refill_matches_pending =
        refill_block_commit
        & pending_miss_valid_q
        & (pending_miss_block_addr_q[28:1] == refill_line_addr_q)
        & (pending_miss_block_addr_q[0] == refill_block_q);
    wire refill_owner_response =
        refill_block_commit
        & refill_response_needed_q;
    wire refill_frontend_response =
        refill_owner_response
        | refill_matches_lookup
        | refill_matches_pending;

    always_ff @(posedge clk) begin
        if (!rst_n || irom_req_kill) begin
            pending_miss_valid_q <= 1'b0;
        end else begin
            if ((refill_state_q == REFILL_IDLE) && pending_miss_valid_q)
                pending_miss_valid_q <= 1'b0;
            if (refill_matches_pending)
                pending_miss_valid_q <= 1'b0;
            if (lookup_miss & ~refill_matches_lookup
                            & ~launch_lookup_miss) begin
                pending_miss_valid_q <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (lookup_miss & ~refill_matches_lookup)
            pending_miss_block_addr_q <= lookup_block_addr_q;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || irom_req_kill)
            miss_resp_valid_q <= 1'b0;
        else
            miss_resp_valid_q <= refill_frontend_response;
    end

    always_ff @(posedge clk) begin
        if (refill_frontend_response) begin
            miss_resp_payload_q <= refill_block_payload;
            miss_resp_class_q <= refill_block_class;
            miss_resp_resp_q <= refill_block_resp;
        end
    end

    assign irom_resp_valid = lookup_hit | miss_resp_valid_q;
    assign irom_resp_data =
        lookup_hit
            ? lookup_hit_payload[63:0]
            : miss_resp_payload_q[63:0];
    wire [7:0] response_control =
        lookup_hit
            ? lookup_hit_payload[71:64]
            : miss_resp_payload_q[71:64];
    wire [BLOCK_CLASS_WIDTH-1:0] response_class =
        lookup_hit ? lookup_hit_class : miss_resp_class_q;
    assign irom_resp_predecode = {
        response_control[7:4], response_class[5:3],
        response_control[3:0], response_class[2:0]
    };
    assign irom_resp_resp =
        lookup_hit
            ? 2'b00
            : miss_resp_resp_q;

    // ----------------------------------------------------------------
    // Refill 事务所有权
    // ----------------------------------------------------------------
    icache_refill_ctrl #(
        .WAY_WIDTH (WAY_WIDTH)
    ) u_refill_ctrl (
        .clk             (clk),
        .rst_n           (rst_n),
        .kill            (irom_req_kill),
        .launch          (launch_refill),
        .launch_block_addr(launch_miss_block_addr),
        .launch_way      (miss_replacement_way),
        .state           (refill_state_q),
        .line_addr       (refill_line_addr_q),
        .block           (refill_block_q),
        .way             (refill_way_q),
        .second_block    (refill_second_block_q),
        .response_needed (refill_response_needed_q),
        .drop            (refill_drop_q),
        .beat            (refill_beat_q),
        .first_word      (refill_word0_q),
        .block_resp_q    (refill_block_resp_q),
        .mem_req_valid   (mem_req_valid),
        .mem_req_ready   (mem_req_ready),
        .mem_req_addr    (mem_req_addr),
        .mem_req_len     (mem_req_len),
        .mem_req_burst   (mem_req_burst),
        .mem_rd_valid    (mem_rd_valid),
        .mem_rd_ready    (mem_rd_ready),
        .mem_rd_data     (mem_rd_data),
        .mem_rd_last     (mem_rd_last),
        .mem_rd_resp     (mem_rd_resp),
        .mem_req_fire    (mem_req_fire),
        .mem_rd_fire     (mem_rd_fire)
    );

`ifndef SYNTHESIS
    initial begin
        if ((CACHE_BYTES != 8192) && (CACHE_BYTES != 16384)
            && (CACHE_BYTES != 32768))
            $fatal(1, "ICache CACHE_BYTES must be 8192, 16384 or 32768");
        if ((WAYS != 1) && (WAYS != 2))
            $fatal(1, "ICache WAYS must be 1 or 2");
        if ((LINES % WAYS) != 0)
            $fatal(1, "ICache line count must divide evenly across ways");
    end

    always_ff @(posedge clk) begin
        if (rst_n && irom_req_fire && (irom_req_addr[2:0] != 3'b000))
            $error("ICache request address is not 64-bit aligned");
        if (rst_n
            && mem_rd_fire
            && !refill_drop_q
            && !irom_req_kill
            && (mem_rd_last !=
                (refill_second_block_q & refill_beat_q)))
            $error("ICache four-beat WRAP refill RLAST mismatch");
        if (rst_n && lookup_hit && miss_resp_valid_q)
            $error("ICache produced two frontend responses in one cycle");
        if (rst_n && refill_matches_lookup && refill_matches_pending)
            $error("ICache matched both lookup and pending miss owners");
        if (rst_n && irom_req_valid && (WAYS == 2)
            && (&irom_req_way_hit))
            $error("ICache duplicate tag addr=%08x set=%0d",
                   irom_req_addr, irom_req_index);
    end
`endif

endmodule
