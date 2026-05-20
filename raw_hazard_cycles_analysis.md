# RAW Hazard Cycle Analysis

生成时间：2026-05-20

## 结论摘要

这次重新跑完了六份 COE，没有使用部分结果。仿真总耗时 `3123s`，日志在 `/tmp/raw_hazard_diag/log/full/`。

主要结论：

- `ID RAW stall cycles` 是真实 ID 阶段 RAW 停顿周期，六份合计 `2,794,542,503` 周期。
- “W 尚未计算出来”的 RAW 主要来自 load-use：六份合计 `1,409,708,991` 周期，其中 `EX load pending` 占 `80.1%`，`MEM load blocked/not ready` 占 `19.9%`。
- “W 已经算出但当前没有合适前递/旁路”的 RAW 合计 `1,385,601,600` 周期，是优化前递路径的主要目标。
- 第二类 RAW 的主要来源按六份合计排序：
  - `Branch EX no fwd`: `632,727,245` 周期，占第二类 `45.7%`
  - `Repaired EX chain no fwd`: `515,026,415` 周期，占第二类 `37.2%`
  - `MEM-ready load no fwd`: `237,847,922` 周期，占第二类 `17.2%`
  - `JALR EX no fwd`: `18` 周期，基本可以忽略
- `new_with_Mext` 中 MULDIV pending dependency 只有 `768,088` 周期，占该程序总周期 `0.12%`，不是 RAW 停顿的主要来源。
- `Same-pair RAW lost slots` 不是流水线停顿周期，而是 slot1 因同拍 RAW 不能双发射损失的发射槽；六份合计 `1,900,605,299` 个发射槽。

## 统计口径

第一类：W 的数据尚未计算出来，无法前递。

- `EX load pending`：load 仍在 EX，数据至少还差一个或多个阶段。
- `MEM load blocked/not ready`：load 在 MEM，但 DCache/BRAM 数据尚不可用或 MEM 被阻塞。
- `MULDIV pending dependency`：ID 指令依赖 EX 阶段未完成的 MULDIV 结果。注意当前 MULDIV 会让 EX 全局等待，所以这项不完全等价于 `id_ready_go=0`，在 `new_with_Mext` 中会让“未算出 + 已算出无前递”略大于 `ID RAW stall cycles`。

第二类：W 的数据已经计算出来，但当前没有为该消费场景设计低代价前递/旁路。

- `MEM-ready load no fwd`：MEM load 数据已经 ready，但消费端不是当前可直接释放的普通 S0 ALU 场景。
- `Repaired EX chain no fwd`：EX 中的 ALU 结果本身来自 late WB repair，当前没有把这个 repaired EX result 当拍再前递给更年轻 ID 指令。
- `Branch EX no fwd`：branch compare 在 ID 侧，为避免 EX producer -> ID compare 的长组合路径，当前选择停一拍等 MEM/WB。
- `JALR EX no fwd`：JALR target 在 ID 侧，同样没有 EX producer -> ID JALR target 的路径。

`Same-pair RAW lost slots` 单独列出：它描述同一 fetch pair 中 slot1 被 slot0 RAW 阻止，不是流水线停顿周期。

## 总览表

| 程序 | 结束状态 | cycles | CPI | 双发射率 | ID RAW 停顿 | 未算出 RAW | 已算出无前递 RAW | 同拍 RAW 损失槽 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `current` | LED fail, PERF complete | 36,247,924 | 1.178 | 60.6% | 3,446,913 | 700,240 | 2,746,673 | 1,010,630 |
| `src0` | LED fail, PERF complete | 2,044,868,564 | 1.442 | 16.9% | 643,218,922 | 302,716,987 | 340,501,935 | 567,075,903 |
| `src1` | LED fail, PERF complete | 2,153,225,504 | 1.651 | 11.6% | 838,416,260 | 523,496,990 | 314,919,270 | 415,018,028 |
| `src2` | LED fail, PERF complete | 2,637,386,996 | 1.426 | 30.8% | 710,836,278 | 252,965,927 | 457,870,351 | 422,688,966 |
| `new_without_Mext` | DONE_PC | 1,132,685,661 | 1.446 | 20.5% | 361,347,373 | 165,590,867 | 195,756,506 | 289,553,505 |
| `new_with_Mext` | DONE_PC | 629,033,648 | 1.654 | 6.0% | 237,276,757 | 164,237,980 | 73,806,865 | 205,258,267 |

