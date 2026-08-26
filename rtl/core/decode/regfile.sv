// ============================================================
// 中文说明：实现双发射处理器使用的 32 个 32 位通用寄存器，提供四个读端口和两个写端口。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：regfile。
// 说明：32 个 32 位寄存器，提供四读两写端口，采用 read-first 行为。
// 所属阶段：decode 和 issue。
// 规格说明：02_Design/spec/regfile_spec.md。
// ============================================================

module regfile (
    input  logic        clk,
    input  logic        rst_n,

    // Slot0 读端口（组合逻辑）。
    input  logic [ 4:0] rs1_addr,
    input  logic [ 4:0] rs2_addr,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data,

    // Slot1 读端口（组合逻辑）。
    input  logic [ 4:0] rs1_addr_s1,
    input  logic [ 4:0] rs2_addr_s1,
    output logic [31:0] rs1_data_s1,
    output logic [31:0] rs2_data_s1,

    // Slot0 写端口（时钟上升沿）。
    input  logic [ 4:0] rd_addr,
    input  logic [31:0] rd_data,
    input  logic        rd_wen,     // 来自流水线的 reg_write_en
    input  logic        rd_valid,   // wb_valid（只在有效时写入）

    // Slot1 写端口（时钟上升沿），WAW 时优先于 Slot0。
    input  logic [ 4:0] rd_addr_s1,
    input  logic [31:0] rd_data_s1,
    input  logic        rd_wen_s1,
    input  logic        rd_valid_s1,

    output logic [1023:0] debug_state
);

    // ---- 寄存器数组 ----
    // x0 不存入数组；读取地址零时直接返回常数。
    logic [31:0] regs [1:31];   // 不存储 x0，读取时固定返回 0

    // ---- 读取（组合逻辑，read-first）----
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];
    assign rs1_data_s1 = (rs1_addr_s1 == 5'd0) ? 32'd0 : regs[rs1_addr_s1];
    assign rs2_data_s1 = (rs2_addr_s1 == 5'd0) ? 32'd0 : regs[rs2_addr_s1];
    assign debug_state[0 +: 32] = 32'd0;
    for (genvar debug_reg = 1; debug_reg < 32; debug_reg++) begin : g_debug
        assign debug_state[debug_reg*32 +: 32] = regs[debug_reg];
    end

    // ---- 写入（上升沿，保护 x0；Slot1 最后赋值，因此 WAW 时获胜）----
    // 两个写端口在同一个 WB 周期按程序顺序提交。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 1; i < 32; i++) begin
                regs[i] <= 32'd0;
            end
        end else begin
            if (rd_valid && rd_wen && rd_addr != 5'd0)
                regs[rd_addr] <= rd_data;
            if (rd_valid_s1 && rd_wen_s1 && rd_addr_s1 != 5'd0)
                regs[rd_addr_s1] <= rd_data_s1;
        end
    end

endmodule
