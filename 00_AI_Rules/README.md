# 00_AI_Rules

> AI 接入本项目时，按顺序读以下文件。历史存档已清理；当前实现依据只看本目录顶层文档和下方列出的工程文档。

## 阅读顺序

1. **`global_rules.md`** — 地址映射、赛方约束、BRAM 时序、握手协议、编码规则、性能优化立项门槛
2. **`architecture.md`** — 当前 RTL 的双发射架构描述（从代码反向生成）
3. **`OPTIMIZATION_PLAN.md`** — 当前优化计划、设计契约、已否决方向的短结论

按需阅读：

- **`02_Design/sim/riscv_tests/test_coverage.md`** — 回归测试覆盖范围
- **`02_Design/coe/README.md`** — COE 文件、转换脚本和静态分布
- **`PhysicalTwin_XC7A35T/README.md`** — 自有物理板工程与显示映射

## 目录结构

```
00_AI_Rules/
├── README.md          ← 本文件
├── global_rules.md    ← 全局规则（不随架构变化的约束）
└── architecture.md    ← 当前架构（RTL 改动后同步更新）
```

## 工作区

```
CPU_Workspace/
├── 00_AI_Rules/           ← 你正在看的目录
├── OPTIMIZATION_PLAN.md   ← 当前优化计划和设计契约
├── 02_Design/
│   ├── rtl/               ← 自研 CPU RTL 源码
│   ├── coe/               ← 竞赛程序 COE 文件 + 工具脚本
│   ├── contest_readonly/  ← 赛方原版（禁止修改）
│   └── sim/
│       ├── riscv_tests/   ← iverilog 回归测试（64/64 PASS 目标）
│       └── debug/         ← Vivado 调试 TB
├── 03_Timing_Analysis/    ← 时序分析 TCL + 报告
├── PhysicalTwin_XC7A35T/  ← 自有 XC7A35T 板卡 Vivado 工程封装
├── JYD2025_Contest-rv32i/ ← Vivado 工程
└── riscv-tests/           ← 测试源码（build_tests.sh 依赖）
```
