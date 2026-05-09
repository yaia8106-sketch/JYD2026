# 当前状态与下一步

更新日期：2026-05-09

## 当前基线

- 当前分支：`opt/perf`。
- RTL 主线保持干净；最近一次保留的 RTL 方向是前端取指/分支预测/forwarding 已收敛版本。
- `stage_timing_report.txt` 是 Vivado 生成物，已从 git 跟踪中移除；每次以 `./run_vivado_flow.sh current 20` 重新生成。
- 自有物理板工程在 `PhysicalTwin_XC7A35T/`，CPU RTL 直接引用 `02_Design/rtl`，不维护第二份 CPU 代码。

## 最近结论

- 零周期 `ID actual redirect -> IROM` 有 CPI 收益，但 FPGA 时序代价过高，已记录在 `00_AI_Rules/tradeoffs*.md`，不要直接恢复。
- `load -> store` MEM-ready 修复实验对 `src2` 约有 `-0.017 CPI`，但 Vivado 200MHz 报负 slack，已撤回。
- BP 容量/GHR 扫描收益偏小：软件模型中 GHR 8 -> 12 平均约 `-0.007 CPI`，不值得优先扩大表项。
- `coe_hotspots.py` 显示 `src0/src1/src2` 热点主要集中在除法/取模风格循环：
  - 独立 slot1 branch 机会较多。
  - `andi ..., 1 -> branch` 这类 ALU-to-branch 紧邻相关也很热。
- 自有 XC7A35T 物理板 DRAM 只有 48 个 4KiB 物理页（192KiB）可用：
  - `dual_issue/src1` 已适配，动态页集合为 `0x00..0x2c + 0x34`，可完整放入。
  - `dual_issue/src0` 不再做适配；完整运行需要 62 个 4KiB 页，细分到 1KiB 仍需 245KiB 级工作集，超过板卡容量。`src0=2589ms` 这类短时间是错误/提前结束路径，不作为性能结果。
  - `dual_issue/src2` 也超过 48 页，当前板上结果只能作为容量受限实验结果，严格结果需扩展内存或改程序/数据布局。

## 下一步候选

1. 先用软件模型估算 slot1 branch / ALU-branch fusion 的真实收益和 taken/not-taken 风险。
2. 若做 RTL，优先设计不加长 IF/IROM 快路径的 slot1 branch 方案。
3. 任何 CPI 优化后都要按顺序做：
   - `bash 02_Design/sim/riscv_tests/run_all.sh`
   - `run_coe_diff.sh` 的长前缀对比
   - `./run_vivado_flow.sh current 20`