## 第一类：W 尚未计算出来

| 程序 | 未算出 RAW 合计 | EX load pending | MEM load blocked/not ready | MULDIV pending dependency |
|---|---:|---:|---:|---:|
| `current` | 700,240 | 600,215 | 100,025 | 0 |
| `src0` | 302,716,987 | 240,303,064 | 62,413,923 | 0 |
| `src1` | 523,496,990 | 469,420,899 | 54,076,091 | 0 |
| `src2` | 252,965,927 | 207,474,895 | 45,491,032 | 0 |
| `new_without_Mext` | 165,590,867 | 105,570,106 | 60,020,761 | 0 |
| `new_with_Mext` | 164,237,980 | 105,567,162 | 57,902,730 | 768,088 |
| **合计** | **1,409,708,991** | **1,128,936,341** | **280,004,562** | **768,088** |

解读：

- 未算出 RAW 几乎完全由 load-use 组成。除 `new_with_Mext` 外，MULDIV 依赖为 0；即使在 `new_with_Mext` 中也只有 `768,088` 周期。
- `EX load pending` 是第一类的最大项，说明如果想减少“数据确实没出来”的 RAW，只能从 load-use 调度、load latency、cache/BRAM 返回时序或编译端排布入手，单纯增加前递线不能消除这类周期。

## 第二类：W 已算出但没有对应前递路径

| 程序 | 已算出无前递合计 | MEM-ready load no fwd | Repaired EX chain no fwd | Branch EX no fwd | JALR EX no fwd |
|---|---:|---:|---:|---:|---:|
| `current` | 2,746,673 | 100,064 | 300,090 | 2,346,516 | 3 |
| `src0` | 340,501,935 | 36,643,208 | 124,818,546 | 179,040,178 | 3 |
| `src1` | 314,919,270 | 107,236,082 | 159,600,536 | 48,082,649 | 3 |
| `src2` | 457,870,351 | 71,960,939 | 104,601,424 | 281,307,985 | 3 |
| `new_without_Mext` | 195,756,506 | 10,953,799 | 62,852,892 | 121,949,812 | 3 |
| `new_with_Mext` | 73,806,865 | 10,953,830 | 62,852,927 | 105 | 3 |
| **合计** | **1,385,601,600** | **237,847,922** | **515,026,415** | **632,727,245** | **18** |

第二类内部占比：

| 场景 | 合计周期 | 占第二类比例 |
|---|---:|---:|
| Branch EX no fwd | 632,727,245 | 45.7% |
| Repaired EX chain no fwd | 515,026,415 | 37.2% |
| MEM-ready load no fwd | 237,847,922 | 17.2% |
| JALR EX no fwd | 18 | 0.0% |

解读：

- 最值得优先分析的是 `Branch EX no fwd` 和 `Repaired EX chain no fwd`。
- `new_with_Mext` 的 `Branch EX no fwd` 几乎消失，说明它的热点结构和 `new_without_Mext/src*` 差异很大；但 `Repaired EX chain` 仍保持 `62.85M`，是稳定存在的瓶颈。
- `JALR EX no fwd` 只有个位数周期，除非后续程序结构变化，否则不值得优先加复杂路径。

## MEM-ready load no fwd 细分

| 程序 | MEM-ready load no fwd | S0 branch compare | S0 JALR target | S0 load addr | S0 store addr | S0 store data | S1 consumer |
|---|---:|---:|---:|---:|---:|---:|---:|
| `current` | 100,064 | 100,054 | 8 | 0 | 0 | 2 | 1 |
| `src0` | 36,643,208 | 35,838,598 | 20,068 | 0 | 0 | 171,991 | 612,552 |
| `src1` | 107,236,082 | 104,536,069 | 2,560,042 | 0 | 0 | 109,971 | 30,001 |
| `src2` | 71,960,939 | 39,942,421 | 3,812 | 11,000,000 | 6,000,000 | 12,014,706 | 3,000,001 |
| `new_without_Mext` | 10,953,799 | 10,825,721 | 52 | 8 | 2 | 128,010 | 4 |
| `new_with_Mext` | 10,953,830 | 10,825,727 | 77 | 8 | 2 | 128,010 | 4 |
| **合计** | **237,847,922** | **202,068,590** | **2,584,059** | **11,000,016** | **6,000,004** | **12,552,690** | **3,642,563** |

