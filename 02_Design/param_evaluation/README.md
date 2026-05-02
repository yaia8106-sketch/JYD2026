# param_evaluation — 参数评估脚本

> 本目录存放用于 **设计空间探索** 的 Python 脚本。
> 所有脚本基于 ISA 级模拟（RV32I 全指令集），读取 `02_Design/coe/` 下的 COE 文件作为输入。

---

## 脚本总览

| 脚本 | 类别 | 功能 | 并行 |
|------|:---:|------|:---:|
| `bp_test_current.py` | BP | 测试当前 RTL 配置的预测准确率 | — |
| `bp_coldstart_sim.py` | BP | 冷启动预测准确率（严格复刻 RTL 三级流水） | — |
| `bp_param_sweep.py` | BP | 快速参数扫描（复用 bp_test_current 的模型） | ✅ |
| `bp_sweep.py` | BP | 全配置穷举扫描（独立模型，最精确） | ✅ |
| `cache_sim.py` | Cache | DCache 命中率模拟 + 性能估算 | — |
| `cache_sweep.py` | Cache | DCache 多配置并行扫描 | ✅ |

## 共同特征

- **输入**：`02_Design/coe/{current,src0,src1,src2}/irom.coe` + `dram.coe`
- **内存模型**：IROM `0x8000_0000`，DRAM `0x8010_0000 ~ 0x8014_0000`（256KB），MMIO `0x8020_0000+`
- **仿真规模**：通常 5M 指令/程序，4 程序全跑
- **输出**：终端打印 + 部分脚本生成 `sim_output/` 下的报告

## 详细文档

- **BP 脚本** → [`bp_scripts.md`](bp_scripts.md)
- **Cache 脚本** → [`cache_scripts.md`](cache_scripts.md)

## 分析结果归档

脚本产出的关键数据已整理到：
- `00_AI_Rules/full/bp_analysis.md` — BP 扫描结论
- `00_AI_Rules/full/cache_analysis.md` — DCache 扫描结论
