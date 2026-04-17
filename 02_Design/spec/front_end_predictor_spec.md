# Phase 2+ 前端综合预测中心 (Front-end Predictor) 规格

> **回滚基准**: `d1fb38f` — Phase 1: ID-stage JAL early resolution
> **当前版本**: `8a6fac0` — Phase 2+ Bugfix: BTB + BHT + RAS
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
    input  logic        if_allowin,     // 门控：stall 时关闭预测和 RAS pop
    output logic        pred_taken,
    output logic [31:0] pred_target,

    // ID Stage (RAS Management)
    input  logic [31:0] id_pc,
    input  logic        id_is_call,     // JAL/JALR with rd == x1/x5
    input  logic        id_is_ret,      // JALR with rs1 == x1/x5, rd == x0

    // EX Stage (Update / Training)
    input  logic        update_en,      // 仅 JAL/B-type/RET 为真
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_actual_target,
    input  logic        ex_actual_taken, // 真实跳转结果 (从 branch_unit.actual_taken_out)
    input  logic [ 1:0] ex_inst_type,    // 0:JAL, 1:B-type, 2:RET
    input  logic        ex_mispredict    // branch_flush (来自 branch_unit)
);
```

## 3. 预测逻辑 (IF 级, 并行查表)

```
BTB 查表 ──→ btb_hit + btb_type ──→ ┐
                                       ├─ pred_taken_raw ──→ & if_allowin → pred_taken
BHT 查表 ──→ bht_direction ──────→ ┘

pred_target = (type == RET) ? ras_top : btb_target
```

> **关键约束**: `pred_taken` 必须用 `if_allowin` 门控。否则 stall 期间
> 同一 PC 反复命中 BTB，RAS 会被重复 Pop，指针飘走。

## 4. 训练逻辑 (EX 级, 同步写)

- **BTB**: **仅** JAL / B-type / RET 执行后写入 (PC, Target, Type)
- **BHT**: B-type 执行后更新 2-bit 计数器 (taken +1, not-taken -1, 饱和)
- **RAS**: ID 级 CALL 时 PUSH `PC+4`; IF 级 BTB 命中 RET 时 POP

> **关键约束**: 非 RET 的 JALR（间接跳转）**不可**存入 BTB。因为 BTB 会标记
> 为 BP_RET，导致后续 BTB 命中时错误触发 RAS Pop 并跳转到错误地址。
> `cpu_top` 中 `ex_is_ret` 通过 EX 级信号判断：
> `ex_is_jalr && (ex_rs1_addr==x1||x5) && (ex_rd==x0)`

## 5. 已知 Bug 修复记录 (8a6fac0)

| Bug | 原因 | 修复 |
| :--- | :--- | :--- |
| BTB 预测 JAL → EX Flush 到 PC+4 | `actual_taken` 不含 `is_jal` | `branch_unit`: 加入 `is_jal` |
| 非 RET JALR 标记为 BP_RET | 所有 JALR 都给 type=2 | `cpu_top`: 用 EX 级信号区分 RET |
| Stall 期间 RAS 重复 Pop | `btb_pred_ret` 在 stall 时持续为 1 | `pred_taken` & RAS pop 用 `if_allowin` 门控 |
| iverilog 仿真不含 predictor | `run_all.sh` 缺少文件 | 加入 `branch_predictor.sv` |

## 6. 性能指标

| 指令类型 | 首次执行 | 后续命中 | 后续猜错 |
| :--- | :--- | :--- | :--- |
| JAL | 1 拍 (ID 兜底) | **0 拍** | — |
| JALR (ret) | 2 拍 | **0 拍** | 2 拍 |
| B-type | 2 拍 | **0 拍** | 2 拍 |
| JALR (other) | 2 拍 | 2 拍（不可预测） | — |

## 7. 状态

- **仿真**: 40/40 riscv-tests PASS ✅（含预测器全开）
- **FPGA 基线**: EX-only + 无预测器 = ✅ 正常 (11.134s @ 200MHz)
- **FPGA + Phase 1 (JAL ID级)**: ❌ 跑飞，根因待排查
- **FPGA + Phase 2+ (预测器)**: 依赖 Phase 1 修复后才能验证
- **当前 RTL 状态**: `id_jump_taken=0`, `pred_taken=0`（两者均已禁用）
