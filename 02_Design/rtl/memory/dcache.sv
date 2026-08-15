// ============================================================
// 中文说明：实现写回写分配 DCache，包括命中访问、缺失 refill、脏行写回和未缓存访问。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：当前 NSCSCC 使用的 64 KiB 直接映射 DCache。
// 主要结构如下：
//   - 内部有一个与 cpu_top 的 EX/MEM 同步的请求寄存器；
//   - Tag 使用 LUTRAM 异步读取，在 EX 阶段比较，命中结果送入 EX/MEM；
//   - 数据使用同步 BRAM，地址在 EX 采样，数据在 MEM 阶段得到；
//   - cache line 为 32 字节，缺失时按关键字优先方式发起八拍 AXI WRAP 读取；
//   - load 缺失会保存脏 victim，并让写回和 refill 尽量并行；
//   - store 命中直接更新 cache word 并置脏；store 缺失先 refill，再合并写入字节；
//   - BRAM 紧邻读写的同字旁路处理连续 store-load，不依赖 store queue；
//   - 命中、refill 和未缓存 load 数据先并行格式化，再由末端选择器选出结果。
// ============================================================

module dcache #(
    // 完整 32 位地址仍然送往 AXI 和处理器的地址异常判断逻辑。
    // 下面的参数只描述 NSCSCC 固定的可缓存地址窗口，用来压缩内部 Tag。
    parameter logic [31:0] CACHE_ADDR_BASE = 32'h1C08_0000,
    parameter logic [31:0] CACHE_ADDR_MASK = 32'hFFF8_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // --- EX 阶段输入 ---
    input  logic        cpu_req,
    input  logic        cpu_wr,
    input  logic [31:0] cpu_addr,
    input  logic [16:0] cpu_lookup_addr, // 来自 LSU 短地址加法器的 addr[18:2]
    input  logic [ 3:0] cpu_wea,
    input  logic [31:0] cpu_wdata,       // 原始数据，在 EX->MEM 寄存器后对齐
    input  logic [ 1:0] cpu_load_size,
    input  logic        cpu_load_unsigned,
    input  logic        cpu_uncached,

    // --- MEM 阶段输出 ---
    output logic [31:0] cpu_rdata,
    // 给远端 EX load 修复寄存器使用的物理独立副本。
    output logic [31:0] cpu_rdata_ex,
    output logic        cpu_ready,

    // 流水线同步信号
    input  logic        pipeline_stall,  // 来自 cpu_top：~mem_allowin（保持 EX->MEM 同步）

    // 流水线冲刷信号
    input  logic        flush,

    // 外部存储后端接口。命令和写数据使用独立的 ready/valid 通道，
    // 因此 cache line 写回仍然可以按 32 位 beat 连续发送。
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic        mem_req_write,
    // 只有脏 cache line 淘汰命令会置位该属性。NSCSCC 仲裁器据此允许
    // 写回和读请求重叠；未缓存/MMIO 写仍保持强串行。
    output logic        mem_req_writeback,
    output logic [31:0] mem_req_addr,
    output logic [ 7:0] mem_req_len,
    output logic [ 1:0] mem_req_burst,

    output logic        mem_w_valid,
    input  logic        mem_w_ready,
    output logic [31:0] mem_w_data,
    output logic [ 3:0] mem_w_strb,
    output logic        mem_w_last,

    input  logic        mem_rd_valid,
    output logic        mem_rd_ready,
    input  logic [31:0] mem_rd_data,
    input  logic        mem_rd_last,
    input  logic [ 1:0] mem_rd_resp,
    output logic        mem_rd_cancel,

    input  logic        mem_wr_valid,
    output logic        mem_wr_ready,
    input  logic [ 1:0] mem_wr_resp
);

    // ================================================================
    //  参数及地址窗口
    // ================================================================
    localparam SETS       = 2048;
    localparam LINE_WORDS = 8;
    // CACHE_ADDR_MASK 固定地址的 addr[31:19]。对于已经用完整地址
    // 判定为可缓存的请求，内部 Tag 只需保存 addr[18:16]。
    localparam TAG_W      = 3;
    localparam INDEX_W    = 11;   // addr[15:5]
    localparam WORD_W     = 3;    // addr[4:2]
    // Tag 分成八个物理 bank，在 LUTRAM 深度和末端 bank 选择之间折中。
    // 每个 bank 包含 256 个直接映射组。
    localparam TAG_BANK_BITS    = 3;
    localparam TAG_BANKS        = 1 << TAG_BANK_BITS;
    localparam TAG_BANK_INDEX_W = INDEX_W - TAG_BANK_BITS;
    localparam TAG_BANK_SETS    = SETS / TAG_BANKS;
    localparam logic [12:0] CACHE_ADDR_PREFIX = CACHE_ADDR_BASE[31:19];

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

    function automatic [31:0] format_load_data (
        input logic [31:0] raw_data,
        input logic [ 1:0] addr_low,
        input logic [ 1:0] load_size,
        input logic        load_unsigned
    );
        begin
    // 地址低位和访问大小一起参与选择，避免先做可变移位、再做大小选择
    // 和符号扩展的串行组合路径。
            case ({load_size, addr_low})
                4'b00_00: format_load_data = {
                    {24{raw_data[7] & ~load_unsigned}}, raw_data[7:0]
                };
                4'b00_01: format_load_data = {
                    {24{raw_data[15] & ~load_unsigned}}, raw_data[15:8]
                };
                4'b00_10: format_load_data = {
                    {24{raw_data[23] & ~load_unsigned}}, raw_data[23:16]
                };
                4'b00_11: format_load_data = {
                    {24{raw_data[31] & ~load_unsigned}}, raw_data[31:24]
                };
                4'b01_00: format_load_data = {
                    {16{raw_data[15] & ~load_unsigned}}, raw_data[15:0]
                };
                4'b01_01: format_load_data = {
                    {16{raw_data[23] & ~load_unsigned}}, raw_data[23:8]
                };
                4'b01_10: format_load_data = {
                    {16{raw_data[31] & ~load_unsigned}}, raw_data[31:16]
                };
                // 逻辑左移 24 位后，shifted[15:8] 被置零。
                4'b01_11: format_load_data = {24'd0, raw_data[31:24]};
                4'b10_00: format_load_data = raw_data;
                4'b10_01: format_load_data = {8'd0, raw_data[31:8]};
                4'b10_10: format_load_data = {16'd0, raw_data[31:16]};
                4'b10_11: format_load_data = {24'd0, raw_data[31:24]};
                default:  format_load_data = 32'd0;
            endcase
        end
    endfunction