解读：

- MEM-ready load no fwd 里面最大的是 `S0 branch compare`，合计 `202.1M`。
- `src2` 是唯一明显暴露 LSU 相关 MEM-ready load 旁路需求的程序：`load addr 11M`、`store addr 6M`、`store data 12.0M`、`S1 3M`。
- 普通 S0 ALU 的 MEM-ready load 依赖当前通过 repair 机制释放，不计入这里的 stall；但它会引出下一类 `Repaired EX chain`。

## 优化优先级建议

1. 先评估 `Branch EX no fwd` 是否值得加路径。

   当前停顿是有意设计出来的：branch compare 在 ID，EX producer -> ID branch compare 会形成反向长组合路径。它的收益很高，六份合计 `632.7M` 周期，但 PPA 风险也最大。建议先做一个可综合分支，比较 200MHz timing：

   - 方案 A：仅对 branch compare 加 EX/MEM/WB 更完整的旁路选择，但严格看 ID comparator 前路径。
   - 方案 B：把部分 branch compare/resolve 后移或重构，降低 ID 侧长路径，但可能增加分支惩罚。
   - 方案 C：保持不加 EX->ID branch 旁路，只针对 MEM-ready load -> branch 这种更晚一级且可能更安全的路径优化。

2. 再处理 `Repaired EX chain no fwd`。

   这类不是简单“多接一条线”就一定安全，因为 producer 的 EX 结果本身来自 late WB repair。若直接做 WB -> EX ALU -> ID operand 的同拍组合链，很可能不适合 200MHz。更可行的方向是：

   - 在 EX 阶段增加真正的 operand bypass mux，让年轻指令进入 EX 后再拿上一拍结果，而不是都在 ID 前递完成。
   - 或者重新设计 MEM-ready load release/repair 策略，减少“被 repair 的 ALU 结果立刻又被下一条依赖”的长链。

3. 最后看 `MEM-ready load no fwd` 的子场景。

   合计最大子项是 MEM-ready load -> branch compare。`src2` 还暴露了 MEM-ready load -> LSU 地址/写数据和 S1 consumer 的需求。这里可以按风险分层：

   - MEM-ready load -> store data 可能比 branch compare 更容易局部化。
   - MEM-ready load -> LSU address 会影响 DCache 请求地址时序，需要谨慎。
   - MEM-ready load -> S1 consumer 涉及双发射 slot1 operand path，收益在当前六份中较小。

4. `JALR EX no fwd` 暂不优先。

   六份合计只有 `18` 周期，收益太小。

## 代码与复现记录

修改的统计逻辑位于 `02_Design/riscv_tests/tb/perf_monitor.sv`。快速验证命令：

```bash
bash 02_Design/riscv_tests/run_perf.sh simple
```

完整 COE 运行使用 Verilator，并行跑六份：

```bash
/tmp/raw_hazard_diag/obj/Vtb_riscv_tests      +test=current +cycles=5000000000 +perf
/tmp/raw_hazard_diag/obj/Vtb_riscv_tests      +test=src0 +cycles=5000000000 +perf
/tmp/raw_hazard_diag/obj/Vtb_riscv_tests      +test=src1 +cycles=5000000000 +perf
/tmp/raw_hazard_diag/obj/Vtb_riscv_tests      +test=src2 +cycles=5000000000 +perf
/tmp/raw_hazard_diag/obj_done/Vtb_riscv_tests +test=new_without_Mext +stop_pc=80000010 +cycles=5000000000 +perf
/tmp/raw_hazard_diag/obj_done/Vtb_riscv_tests +test=new_with_Mext +stop_pc=80000014 +cycles=5000000000 +perf
```

