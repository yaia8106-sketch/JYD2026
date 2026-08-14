// ============================================================
// 中文说明：选择写回寄存器堆的数据来源，包括 ALU 结果、load 数据和跳转链接地址。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：组合选择 WB 阶段写回寄存器堆的数据，并提供 JAL/JALR
// 需要的 PC+4 链接地址。
// ============================================================

module wb_mux (
    input  logic [31:0] wb_alu_result,
    input  logic [31:0] wb_load_data,      // 来自访存接口的 load 数据
    input  logic [31:0] wb_pc_plus_4,     // 已预先计算，不需要再次加法
    input  logic [ 1:0] wb_sel,            // 00=ALU，01=DRAM，10=PC+4

    output logic [31:0] wb_write_data
);

    // ---- 三路与或选择器 ----
    // load 使用已经格式化的 MEM/WB 数据；跳转使用 PC+4 链接地址。
    wire sel_alu  = (wb_sel == 2'b00);
    wire sel_mem  = (wb_sel == 2'b01);
    wire sel_link = (wb_sel == 2'b10);

    assign wb_write_data = ({32{sel_alu}}  & wb_alu_result)
                         | ({32{sel_mem}}  & wb_load_data)
                         | ({32{sel_link}} & wb_pc_plus_4);

endmodule
