// ============================================================
// 中文说明：连接流水线访存请求和 DCache 接口，保存访存请求在等待期间必须保持的字段。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：mem_interface。
// 说明：提供 DRAM 访问辅助逻辑（纯组合逻辑）。
// 所属单元：load/store。
//   - store 侧（EX 阶段）：生成 WEA，并移动 store 数据；
//   - load 侧（MEM 阶段）：提取字节并进行符号/零扩展；
//     地址候选项先并行计算，末级再选择槽位。
// 规格说明：02_Design/spec/mem_interface_spec.md。
// ============================================================

module mem_interface (
    // ---- store 侧（EX 阶段使用）----
    input  logic        store_valid,       // ex_valid
    input  logic        store_en,          // ex_mem_write_en
    input  logic [ 1:0] store_addr_low,    // ALU_result[1:0]
    input  logic [ 1:0] store_mem_size,    // 00=B, 01=H, 10=W
    input  logic [31:0] store_data_in,     // rs2_data (raw)
    output logic [ 3:0] store_wea,         // BRAM 字节写使能（已门控）
    output logic [31:0] store_data_out,    // 移位后送入 BRAM din 的数据

    // ---- load 侧（MEM 阶段使用）----
    input  logic        load_en,
    input  logic [ 1:0] load_addr_low,
    input  logic [ 1:0] load_mem_size,     // 00=B, 01=H, 10=W
    input  logic        load_unsigned,
    input  logic [31:0] load_dram_dout,    // BRAM 原始 32 位输出
    output wire  [31:0] load_data_out      // 提取并扩展后的结果
);

    // ================================================================
    //  store 侧：WEA + 数据移动。
    // ================================================================

    // WEA：需要写入哪些字节（由 valid 和 enable 控制）。
    wire st_byte = (store_mem_size == 2'b00);
    wire st_half = (store_mem_size == 2'b01);
    wire st_word = (store_mem_size == 2'b10);

    // 未对齐半字掩码按字面生成；访问是否合法由目标平台的存储系统决定。
    wire [3:0] wea_raw = ({4{st_byte}} & (4'b0001 << store_addr_low))
                       | ({4{st_half}} & (4'b0011 << store_addr_low))
                       | ({4{st_word}} & 4'b1111);

    assign store_wea = (store_valid & store_en) ? wea_raw : 4'b0000;

    // 数据移动：将 rs2 数据移到正确的字节通道。
    assign store_data_out = store_data_in << {store_addr_low, 3'b0};

    // ================================================================
    //  load 侧：并行字节提取 + 符号/零扩展。
    // ================================================================

    // load 有效位刻意不进入这个宽 payload 路径。MEM/WB 只有在 mem_load_valid
    // 接受完成的 load 时才观察 load_data_out，因此无效周期可以携带任意格式化
    // 候选值。这样 32 个数据位都不需要经过末级 LSU-valid 控制。
    wire load_byte_signed   = (load_mem_size == 2'b00) & ~load_unsigned;
    wire load_byte_unsigned = (load_mem_size == 2'b00) &  load_unsigned;
    wire load_half_signed   = (load_mem_size == 2'b01) & ~load_unsigned;
    wire load_half_unsigned = (load_mem_size == 2'b01) &  load_unsigned;
    wire load_word          = (load_mem_size == 2'b10);

    function automatic logic [31:0] format_load_candidate(
        input logic [31:0] shifted,
        input logic        byte_signed,
        input logic        byte_unsigned,
        input logic        half_signed,
        input logic        half_unsigned,
        input logic        word
    );
        logic [31:0] byte_signed_ext;
        logic [31:0] byte_unsigned_ext;
        logic [31:0] half_signed_ext;
        logic [31:0] half_unsigned_ext;
        begin
            byte_signed_ext   = {{24{shifted[7]}},  shifted[7:0]};
            byte_unsigned_ext = {24'd0, shifted[7:0]};
            half_signed_ext   = {{16{shifted[15]}}, shifted[15:0]};
            half_unsigned_ext = {16'd0, shifted[15:0]};
            format_load_candidate =
                ({32{byte_signed}}   & byte_signed_ext)
              | ({32{byte_unsigned}} & byte_unsigned_ext)
              | ({32{half_signed}}   & half_signed_ext)
              | ({32{half_unsigned}} & half_unsigned_ext)
              | ({32{word}}          & shifted);
        end
    endfunction

    // 这些候选项等价于按 addr_low * 8 进行逻辑右移，包括未对齐访问所需的零填充。
    wire [31:0] shifted_addr0 = load_dram_dout;
    wire [31:0] shifted_addr1 = { 8'd0, load_dram_dout[31:8]};
    wire [31:0] shifted_addr2 = {16'd0, load_dram_dout[31:16]};
    wire [31:0] shifted_addr3 = {24'd0, load_dram_dout[31:24]};

    wire [31:0] load_addr0_candidate = format_load_candidate(
        shifted_addr0, load_byte_signed, load_byte_unsigned,
        load_half_signed, load_half_unsigned, load_word
    );
    wire [31:0] load_addr1_candidate = format_load_candidate(
        shifted_addr1, load_byte_signed, load_byte_unsigned,
        load_half_signed, load_half_unsigned, load_word
    );
    wire [31:0] load_addr2_candidate = format_load_candidate(
        shifted_addr2, load_byte_signed, load_byte_unsigned,
        load_half_signed, load_half_unsigned, load_word
    );
    wire [31:0] load_addr3_candidate = format_load_candidate(
        shifted_addr3, load_byte_signed, load_byte_unsigned,
        load_half_signed, load_half_unsigned, load_word
    );

    assign load_data_out = ({32{load_addr_low == 2'd0}} & load_addr0_candidate)
                         | ({32{load_addr_low == 2'd1}} & load_addr1_candidate)
                         | ({32{load_addr_low == 2'd2}} & load_addr2_candidate)
                         | ({32{load_addr_low == 2'd3}} & load_addr3_candidate);

endmodule
