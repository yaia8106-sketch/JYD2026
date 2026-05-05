# 00_AI_Rules

> AI 接入本项目时，按顺序读以下两个文件。

## 阅读顺序

1. **`global_rules.md`** — 地址映射、赛方约束、BRAM 时序、握手协议、编码规则
2. **`architecture.md`** — 当前 RTL 的双发射架构描述（从代码反向生成）

## 目录结构

```
00_AI_Rules/
├── README.md          ← 本文件
├── global_rules.md    ← 全局规则（不随架构变化的约束）
├── architecture.md    ← 当前架构（RTL 改动后同步更新）
└── archive/           ← 旧文档存档（不主动读）
```

## 工作区

```
CPU_Workspace/
├── 00_AI_Rules/           ← 你正在看的目录
├── 02_Design/
│   ├── rtl/               ← 自研 CPU RTL 源码
│   ├── contest_readonly/  ← 赛方原版（禁止修改）
│   └── sim/riscv_tests/   ← 回归测试（63/63 PASS）
├── JYD2025_Contest-rv32i/ ← Vivado 工程
└── riscv-tests/           ← 测试源码
```
