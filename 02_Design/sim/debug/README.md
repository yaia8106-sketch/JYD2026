# 临时调试 Testbench 区

本目录用于存放**临时性的调试 testbench** 及其**输出产物**。

## 用途

- 快速编写一次性 TB 来验证某个信号行为、打印寄存器值等
- 存放仿真过程中产生的 `$display` / `$monitor` 文本输出
- 存放调试用的 VCD / FST 波形文件

## 命名建议

| 文件类型 | 命名格式 | 示例 |
|----------|---------|------|
| Testbench | `tb_<功能>.sv` | `tb_branch_debug.sv` |
| 仿真输出 | `<功能>_output.log` | `branch_debug_output.log` |
| 波形文件 | `<功能>.vcd` | `branch_debug.vcd` |

## 注意

- 本目录中的文件**不保证长期保留**，重要的验证结果请归档到 `riscv_tests/` 或文档中
- 建议在 `.gitignore` 中排除 `.vcd` 等大文件
