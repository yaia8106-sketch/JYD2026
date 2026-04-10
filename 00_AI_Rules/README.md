# 00_AI_Rules 目录索引

> AI 接入本项目时，**先读这个文件**，再按需阅读具体文档。

---

## 文件结构

```
00_AI_Rules/
├── README.md                 ← 你正在看的文件
├── project_context.md        ← AI 角色定义与工作流
├── design_rules/             ← AI 必须遵守的设计规则（"法律"）
│   ├── pipeline.md           ← 五级流水线控制规范（核心文档）
│   ├── isa_encoding.md       ← RV32I 控制信号与译码表
│   └── spec_format.md        ← Module Spec 编写模板
└── selfuse/                  ← 架构师个人笔记（可查看，禁止修改）
    ├── design_decisions.md   ← A-H 设计决策记录
    └── TODO.md               ← 待办清单
```

---

## 各文件说明

### `project_context.md`
**定位**：System Prompt，定义 AI 的角色和工作范式。
**内容**：黑盒开发流程、目录结构、SOP、硬件编码底线规则。
**何时读**：每次对话开头。

---

### `design_rules/pipeline.md`
**定位**：全局架构圣经，所有模块 spec 的上位依据。
**内容**：
- §1-2：流水线结构、BRAM 时序模型（方案 B）、IROM/DRAM 时序分析
- §3-5：握手协议（valid/allowin/ready_go）、级间寄存器行为、PC 更新逻辑
- §6-7：stall 传播机制与时序示例
- §8：flush 机制（2 拍代价、信号连接、valid gating）
- §9：数据冒险（并行前递 MUX、Load-Use 检测 EX+MEM 两级）
- §10-11：信号连接总览、设计检查清单

**何时读**：编写任何模块 spec 或 RTL 之前。

---

### `design_rules/isa_encoding.md`
**定位**：指令集编码与控制信号定义。
**内容**：14 个控制信号定义、ALU 操作编码、分支条件编码、立即数生成规则、完整译码真值表、EX 级分支判断单元。
**何时读**：编写译码器、ALU、分支单元相关模块时。

---

### `design_rules/spec_format.md`
**定位**：Module Spec 的格式模板。
**内容**：必需章节（端口列表、功能描述、时序约束、边界条件、依赖文档）、可选章节、反面示例。
**何时读**：编写新的 `_spec.md` 时。

---

### `selfuse/design_decisions.md`
**定位**：架构师决策笔记（A-H 共 8 项）。
**内容**：
- A. 寄存器堆：read-first
- B. Flush 代价：2 拍
- C. 跳转处理：初版全 EX
- D. 控制信号：见 isa_encoding.md
- E. DRAM 访存：Single Port + 4-bit WEA
- F. 前递路径：ID 级并行 MUX，EX>MEM>WB>regfile
- G. BRAM 配置：均 Single Port 带输出寄存器
- H. BRAM 残留：valid gating 屏蔽

**何时读**：需要了解"为什么这样设计"时。AI 不应修改此文件。

---

### `selfuse/TODO.md`
**定位**：待办清单，分 AI 总结区和架构师自用区。
**何时读**：确认当前任务优先级时。AI 不应修改此文件。
