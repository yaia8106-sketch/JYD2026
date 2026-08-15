# 前递网络与删路软件模型

## 1. 当前 RTL 的前递结构

普通 ID 操作数网络在
`rtl/core/decode/forwarding.sv` 中对 S0.rs1、S0.rs2、S1.rs1、S1.rs2
各复制一份匹配与选择逻辑。每个操作数的架构优先级相同：

```text
S1_EX > S0_EX > S1_MEM > S0_MEM > S1_WB > S0_WB > RF
```

同一流水级内 S1 比 S0 年轻，因此必须优先。MEM load 不参加普通 MEM
前递；S0 MEM 的乘法结果使用已寄存的 `mem_mul_result`；JAL/JALR 类写回
使用 PC+4，而不是控制目标或普通 ALU 结果。

当前可独立消融的网络组如下：

| 模型名 | RTL 数据方向 | 说明 |
|---|---|---|
| `id_s1_ex` | S1 EX → 四个 ID 操作数 | 最年轻普通前递源 |
| `id_s0_ex` | S0 EX → 四个 ID 操作数 | 含 fast ALU/特殊结果选择 |
| `id_s1_mem` | S1 MEM → 四个 ID 操作数 | load 除外 |
| `id_s0_mem` | S0 MEM → 四个 ID 操作数 | load 除外，含 MUL 结果 |
| `id_s1_wb` | S1 WB → 四个 ID 操作数 | 读优先寄存器堆所必需 |
| `id_s0_wb` | S0 WB → 四个 ID 操作数 | 读优先寄存器堆所必需 |
| `load_repair_s1_mem` | S1 MEM load → 下一拍 EX | load 数据修复标签 |
| `load_repair_s0_mem` | S0 MEM load → 下一拍 EX | load 数据修复标签 |
| `mul_s1_mem` | S1 MEM → MUL 本地输入 | DSP 旁的物理复制网络 |
| `mul_s0_mem` | S0 MEM → MUL 本地输入 | 含寄存 MUL product |
| `mul_s1_wb` | S1 WB → MUL 本地输入 | DSP 旁的物理复制网络 |
| `mul_s0_wb` | S0 WB → MUL 本地输入 | DSP 旁的物理复制网络 |
| `pair_s0_alu_to_s1_store_data` | 同发射对 S0 ALU → S1 store data | EX 内同拍旁路 |

普通网络之后的 ALU `PC/zero/imm` 选择已被 RTL 做成“各候选并行变换、最后
选择”，这是时序实现方式，不是额外的架构前递边。

## 2. 时钟沿与周期语义

edge x:

- 旧 WB 对寄存器堆执行双写，S1 WAW 优先于 S0。
- 旧 MEM 进入 WB，旧 EX 进入 MEM，满足握手的 ID 指令对进入 EX。

cycle x:

- 新 ID 指令组合读取寄存器堆。
- 普通前递网络同时匹配当前 EX/MEM/WB 的两个生产槽，并按
  `EX > MEM > WB`、同级 `S1 > S0` 选择。
- EX load 尚无数据，相关 ID 消费者等待。
- ready 的 MEM load 若消费指令支持修复，则 ID 携带 repair tag 前进；
  否则继续等待。
- 条件分支可以修复比较操作数；JIRL 还要用源寄存器形成重定向目标，不能
  使用这个晚一拍契约。
- S0 MUL 的 DSP 本地网络只接收 MEM/WB/RF；真实 EX RAW 必须等待一拍。

edge x+1:

- ready MEM load 的格式化数据写入 `wb_load_data_ex` 物理副本。
- 携带 repair tag 的消费者进入 EX。

cycle x+1:

- EX 在 ALU、分支比较、地址和 store data 的真实消费点，用
  `wb_load_data_ex` 替换带 repair tag 的源操作数。
- 同一发射对中的 S1 store data 可由 S0 ALU 结果覆盖。

## 3. 软件模型

`forwarding_model.cpp` 包含两层：

1. `evaluate_forwarding()`：组合级标准模型。全网络使能时复现
   `forwarding` 与 `mul_operand_forwarding` 的数据优先级、PC+4/MUL
   载荷选择、load repair tag 和 `id_ready_go`。
2. `ForwardingStudyModel`：理想前端的逐周期流水模型。它遵守当前双发射
   配对规则与上述 RAW 可用性，但假设预测 100%、Cache 始终 ready、无
   MMIO/结构冲突和 MDU backpressure。

差分模型不是简单让已删除路径落到旧值。若被删除路径承载当前最新版本，
模型会增加正确性 interlock，等到该版本到达仍存在的 MEM/WB/RF 路径后再
发射。否则测到的是静默错误率，而不是可实现 CPU 的性能。

