# Phase 2+ 前端综合预测中心 (Front-end Predictor) 规格与计划

> **回滚基准**: `d1fb38f` — Phase 1: ID-stage JAL early resolution (200MHz timing closed)
> 如需回滚: `git reset --hard d1fb38f`

## 1. 核心架构 (64-entry BTB / 4-entry RAS)
针对 200MHz 及小规模程序优化：
*   **IF 级预测 (0-cycle)**: 纯组合逻辑查表 (LUTRAM)。
    *   **BTB**: 32~64项，存 `Tag (PC高位)`, `Type (JAL/B/RET)`, `Target (PC[31:2])`。
    *   **BHT**: 128项，2-bit 饱和计数器。
    *   **RAS**: 4层 LIFO 栈。
*   **EX 级训练**: 同步写更新。

## 2. 关键接口定义 (branch_predictor.sv)
```verilog
module branch_predictor (
    input  logic        clk,
    input  logic        rst_n,
    
    // IF Stage (Query)
    input  logic [31:0] if_pc,
    output logic        pred_taken,
    output logic [31:0] pred_target,
    
    // ID Stage (RAS Push/Pop logic)
    input  logic [31:0] id_pc,
    input  logic        id_is_call,
    input  logic        id_is_ret,
    
    // EX Stage (Update / Train)
    input  logic        update_en,
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_actual_target,
    input  logic        ex_actual_taken,
    input  logic [ 1:0] ex_inst_type     // 0:JAL, 1:B, 2:RET
);
```

## 3. 实施计划 (Roadmap)
1.  **Step 1**: 模块例化与接口挂载 (默认 Taken=0)。
2.  **Step 2**: 实现 BTB + JAL 0-拍跳转。
3.  **Step 3**: 实现 RAS + RET 0-拍预测。
4.  **Step 4**: 实现 BHT + 分支方向预测。
5.  **Step 5**: 时序收敛与 riscv-tests 验证。
