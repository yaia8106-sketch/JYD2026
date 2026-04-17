# Phase 2+ 前端综合预测中心 (Front-end Predictor) 规格

> **回滚基准**: `d1fb38f` — Phase 1: ID-stage JAL early resolution
> **当前版本**: `c2efc29` — Phase 2+: BTB + BHT + RAS 全部完成
> 如需回滚: `git reset --hard d1fb38f`

## 1. 核心架构

针对 200MHz 及小规模程序优化，所有查询为 IF 级纯组合逻辑 (LUTRAM 异步读)。

| 组件 | 规模 | 索引 | 功能 |
| :--- | :--- | :--- | :--- |
| **BTB** | 32 项 | `PC[6:2]`, Tag=`PC[13:7]` | 记录跳转目标及指令类型 (JAL/B/RET) |
| **BHT** | 64 项 | `PC[7:2]`, 无 Tag | 2-bit 饱和计数器方向预测 |
| **RAS** | 4 层 | 循环 LIFO | 函数返回地址栈 |

## 2. 接口定义 (branch_predictor.sv)

```verilog
module branch_predictor (
    input  logic        clk, rst_n,

    // IF Stage (Query - Combinational)
    input  logic [31:0] if_pc,
    output logic        pred_taken,
    output logic [31:0] pred_target,

    // ID Stage (RAS Management)
    input  logic [31:0] id_pc,
    input  logic        id_is_call,     // JAL/JALR with rd == x1/x5
    input  logic        id_is_ret,      // JALR with rs1 == x1/x5, rd == x0

    // EX Stage (Update / Training)
    input  logic        update_en,
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_actual_target,
    input  logic        ex_actual_taken, // 真实跳转结果 (从 branch_unit.actual_taken_out)
    input  logic [ 1:0] ex_inst_type,    // 0:JAL, 1:B-type, 2:RET/JALR
    input  logic        ex_mispredict    // branch_flush (来自 branch_unit)
);
```

## 3. 预测逻辑 (IF 级, 并行查表)

```
BTB 查表 ──→ btb_hit + btb_type ──→ ┐
                                       ├─ pred_taken (1 个 AND 合并)
BHT 查表 ──→ bht_direction ──────→ ┘

pred_target = (type == RET) ? ras_top : btb_target
```

## 4. 训练逻辑 (EX 级, 同步写)

- **BTB**: 任何跳转指令执行后写入 (PC, Target, Type)
- **BHT**: B-type 执行后更新 2-bit 计数器 (taken +1, not-taken -1, 饱和)
- **RAS**: ID 级 CALL 时 PUSH `PC+4`; IF 级 BTB 命中 RET 时 POP

## 5. 性能指标

| 指令类型 | 首次执行 | 后续命中 | 后续猜错 |
| :--- | :--- | :--- | :--- |
| JAL | 1 拍 (ID 兜底) | **0 拍** | — |
| JALR (ret) | 2 拍 | **0 拍** | 2 拍 |
| B-type | 2 拍 | **0 拍** | 2 拍 |
| JALR (other) | 2 拍 | 2 拍 | — |

**时序**: WNS = +0.064ns @ 200MHz ✅