每个差分模型只关闭上述 13 组中的一组。输出同时包含：

- 标准模型动态选中次数；
- S0/S1、rs1/rs2 的细分命中数；
- 删路后的新增等待周期；
- 同发射 store-data 旁路删除后损失的配对机会；
- 基线/差分总周期与 `delta_cpi`。

此外，基线把每条被选择的动态操作数边进一步拆成：物理网络、生产者 LA32R
指令、消费者槽位、消费者源操作数和消费者 LA32R 指令。该细分用于解释一条
物理网络服务了谁；删掉整条网络的真实周期代价仍以 13 个差分模型为准，不能
把细分命中次数直接当成周期收益。

### 3.1 连续型数据依赖

连续型依赖使用严格的动态定义 `A -> B -> C`：

1. B 的某个实际使用操作数选择了仍在同发射对、EX、MEM 或 WB 中的 A；
2. B 自身写非零 `rd`；
3. B 退休前又成为 C 某个实际使用操作数的 youngest writer。

每个流水 Token 保存最多两条输入依赖的动态 ordinal 和实际前递网络。寄存器
号相同但被更年轻写者覆盖、未使用的 rs 字段、以及 producer 退休后从 RF
读取都不计入。

主概率为：

```text
relay_probability =
    unique continuous middle B /
    in-flight consumers that write a non-zero rd
```

同时输出 `continuous_middle / instructions` 的程序密度、
`continuous_operand_edges / all_forwarding_operand_hits` 的网络流量占比、
链深度直方图，以及第一段网络 `A -> B` 与第二段网络 `B -> C` 的 13×13
矩阵。一个 B 即使服务多个 C，在 middle 指令数中仍只计一次；操作数流量和
矩阵按实际被选择的操作数边计数。

## 4. 运行

```bash
cmake -S 02_Design/model/cpp_arch_explorer \
      -B /tmp/cpp_arch_explorer_build \
      -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/cpp_arch_explorer_build -j16 \
      --target forwarding_study forwarding_model_tests
/tmp/cpp_arch_explorer_build/forwarding_model_tests

# 直接比较 RTL 与 C++ 标准模型，各运行 100000 组随机向量
02_Design/model/cpp_arch_explorer/scripts/run_forwarding_rtl_cosim.sh

/tmp/cpp_arch_explorer_build/forwarding_study \
    --perf-root ../chiplab/software/examples/nscscc_perf/obj \
    --output-dir /tmp/forwarding_study_results \
    --progress 100000000 \
    --jobs 12
```

若只测连续依赖概率而不重跑 13 个删路模型，添加 `--baseline-only`。该模式
只维护全网络标准模型，并保留链统计和细粒度路径统计。

先调试时可加 `--max-instructions 100000`。正式删路判断必须使用完整 20 程序，
并检查 `forwarding_per_program.csv`，不能只依据聚合平均值。

连续依赖输出为：

- `forwarding_chain_summary.csv`：逐程序和 `ALL` 的三种概率、原始计数、
  周期占用和链深度；
- `forwarding_chain_networks.csv`：每条前递网络作为第一段/第二段的参与度；
- `forwarding_chain_matrix.csv`：完整 13×13 第一段×第二段路径矩阵。
- `forwarding_detailed_paths.csv`：按生产者指令、消费者槽位/操作数/指令拆分
  的动态命中数和使用周期数。
- `dcache_raw_bypass.csv`：当前 64 KiB 直接映射 DCache 中，store hit 位于
  MEM、load 位于 EX 的相邻访问次数，以及真正同 word、需要 BRAM RAW 数据
  旁路的次数。删掉旁路后的代价按每次一拍 interlock 给出估计。

## 5. 可信边界

- 组合前递模型是 ISA 无关的；当前动态指令流驱动器执行 LA32R，并直接读取
  chiplab 的 20 个 `nscscc_perf` 镜像。UART 状态被抽象为始终可发送，其余未
  建模 MMIO 默认读零，因此它用于动态依赖与删路对比，不代表真实 SoC 周期。
- 模型故意不生成错误预测路径，不模拟 Cache/MMIO backpressure。
- DCache RAW 统计会按当前容量/映射重放架构访存并恢复相邻 EX/MEM 关系，
  但没有把 miss 延迟插回流水线；因此它适合判断该旁路是否罕见，不替代 RTL
  monitor 的精确周期计数。
- “命中少”不等于“适合删除”。还要比较删路后的 `extra_cycles`，以及 Vivado
  综合后的 WNS、Fmax、LUT、扇出和布线变化。
- 若删除普通路径，RTL 还必须增加与模型相同的 newest-writer interlock；
  只删 mux 输入会在存在更老同名写者时选择错误值。
