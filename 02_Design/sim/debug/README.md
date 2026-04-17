# 调试 Testbench 区

**绝对路径**：`/home/anokyai/桌面/CPU_Workspace/02_Design/sim/debug`

本目录用于存放 **调试用 testbench** 及其 **仿真输出产物**。

## 核心文件

| 文件 | 说明 |
|------|------|
| `tb_student_top.sv` | 主调试 TB（例化 student_top 的平台级仿真） |

- **用户**通过 Vivado GUI 使用此 TB 打印信号值、查看波形
- **AI** 通过 Vivado TCL shell 使用此 TB 进行自动化调试仿真
- 每次调试时直接修改此文件，添加 `$display` / `$monitor` 等语句

## 输出产物

仿真过程中产生的输出也存放在本目录：

| 文件类型 | 命名格式 | 示例 |
|----------|---------|------|
| 仿真输出 | `<功能>_output.log` | `branch_debug_output.log` |
| 波形文件 | `<功能>.vcd` | `branch_debug.vcd` |

## 注意

- `.vcd` 等大文件建议在 `.gitignore` 中排除
- 重要的调试结论请归档到 `00_AI_Rules/selfuse/` 或相关文档中