`ifndef SYNTHESIS
    // 这是原串行格式化器的参考模型。请求寄存边界上的断言覆盖所有
    // 地址低位和访问大小组合，防止并行格式化产生语义变化。
    function automatic [31:0] format_load_data_reference (
        input logic [31:0] raw_data,
        input logic [ 1:0] addr_low,
        input logic [ 1:0] load_size,
        input logic        load_unsigned
    );
        logic [31:0] shifted;
        begin
            case (addr_low)
                2'd0: shifted = raw_data;
                2'd1: shifted = { 8'd0, raw_data[31:8]};
                2'd2: shifted = {16'd0, raw_data[31:16]};
                default: shifted = {24'd0, raw_data[31:24]};
            endcase
            case (load_size)
                2'b00: format_load_data_reference = {
                    {24{shifted[7] & ~load_unsigned}}, shifted[7:0]
                };
                2'b01: format_load_data_reference = {
                    {16{shifted[15] & ~load_unsigned}}, shifted[15:0]
                };
                2'b10: format_load_data_reference = shifted;
                default: format_load_data_reference = 32'd0;
            endcase
        end
    endfunction
`endif

    // ================================================================
    //  EX 阶段地址拆分
    // ================================================================
    wire [TAG_W-1:0]   ex_tag   = cpu_lookup_addr[16:14];
    wire [INDEX_W-1:0] ex_index = cpu_lookup_addr[13:3];
    wire [WORD_W-1:0]  ex_word  = cpu_lookup_addr[2:0];

    // ================================================================
    //  内部 EX->MEM 请求寄存器（与 cpu_top 的 ex_mem_reg 同步）
    // ================================================================
    logic [TAG_W-1:0]   mem_tag;
    logic [INDEX_W-1:0] mem_index;
    logic [WORD_W-1:0]  mem_word;
    logic [31:0]        mem_addr;
    logic               mem_req;
    logic               mem_wr;
    logic [ 3:0]        mem_wea;
    logic [31:0]        mem_wdata;
    logic [ 1:0]        mem_load_size;
    logic               mem_load_unsigned;
    logic               mem_uncached;

    // pipeline_advance 必须和 cpu_top 的 mem_allowin 完全一致，才能让
    // DCache 内部 EX->MEM 请求寄存器与 cpu_top 的 ex_mem_reg 同步。
    // 注意：这里不能再加“| flush”。当前 MEM 指令在冲刷时仍需按
    // ex_mem_reg 的规则保持，两个寄存器必须同时停住或同时前进。
    wire pipeline_advance = ~pipeline_stall;

    always_ff @(posedge clk) begin
        if (!rst_n)
            mem_req <= 1'b0;
        else if (pipeline_advance)
            mem_req <= cpu_req & ~flush;
    end

    // mem_req_valid 是 EX/MEM 请求载荷的唯一所有权标志。因此冲刷和复位
    // 只需要清它；正常前进时，它同时作为载荷寄存器的时钟使能。
    always_ff @(posedge clk) begin
        if (pipeline_advance) begin
            mem_tag   <= ex_tag;
            mem_index <= ex_index;
            mem_word  <= ex_word;
            mem_addr  <= cpu_addr;
            mem_wr    <= cpu_wr;
            mem_wea   <= cpu_wea;
            mem_wdata <= cpu_wdata;
            mem_load_size <= cpu_load_size;
            mem_load_unsigned <= cpu_load_unsigned;
            mem_uncached <= cpu_uncached;
        end
    end

    // ================================================================
    //  状态机类型和信号（提前声明以兼容仿真器）
    // ================================================================
    typedef enum logic [3:0] {
        S_IDLE,
S_REFILL_REQ,     // 向后端发出 line 读请求
S_REFILL_DATA,    // 接收后端返回的 line 数据 beat
S_REFILL_DROP,    // 流水线冲刷后排空已中止的 refill
        S_DONE,
S_REPLAY,         // 重新读取因 WB miss 使用 Port B 而暂存的请求
S_WB_CAPTURE,     // 将八个 victim word 读入本地 line 缓冲
S_WB_REQ,         // 发出一条八 beat 写回命令
S_WB_JOIN_DONE,   // refill 已安装，等待脏行写回成功
S_WB_JOIN_IDLE,   // refill 被冲刷，等待脏行写回成功
S_UC_REQ,         // 发出一条未缓存读/写命令
S_UC_READ,        // 等待未缓存读 beat
S_UC_WRITE_DATA,  // 发送单个未缓存写 beat
S_UC_WRITE_RESP   // 等待未缓存写响应
    } state_t;

    (* fsm_encoding = "one_hot" *) state_t state;
    state_t state_next;
    wire state_idle          = (state == S_IDLE);
    wire state_refill_req    = (state == S_REFILL_REQ);
    wire state_refill_data   = (state == S_REFILL_DATA);
    wire state_refill_drop   = (state == S_REFILL_DROP);
    wire state_done          = (state == S_DONE);
    wire state_replay        = (state == S_REPLAY);
    wire state_wb_capture    = (state == S_WB_CAPTURE);
    wire state_wb_req        = (state == S_WB_REQ);
    wire state_wb_join_done  = (state == S_WB_JOIN_DONE);
    wire state_wb_join_idle  = (state == S_WB_JOIN_IDLE);
    wire state_uc_req        = (state == S_UC_REQ);
    wire state_uc_read       = (state == S_UC_READ);
    wire state_uc_write_data = (state == S_UC_WRITE_DATA);
    wire state_uc_write_resp = (state == S_UC_WRITE_RESP);
    wire refill_start;
    logic [WORD_W-1:0]  refill_beat;  // 已接收的数据 beat 数（0..LINE_WORDS-1）
    wire                refill_data_fire; // 当前周期接受了后端数据
    logic [TAG_W-1:0]   refill_tag;
    logic [INDEX_W-1:0] refill_index;
    logic [31:0]        refill_fetch_addr;
    logic [WORD_W-1:0]  refill_target_word;
    logic               refill_is_store;
    logic [31:0]        refill_store_data;
    logic [ 3:0]        refill_store_wea;
    logic [31:0]        victim_line_addr;
    wire  [WORD_W-1:0]  refill_word;
    wire [INDEX_W+WORD_W-1:0] refill_write_addr;
    wire                refill_cache_write;
    logic               refill_cpu_pending;
    wire                refill_target_fire;
    wire                refill_cpu_ready;

    // 脏 victim 在 B 响应成功前一直占用 line_buffer。refill 数据直接写入
    // 选中的 BRAM，因此读写可以分别推进，不需要第二个 cache line 缓冲区。
    typedef enum logic [1:0] {
        WB_IDLE,
        WB_CMD,
        WB_DATA,
        WB_RESP
    } wb_state_t;
    wb_state_t wb_state;
    wire wb_state_cmd  = (wb_state == WB_CMD);
    wire wb_state_data = (wb_state == WB_DATA);
    wire wb_state_resp = (wb_state == WB_RESP);
    logic wb_required;
    logic wb_done;
    logic refill_read_accepted;
    wire refill_complete;
    wire refill_req_fire;

    // ================================================================
    //  Tag RAM（LUTRAM，异步读取）
    // ================================================================
    // 直接映射 Tag 数组拆成八个、每个 256 组的物理 bank。所有 bank
    // 并行读取低位组索引；高三位和请求一起寄存，只在 MEM 阶段完成最终选择。
    wire [TAG_BANK_BITS-1:0] refill_tag_bank =
        refill_index[INDEX_W-1 -: TAG_BANK_BITS];
    wire [TAG_BANK_INDEX_W-1:0] refill_tag_set =
        refill_index[TAG_BANK_INDEX_W-1:0];

    wire [TAG_W:0] tag_rd_entry [TAG_BANKS-1:0];
    wire [TAG_W-1:0] tag_rd_data [TAG_BANKS-1:0];
    wire tag_rd_vld [TAG_BANKS-1:0];

    // valid 和 Tag 一起存放在 LUTRAM 中。复位后的前 256 个周期并行清空
    // 所有物理 bank；非访存流水可以继续，第一条访存请求会等清空和一次
    // 重放读取完成后再继续。
    logic [TAG_BANK_INDEX_W-1:0] tag_init_set;
    logic tag_init_done;
    logic tag_init_release_q;
    wire tag_init_replay = tag_init_done & ~tag_init_release_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tag_init_set       <= '0;
            tag_init_done      <= 1'b0;
            tag_init_release_q <= 1'b0;
        end else begin
            if (!tag_init_done) begin
                if (tag_init_set
                    == TAG_BANK_INDEX_W'(TAG_BANK_SETS - 1))
                    tag_init_done <= 1'b1;
                else
                    tag_init_set <= tag_init_set + 1'b1;
            end
            // 最后一笔 LUTRAM 清空写入后的下一个周期，重放初始化期间
            // 已经进入 MEM 的请求。
            tag_init_release_q <= tag_init_done;
        end
    end

    wire tag_lookup_from_mem = state_replay | tag_init_replay;
    wire [TAG_BANK_INDEX_W-1:0] tag_read_set_source =
        tag_lookup_from_mem
        ? mem_index[TAG_BANK_INDEX_W-1:0]
        : ex_index[TAG_BANK_INDEX_W-1:0];

    generate
        for (genvar tag_bank = 0;
             tag_bank < TAG_BANKS;
             tag_bank++) begin : g_tag_bank
            (* ram_style = "distributed" *)
            logic [TAG_W:0] tag_mem [0:TAG_BANK_SETS-1];

            wire [TAG_BANK_INDEX_W-1:0] tag_read_set =
                tag_read_set_source;
            assign tag_rd_entry[tag_bank] = tag_mem[tag_read_set];
            assign tag_rd_data[tag_bank] =
                tag_rd_entry[tag_bank][TAG_W-1:0];
            assign tag_rd_vld[tag_bank] = tag_rd_entry[tag_bank][TAG_W];

            // 每个物理存储器每周期只做一次按索引写入，保持单写端口
            // LUTRAM 模板。refill 完成对 Tag 的提交优先于失效操作。
            always_ff @(posedge clk) begin
                if (rst_n) begin
                    if (!tag_init_done)
                        tag_mem[tag_init_set] <= '0;
                    else if (refill_complete
                        && (refill_tag_bank
                            == TAG_BANK_BITS'(tag_bank)))
                        tag_mem[refill_tag_set] <= {1'b1, refill_tag};
                    else if (refill_req_fire
                        && (refill_tag_bank
                            == TAG_BANK_BITS'(tag_bank)))
                        tag_mem[refill_tag_set] <= '0;
                end
            end
        end
    endgenerate

    // Dirty 元数据只有一个异步查询端口，每周期最多进行一次逻辑更新。
    // tag valid 会屏蔽所有未分配表项，因此不需要复位。
    (* ram_style = "distributed" *)
    logic dirty [0:SETS-1];

    // 捕获每个物理 bank 的原始 Tag 和 valid。已寄存的高位索引在 MEM
    // 阶段选择架构地址对应的候选；Tag 比较也放在寄存器之后，避免把
    // 比较器串在 EX 地址计算和 LUTRAM 异步读取之后。
    logic [TAG_W-1:0] mem_tag_rd_bank [TAG_BANKS-1:0];
    logic mem_tag_vld_bank [TAG_BANKS-1:0];

`ifndef SYNTHESIS
    // 原单表查找逻辑的可执行参考模型。它在时钟沿之前选择目标 bank，
    // 必须和新的末端选择结果保持一致。
    wire [TAG_BANK_BITS-1:0] tag_lookup_bank = tag_lookup_from_mem
        ? mem_index[INDEX_W-1 -: TAG_BANK_BITS]
        : ex_index[INDEX_W-1 -: TAG_BANK_BITS];
    wire [TAG_W-1:0] tag_lookup_tag = tag_lookup_from_mem
        ? mem_tag : ex_tag;
    wire lookup_hit_reference =
        tag_rd_vld[tag_lookup_bank]
        & (tag_rd_data[tag_lookup_bank] == tag_lookup_tag);
    logic mem_hit_reference;
`endif

    always_ff @(posedge clk) begin
        if (pipeline_advance | state_replay | tag_init_replay) begin
            for (int capture_bank = 0;
                 capture_bank < TAG_BANKS;
                 capture_bank++) begin
                mem_tag_rd_bank[capture_bank]
                    <= tag_rd_data[capture_bank];
                mem_tag_vld_bank[capture_bank]
                    <= tag_rd_vld[capture_bank];
            end
`ifndef SYNTHESIS
            mem_hit_reference <= lookup_hit_reference;
`endif
        end
    end

    // ================================================================
    //  命中结果（MEM 阶段）
    //
    //  每个 bank 的原始 Tag 和 valid 分别在寄存器处结束。这里先用已
    //  寄存的高位组索引选择一个候选，再进行很窄的 3-bit Tag 比较。
    //  比较发生在 MEM 周期，不增加 Cache 的查询周期数。
    // ================================================================
    wire [TAG_BANK_BITS-1:0] mem_tag_bank =
        mem_index[INDEX_W-1 -: TAG_BANK_BITS];
    wire [TAG_W-1:0] mem_tag_rd = mem_tag_rd_bank[mem_tag_bank];
    wire mem_tag_vld = mem_tag_vld_bank[mem_tag_bank];
    wire mem_tag_match = mem_tag_rd == mem_tag;
    wire tag_hit = mem_tag_vld & mem_tag_match;
    // mem_uncached 来自 memory_access_unit 对完整 32 位地址窗口的判断，
    // 它具有最终权威性。即使窗口外地址与压缩 Tag/index 相同，也不能命中
    // 或改变替换状态。
    wire cache_hit = ~mem_uncached & tag_hit;

    // ================================================================
    //  数据 RAM——一个逻辑上的 16384x32 BRAM bank
    // ================================================================
    logic [31:0] data_rd;
    logic [31:0] line_buffer [0:LINE_WORDS-1];
    logic [WORD_W:0] wb_read_issue_count;
    logic [WORD_W-1:0] wb_read_capture_count;
    logic               wb_read_valid_q;
    logic [WORD_W-1:0]  wb_send_beat;

    wire wb_read_issue = state_wb_capture
                       & (wb_read_issue_count
                          < (WORD_W + 1)'(LINE_WORDS));
    wire wb_capture_fire = state_wb_capture & wb_read_valid_q;
    wire wb_capture_last = wb_capture_fire
                         & (wb_read_capture_count
                            == WORD_W'(LINE_WORDS - 1));
    wire [INDEX_W+WORD_W-1:0] wb_read_addr = {
        refill_index, wb_read_issue_count[WORD_W-1:0]
    };
    wire [31:0] wb_selected_data = data_rd;

    wire [INDEX_W+WORD_W-1:0] data_rd_addr = {ex_index, ex_word};
    wire [INDEX_W+WORD_W-1:0] replay_read_addr = {mem_index, mem_word};
    wire [INDEX_W+WORD_W-1:0] data_bram_rd_addr =
        wb_read_issue ? wb_read_addr
      : (state_replay | tag_init_replay) ? replay_read_addr
                      : data_rd_addr;

    // BRAM 写端口信号（统一 MUX，稍后定义）。
    wire  [ 3:0] data_bram_wea;
    wire  [INDEX_W+WORD_W-1:0] data_bram_waddr;
    wire  [31:0] data_bram_wdata;

    // victim 捕获和重放是只在 miss 时使用的、已经寄存的地址候选。
    // 普通 load 命中时序仍然只观察原始流水线地址。
    wire data_bram_rd_en = pipeline_advance | wb_read_issue | state_replay
                          | tag_init_replay;

    // 使用 BRAM 原生 ENB 保持输出，不把较晚的流水线 ready 响应 MUX 到每个
    // 地址位。地址仍在与原来完全相同的时钟沿采样，但 AXI 写完成现在在
    // 局部使能处结束，不再进入 14 位地址路径。

    // 原始 BRAM 输出直接作为 data_rd。
    // BRAM 固有一拍读延迟，与原来的 FF 行为一致。

    dcache_data_ram u_data (
        .clka  (clk),
        .wea   (data_bram_wea),
        .addra (data_bram_waddr),
        .dina  (data_bram_wdata),
        .clkb  (clk),
        .enb   (data_bram_rd_en),
        .addrb (data_bram_rd_addr),
        .doutb (data_rd)
    );

    wire  [31:0] refill_write_data;
    logic        refill_target_valid;
    logic [31:0] refill_target_data;
    logic        raw_bypass_valid;
    logic [31:0] raw_bypass_data;
    logic [ 3:0] raw_bypass_wea;

    // 直接映射使被寻址表项成为唯一 victim 候选。
    // Dirty 元数据仍不进入普通命中结果逻辑锥。
    wire victim_valid_candidate = mem_tag_vld;
    wire victim_dirty_candidate = dirty[mem_index];
    wire [TAG_W-1:0] victim_tag_candidate = mem_tag_rd;
    wire victim_needs_writeback = victim_valid_candidate
                                & victim_dirty_candidate;

    // NSCSCC 构建始终使用通用流式 AXI 后端。
    wire        backend_req_ready = mem_req_ready;
    wire        backend_rd_valid  = mem_rd_valid;
    wire [31:0] backend_rd_data   = mem_rd_data;
    wire        backend_rd_last   = mem_rd_last;
    wire        backend_rd_ready  = state_refill_data | state_refill_drop
                                  | state_uc_read;
    wire        backend_wr_valid  = mem_wr_valid;
    wire        backend_wr_ready  = wb_state_resp | state_uc_write_resp;

    // 字节对齐延后到内部 EX->MEM 寄存器之后，避免可变移位进入 CPU
    // ALU 的地址计算路径。
    wire [31:0] mem_wdata_aligned = mem_wdata << {mem_addr[1:0], 3'b0};
    wire [3:0] refill_store_merge_wea =
        (refill_is_store & (refill_word == refill_target_word))
        ? refill_store_wea : 4'b0000;
    assign refill_write_data = merge_bytes(
        backend_rd_data, refill_store_data, refill_store_merge_wea
    );
    // ================================================================
    //  状态机——可变延迟 refill/store 后端
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= state_next;
    end

    // store 缺失会被保存为当前唯一的缺失请求，并允许 store 尽快提交；
    // 后续访存要等 write-allocate refill 完成后才能继续。
    // Tag LUTRAM 清空期间，空闲 MEM 仍可能接收请求；请求会停在 S_IDLE，
    // 等初始化重放产生可信的 Tag 和数据候选。
    wire idle_mem_req = state_idle & mem_req & tag_init_release_q;
    wire idle_uncached = idle_mem_req & mem_uncached;
    wire idle_load    = idle_mem_req & ~mem_uncached & ~mem_wr;
    wire idle_store   = idle_mem_req & ~mem_uncached &  mem_wr;
    wire idle_store_accept = idle_store;

    wire idle_load_hit   = idle_load &  cache_hit;
    wire idle_load_miss  = idle_load & ~cache_hit;
    wire idle_store_hit  = idle_store &  cache_hit;
    wire idle_store_miss = idle_store & ~cache_hit;
    wire store_hit_accept = idle_store_hit;
    wire idle_refill_start = idle_load_miss | idle_store_miss;
    wire idle_uncached_start = idle_uncached;
    assign refill_start = idle_refill_start;

    // 已经握手接受的 AXI 读不能取消。被冲刷的 load 会继续接收剩余返回
    // 但不安装到 cache；store 分配必须完整完成。
    wire refill_abort = flush & ~refill_is_store;
    wire refill_data_last = refill_data_fire & (refill_beat == WORD_W'(LINE_WORDS - 1));
    assign refill_complete = refill_data_last & ~refill_abort;
    assign refill_word = refill_target_word + refill_beat;
    assign refill_target_fire = refill_data_fire
                              & refill_cpu_pending
                              & (refill_word == refill_target_word)
                              & ~refill_abort;
    wire refill_drop_done = state_refill_drop & backend_rd_valid & backend_rd_ready & backend_rd_last;
    wire wb_req_fire = wb_state_cmd & backend_req_ready;
    wire wb_data_fire = wb_state_data & mem_w_ready;
    wire wb_data_last_fire = wb_data_fire
                           & (wb_send_beat == WORD_W'(LINE_WORDS - 1));
    wire wb_resp_fire = wb_state_resp & backend_wr_valid
                      & backend_wr_ready;
    wire wb_resp_ok = wb_resp_fire & (mem_wr_resp == 2'b00);
    wire writeback_complete_now = ~wb_required | wb_done | wb_resp_ok;
    // 如果重试写回命令和仍在等待的 refill 命令同周期出现，优先重试写回。
    assign refill_req_fire = state_refill_req & ~wb_state_cmd
                           & backend_req_ready;
    // refill_cpu_pending 还会记住与不可取消写回命令握手同周期发生的
    // 一拍冲刷。
    wire refill_cancel_before_read = ~refill_is_store
                                   & (refill_abort | ~refill_cpu_pending);
    wire uc_req_fire = state_uc_req & backend_req_ready;
    wire uc_read_fire = state_uc_read & backend_rd_valid
                     & backend_rd_ready & backend_rd_last;
    wire uc_write_data_fire = state_uc_write_data & mem_w_ready;
    wire uc_write_fire = state_uc_write_resp & backend_wr_valid
                      & backend_wr_ready;

    always_comb begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (idle_uncached_start)
                    state_next = S_UC_REQ;
                else if (idle_refill_start) begin
                    if (victim_needs_writeback)
                        state_next = S_WB_CAPTURE;
                    else
                        state_next = S_REFILL_REQ;
                end
            end

            S_REFILL_REQ: begin
                if (refill_req_fire) begin
                    if (refill_abort)
                        state_next = S_REFILL_DROP;
                    else
                        state_next = S_REFILL_DATA;
                end
                else if (refill_cancel_before_read) begin
                    if (wb_required & ~writeback_complete_now)
                        state_next = S_WB_JOIN_IDLE;
                    else
                        state_next = S_IDLE;
                end
            end

            S_REFILL_DATA: begin
                if (refill_abort)
                    // 后端事务不可取消；如果 flush 与最后一个已接受 beat 同周期，
                    // 已经没有可丢弃的事务。
                    if (refill_data_last) begin
                        if (writeback_complete_now)
                            state_next = S_IDLE;
                        else
                            state_next = S_WB_JOIN_IDLE;
                    end
                    else
                        state_next = S_REFILL_DROP;
                else if (refill_data_last) begin
                    if (writeback_complete_now)
                        state_next = S_DONE;
                    else
                        state_next = S_WB_JOIN_DONE;
                end
            end

            S_REFILL_DROP: begin
                if (refill_drop_done) begin
                    if (writeback_complete_now)
                        state_next = S_IDLE;
                    else
                        state_next = S_WB_JOIN_IDLE;
                end
            end

            S_DONE: begin
                if (mem_req)
                    state_next = S_REPLAY;
                else
                    state_next = S_IDLE;
            end
            S_REPLAY:
                state_next = S_IDLE;
            S_WB_CAPTURE: begin
                if (refill_abort)
                    // 还没有外部写命令，因此被冲刷的 load 可以保留原来的脏 cache line。
                    state_next = S_IDLE;
                else if (wb_capture_last)
                    state_next = S_WB_REQ;
            end
            S_WB_REQ: begin
                if (wb_req_fire)
                    // 写事务一旦被接受，就不能取消。
                    state_next = S_REFILL_REQ;
                else if (refill_abort)
                    state_next = S_IDLE;
            end
            S_WB_JOIN_DONE: begin
                if (writeback_complete_now)
                    state_next = S_DONE;
            end
            S_WB_JOIN_IDLE: begin
                if (writeback_complete_now)
                    state_next = S_IDLE;
            end
            S_UC_REQ: begin
                if (uc_req_fire) begin
                    if (mem_wr)
                        state_next = S_UC_WRITE_DATA;
                    else
                        state_next = S_UC_READ;
                end
            end
            S_UC_READ: begin
                if (uc_read_fire)
                    state_next = S_IDLE;
            end
            S_UC_WRITE_DATA: begin
                if (uc_write_data_fire)
                    state_next = S_UC_WRITE_RESP;
            end
            S_UC_WRITE_RESP: begin
                if (uc_write_fire)
                    state_next = S_IDLE;
            end
            default:
                state_next = S_IDLE;
        endcase
    end

    // 脏行写回命令一旦接受就是独立事务。B 响应失败时重放同一条已缓存的
    // 命令和数据；flush 可以丢弃 load refill，但不能丢弃已经接受的内存副作用，
    // 也不能丢弃 victim line 唯一仍然存在的副本。
    always_ff @(posedge clk) begin
        if (!rst_n)
            wb_state <= WB_IDLE;
        else if (refill_start)
            wb_state <= WB_IDLE;
        else begin
            case (wb_state)
                WB_IDLE: begin
                    if (wb_capture_last & ~refill_abort)
                        wb_state <= WB_CMD;
                end
                WB_CMD: begin
                    if (wb_req_fire)
                        wb_state <= WB_DATA;
                    else if (state_wb_req & refill_abort)
                        wb_state <= WB_IDLE;
                end
                WB_DATA: begin
                    if (wb_data_last_fire)
                        wb_state <= WB_RESP;
                end
                WB_RESP: begin
                    if (wb_resp_fire) begin
                        if (mem_wr_resp == 2'b00)
                            wb_state <= WB_IDLE;
                        else
                            wb_state <= WB_CMD;
                    end
                end
                default:
                    wb_state <= WB_IDLE;
            endcase
        end
    end

    // 这些是所有权/进度位，不是 payload。它们是连接独立完成的读写路径所需的
    // 唯一新增状态。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_required <= 1'b0;
            wb_done <= 1'b0;
            refill_read_accepted <= 1'b0;
        end else if (refill_start) begin
            wb_required <= victim_needs_writeback;
            wb_done <= 1'b0;
            refill_read_accepted <= 1'b0;
        end else begin
            if (wb_resp_ok)
                wb_done <= 1'b1;
            if (refill_req_fire)
                refill_read_accepted <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (refill_start) begin
            refill_beat         <= '0;
            refill_tag          <= mem_tag;
            refill_index        <= mem_index;
            refill_fetch_addr   <= {mem_addr[31:5], mem_word, 2'b00};
            refill_target_word  <= mem_word;
            refill_is_store     <= mem_wr;
            refill_store_data   <= mem_wdata_aligned;
            refill_store_wea    <= mem_wea;
            victim_line_addr    <= {
                CACHE_ADDR_PREFIX, victim_tag_candidate,
                mem_index, 5'b00000
            };
            refill_cpu_pending  <= ~mem_wr;
            refill_target_valid <= 1'b0;
            refill_target_data  <= 32'd0;
        end else begin
            if (refill_data_fire) begin
                refill_beat <= refill_beat + 1'b1;
                if (refill_word == refill_target_word) begin
                    refill_target_valid <= 1'b1;
                    refill_target_data  <= refill_write_data;
                end
            end
            if (refill_cpu_ready | refill_abort | refill_drop_done | state_done)
                refill_cpu_pending <= 1'b0;
        end
    end

    assign refill_data_fire = state_refill_data & backend_rd_valid & backend_rd_ready;

    // 这 8 个本地字在 B 成功前独占保存脏 victim 的快照。Port B 是同步端口，
    // 因此 valid_q 将每个已寄存的 RAM 结果与捕获索引对齐。refill beat 永远
    // 不会覆盖这个缓冲区。
    always_ff @(posedge clk) begin
        if (refill_start) begin
            wb_read_issue_count   <= '0;
            wb_read_capture_count <= '0;
            wb_read_valid_q       <= 1'b0;
            wb_send_beat          <= '0;
        end else begin
            if (state_wb_capture) begin
                wb_read_valid_q <= wb_read_issue;
                if (wb_read_issue)
                    wb_read_issue_count <= wb_read_issue_count + 1'b1;
                if (wb_capture_fire) begin
                    line_buffer[wb_read_capture_count] <= wb_selected_data;
                    wb_read_capture_count <= wb_read_capture_count + 1'b1;
                end
            end else begin
                wb_read_valid_q <= 1'b0;
            end

            if (wb_req_fire)
                wb_send_beat <= '0;
            else if (wb_data_fire & ~wb_data_last_fire)
                wb_send_beat <= wb_send_beat + 1'b1;

        end
    end

    // ================================================================
    //  Data RAM 写入：供 BRAM IP 使用的统一写端口 MUX。
    //  refill 和 store 由状态机保证互斥，因此共用 Port A。
    // ================================================================
    assign refill_write_addr = {refill_index, refill_word};
    wire [INDEX_W+WORD_W-1:0] store_data_addr    = {mem_index, mem_word};

    // store 命中更新选中的 cache word；store miss 在 write-allocate refill
    // 期间合并到关键字。
    wire        store_cache_write = store_hit_accept;
    wire [INDEX_W+WORD_W-1:0] store_cache_write_addr = store_data_addr;
    wire [31:0] store_cache_write_data = mem_wdata_aligned;
    wire [ 3:0] store_cache_write_wea = mem_wea;

    // refill 写入：每接受一个后端读 beat，就写入一次 cache data RAM。
    assign refill_cache_write = refill_data_fire;

    // 统一 BRAM 写端口 MUX。
    // 优先级：refill > store（FSM 保证两者互斥）。
    assign data_bram_wea = refill_cache_write ? 4'b1111
                         : store_cache_write ? store_cache_write_wea
                                             : 4'b0000;
    assign data_bram_waddr = refill_cache_write ? refill_write_addr
                           : store_cache_write ? store_cache_write_addr
                                               : '0;
    assign data_bram_wdata = refill_cache_write ? refill_write_data
                           : store_cache_write ? store_cache_write_data
                                               : 32'd0;

    // ================================================================
    //  一拍 BRAM 写后读冲突旁路。
    //
    //  在 store 位于 MEM、load 位于 EX 的周期，直接比较完整的对齐字地址。
    //  如果物理字匹配，它一定选择与已确认 store 命中相同的 cache way，
    //  因此不需要等待年轻 load 的 tag-RAM 查询。
    //
    //  payload 寄存器无条件写入。先在不经过末级 request/flush 逻辑锥的情况下
    //  捕获无害的同字候选，再由下面已寄存的 MEM 阶段 load token 决定是否使用。
    // ================================================================
    // 旁路两侧都来自可缓存地址，因此共享平台定义的 addr[31:19] 前缀。
    // 只比较由并行短地址加法器产生的 cache word 标识；分成三个六位分组，
    // 避免重新形成串行的宽等值/进位结构。
    wire [16:0] raw_bypass_word_addr_diff =
        cpu_lookup_addr ^ {mem_tag, mem_index, mem_word};
    wire raw_bypass_addr_eq0 = ~|raw_bypass_word_addr_diff[5:0];
    wire raw_bypass_addr_eq1 = ~|raw_bypass_word_addr_diff[11:6];
    wire raw_bypass_addr_eq2 = ~|raw_bypass_word_addr_diff[16:12];
    wire raw_bypass_same_word =
        raw_bypass_addr_eq0 & raw_bypass_addr_eq1
        & raw_bypass_addr_eq2;
    wire raw_bypass_capture = pipeline_advance
                            & store_cache_write
                            & raw_bypass_same_word;

`ifndef SYNTHESIS
    wire raw_bypass_capture_reference =
        pipeline_advance & store_cache_write
        & cpu_req & ~cpu_wr & ~cpu_uncached & ~flush
        & (cpu_addr[31:2] == mem_addr[31:2]);
    logic raw_bypass_valid_reference_q;
`endif

    always_ff @(posedge clk) begin
        raw_bypass_data <= store_cache_write_data;
        raw_bypass_wea  <= store_cache_write_wea;
        if (!rst_n)
            raw_bypass_valid <= 1'b0;
        else
            raw_bypass_valid <= raw_bypass_capture;
    end

    // ================================================================
    //  Tag RAM 写入。
    // ================================================================
    // Dirty/tag payload 由 tag_vld 屏蔽。每次分配或 store 命中都会先初始化它，
    // 然后才可能影响 victim 写回选择。
    //
    // 下面四个架构事件彼此互斥，唯一例外是同一个 victim 的写回完成可能与
    // refill 请求/完成同周期发生。严格保持原来的非阻塞赋值优先级：
    // refill 安装 > store 命中 > 写回清脏 > refill 失效。
    logic               dirty_write_valid;
    logic [INDEX_W-1:0] dirty_write_index;
    logic               dirty_write_data;

    always_comb begin
        dirty_write_valid = 1'b0;
        dirty_write_index = refill_index;
        dirty_write_data  = 1'b0;

        if (refill_req_fire) begin
            dirty_write_valid = 1'b1;
        end

        // 写回成功后，被冲刷 load 的原始 cache line 仍保持有效但变为干净；
        // 正常路径会在下一步将其失效。
        if (wb_resp_ok & ~refill_read_accepted) begin
            dirty_write_valid = 1'b1;
        end

        if (store_cache_write) begin
            dirty_write_valid = 1'b1;
            dirty_write_index = mem_index;
            dirty_write_data  = 1'b1;
        end

        if (refill_complete) begin
            dirty_write_valid = 1'b1;
            dirty_write_index = refill_index;
            dirty_write_data  = refill_is_store;
        end
    end

    // 每个存储体每周期一次索引赋值，是标准单写端口分布式 RAM 模板。
    // tag_vld 会屏蔽未分配表项，因此不需要复位。
    always_ff @(posedge clk) begin
        if (dirty_write_valid)
            dirty[dirty_write_index] <= dirty_write_data;
    end

`ifndef SYNTHESIS
    // 只要普通 store 命中不会在 refill/writeback 元数据更新时修改另一条 line，
    // 单写端口表示就与原设计周期等价。同一 line 的重叠是合法的，上面的优先级
    // 与原来的非阻塞赋值顺序一致。
    wire dirty_refill_metadata_event = refill_req_fire
        | (wb_resp_ok & ~refill_read_accepted)
        | refill_complete;
    always_ff @(posedge clk) begin
        if (rst_n && store_cache_write && dirty_refill_metadata_event
                  && (mem_index != refill_index))
            $fatal(1, "DCache dirty metadata received two distinct writes in one cycle");
    end
`endif

    // ================================================================
    //  外部存储后端请求/响应。
    // ================================================================
    assign mem_req_valid = wb_state_cmd | state_refill_req | state_uc_req;
    assign mem_req_write = wb_state_cmd | (state_uc_req & mem_wr);
    assign mem_req_writeback = wb_state_cmd;
    assign mem_req_addr  = wb_state_cmd ? victim_line_addr
                         : state_uc_req ? {mem_addr[31:2], 2'b00}
                         : refill_fetch_addr;
    assign mem_req_len   = wb_state_cmd ? 8'(LINE_WORDS - 1)
                         : state_uc_req ? 8'd0
                                        : 8'(LINE_WORDS - 1);
    assign mem_req_burst = (state_refill_req & ~wb_state_cmd)
                         ? 2'b10 : 2'b01;
    assign mem_w_valid   = wb_state_data | state_uc_write_data;
    assign mem_w_data    = wb_state_data ? line_buffer[wb_send_beat]
                         : state_uc_write_data ? mem_wdata_aligned
                                               : 32'd0;
    assign mem_w_strb    = wb_state_data ? 4'b1111
                         : state_uc_write_data ? mem_wea : 4'b0000;
    assign mem_w_last    = wb_state_data
                         ? (wb_send_beat == WORD_W'(LINE_WORDS - 1))
                         : 1'b1;

    assign mem_rd_ready  = backend_rd_ready;
    assign mem_rd_cancel = 1'b0;
    assign mem_wr_ready  = backend_wr_ready;

    // ================================================================
    //  CPU 读数据格式化和末级来源选择（MEM 阶段）。
    //
    //  BRAM 命中、miss/未缓存响应并行格式化；末级来源控制选择完整 32 位
    //  结果，不会位于字节提取和扩展逻辑之前。
    // ================================================================
    wire raw_bypass_apply = raw_bypass_valid
                          & mem_req & ~mem_wr & ~mem_uncached;
    wire [3:0] raw_bypass_mask = raw_bypass_wea
                               & {4{raw_bypass_apply}};
    wire [31:0] cache_read_data = merge_bytes(
        data_rd, raw_bypass_data, raw_bypass_mask
    );
    wire [31:0] formatted_hit = format_load_data(
        cache_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );

    wire special_read_valid = uc_read_fire | refill_cpu_ready;
    logic [31:0] special_read_data;
    always_comb begin
        if (uc_read_fire)
            special_read_data = backend_rd_data;
        else if (refill_target_fire)
            special_read_data = refill_write_data;
        else if (refill_cpu_ready)
            special_read_data = refill_target_data;
        else
            special_read_data = 32'd0;
    end
    wire [31:0] formatted_special = format_load_data(
        special_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );

`ifndef SYNTHESIS
    wire [31:0] formatted_hit_reference = format_load_data_reference(
        cache_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );
    wire [31:0] formatted_special_reference = format_load_data_reference(
        special_read_data, mem_addr[1:0],
        mem_load_size, mem_load_unsigned
    );
`endif

    // 只复制末级来源选择器。格式化和 RAW 合并逻辑保持共享，远端每个
    // MEM/WB 目的端各自得到独立的末级 LUT 逻辑锥。
    dcache_read_result_select u_read_select_wb (
        .special_valid   (special_read_valid),
        .formatted_hit   (formatted_hit),
        .formatted_special(formatted_special),
        .selected_data   (cpu_rdata)
    );

    dcache_read_result_select u_read_select_ex (
        .special_valid   (special_read_valid),
        .formatted_hit   (formatted_hit),
        .formatted_special(formatted_special),
        .selected_data   (cpu_rdata_ex)
    );

    // ================================================================
    //  CPU ready 信号。
    // ================================================================
    assign refill_cpu_ready = refill_cpu_pending
                            & writeback_complete_now
                            & ~refill_abort
                            & (refill_target_fire | refill_target_valid);
    wire idle_load_ready = idle_load_hit;
    wire idle_cpu_ready = idle_load_ready | idle_store_accept;

    assign cpu_ready = ~mem_req
                     | (tag_init_release_q
                        & (refill_cpu_ready
                           | idle_cpu_ready
                           | uc_read_fire
                           | uc_write_fire));

`ifndef SYNTHESIS
    initial begin
        if (CACHE_ADDR_MASK != 32'hFFF8_0000)
            $fatal(1, "DCache three-bit tag requires addr[31:19] fixed");
        if ((CACHE_ADDR_BASE & ~CACHE_ADDR_MASK) != 32'd0)
            $fatal(1, "DCache cacheable window base is not mask-aligned");
    end

    always_ff @(posedge clk) begin
        if (rst_n && mem_req) begin
            if ((formatted_hit !== formatted_hit_reference)
                || (formatted_special !== formatted_special_reference))
                $fatal(1, "DCache parallel load formatter changed behavior");
            if (tag_hit !== mem_hit_reference)
                $fatal(1, "DCache split tag-hit pipeline changed behavior");

            // 两份副本在逻辑上有意保持完全相同，只有物理目的地不同。
            if (cpu_ready && (cpu_rdata_ex !== cpu_rdata))
                $fatal(1, "DCache duplicated load result changed behavior");

            // 只有完整地址已经由平台窗口分类后，缩短 tag 才合法。
            // 该断言保护这个边界约定，但不会把 13 位比较放入综合后的命中路径。
            if (mem_uncached !== (((mem_addr & CACHE_ADDR_MASK)
                                  != (CACHE_ADDR_BASE & CACHE_ADDR_MASK))))
                $fatal(1, "DCache cacheability disagrees with full address window");
        end

        if (!rst_n)
            raw_bypass_valid_reference_q <= 1'b0;
        else begin
            raw_bypass_valid_reference_q <= raw_bypass_capture_reference;
            if (mem_req && ~mem_wr && ~mem_uncached
                && (raw_bypass_valid !== raw_bypass_valid_reference_q))
                $fatal(1, "Speculative RAW candidate changed load-visible bypass");
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (refill_req_fire && wb_required
                && (wb_state == WB_IDLE) && !wb_done && !wb_resp_ok)
                $error("DCache refill lost ownership of its dirty victim buffer");
            if (wb_state_cmd
                && (!mem_req_valid || !mem_req_write
                    || !mem_req_writeback
                    || (mem_req_len != 8'(LINE_WORDS - 1))
                    || (mem_req_addr != victim_line_addr)
                    || (mem_req_burst != 2'b01)))
                $error("DCache writeback command shape mismatch");
            if (state_refill_req && ~wb_state_cmd
                && (mem_req_burst != 2'b10))
                $error("DCache refill burst type mismatch");
            if (state_uc_req && mem_req_writeback)
                $error("DCache uncached command was marked as writeback");
            if (refill_target_fire && wb_required
                && !writeback_complete_now && refill_cpu_ready)
                $error("DCache released dirty-miss data before B success");
            if (refill_data_fire
                && (backend_rd_last
                    != (refill_beat == WORD_W'(LINE_WORDS - 1))))
                $error("DCache eight-beat refill RLAST mismatch");
            if (wb_data_fire
                && (mem_w_last
                    != (wb_send_beat == WORD_W'(LINE_WORDS - 1))))
                $error("DCache writeback LAST mismatch");
        end
    end
`endif

endmodule
