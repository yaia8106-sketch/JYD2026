# 测试覆盖说明

> 记录每个测试用例验证了什么场景，方便定位 Cache/BP 相关 bug。

---

## `run_all.sh` 当前覆盖规模

当前回归入口运行 64 个测试：

- 38 个基础 RV32I/smoke 测试：`simple` + 官方 `rv32ui` 指令测试（去掉 `fence_i`）。
- 2 个综合访存测试：`ld_st`、`st_ld`。
- 3 个压力测试：`dcache_stress`、`counter_stress`、`bp_stress`。
- 21 个自定义双发射 / BP / DCache / RAS 测试。

`riscv-tests/isa/rv32ui/` 中还保留 `ma_data.S`，`work/hex/` 中也有若干只有 hex 生成物的旧测试，但它们不在当前 `run_all.sh` 默认回归集中。

---

## 基础 RV32I 指令测试（38 个）

来自 [riscv-tests](https://github.com/riscv-software-src/riscv-tests) `isa/rv32ui/`，当前默认回归去掉 `fence_i`，保留 `simple` smoke test。

| 分类 | 测试 | 验证内容 |
|------|------|----------|
| ALU-R | `add`, `sub`, `and`, `or`, `xor`, `sll`, `srl`, `sra`, `slt`, `sltu` | 寄存器-寄存器运算，含边界值（0, -1, 溢出） |
| ALU-I | `addi`, `andi`, `ori`, `xori`, `slli`, `srli`, `srai`, `slti`, `sltiu` | 寄存器-立即数运算，含符号扩展 |
| Load | `lb`, `lbu`, `lh`, `lhu`, `lw` | 各宽度读取 + 符号/零扩展 |
| Store | `sb`, `sh`, `sw` | 各宽度写入 + 字节选通（WEA） |
| Branch | `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu` | 正向/反向跳转，taken/not-taken，含边界比较 |
| Jump | `jal`, `jalr` | 跳转 + 链接寄存器写入，含 JALR 低位清零 |
| Upper | `lui`, `auipc` | 高位立即数加载，AUIPC 相对 PC 计算 |
| Smoke | `simple` | 最小 smoke test |

每个测试含多个 case，自然产生前递、flush、stall 场景。

---

## 自定义综合测试

| 测试 | 来源 | 验证内容 |
|------|------|----------|
| `ld_st` | 官方补充 | 不同宽度混合读写同一地址，字节选通正确性 |
| `st_ld` | 官方补充 | Store 后立即 Load，验证 forwarding / store buffer |

---

## 自定义压力测试

### dcache_stress.S

覆盖 DCache 边界场景。**曾直接捕获 BTB 误预测导致 DCache 数据损坏的 bug。**

| # | 场景 | 验证重点 |
|:-:|------|----------|
| 1 | Store→立即 Load（同 word） | Store buffer forwarding / WT 可见性 |
| 2 | Store→Load（同 line 不同 word） | 行内多 word 一致性 |
| 3 | 跨 set 冲突（stride=1KB，触发 evict） | 2-way LRU 替换 + refill 正确性 |
| 4 | MMIO 读夹在 cacheable 操作间 | non-cacheable 不破坏 cache 状态 |
| 5 | 100 次连续 store-load 循环 | Store buffer drain 时序 |
| 6 | Branch 跨过 cache miss 指令 | flush 不破坏 pending cache 请求 |
| 7 | 4 个不同 set 写入→逆序读回 | 多 set 并发 miss |

### counter_stress.S

模拟真实程序的 load-modify-store 模式。

| # | 场景 | 验证重点 |
|:-:|------|----------|
| 1 | 单次 LW→ADDI→SW→LW | 冷启动 miss→refill→回读 |
| 2 | 循环 36 次 increment | 热循环中 cache 一致性 |
| 3 | 最终值校验（期望 37） | 累积误差检测 |
| 4 | 8 个 NOP 后读回 | 流水线排空后 cache 仍有效 |
| 5 | 函数调用栈操作 + DRAM 读取 | SP 操作与 DRAM 读交错 |

### bp_stress.S

分支预测压力测试，源码当前保留在 `riscv-tests/isa/rv32ui/bp_stress.S`。

| # | 场景 | 验证重点 |
|:-:|------|----------|
| 1 | 简单 tight loop / 嵌套 loop | BHT/PHT 训练后的稳定预测 |
| 2 | 奇偶交替、相关分支、多路 if-else | 方向模式切换与 selector 行为 |
| 3 | 多级函数调用、递归、JALR 间接跳转 | BTB / RAS / JALR 预测与返回修正 |
| 4 | load 后紧邻 branch、长 beqz 链 | load-use、前递、分支 flush 的组合场景 |

### 双发射基础测试（10 个）

| 测试 | 验证重点 |
|------|----------|
| `dual_alu` | 对齐 ALU+ALU 无 RAW 时 Slot1 提交，计数器递增 |
| `raw_block` | inst1 读取 inst0 的 rd 时退化单发，计数器不增 |
| `branch_single` | Slot0 taken branch 后 fall-through 不提交，双发计数器不误增 |
| `branch_dual` | **Branch+ALU 双发优化**：not-taken branch + ALU 计数器递增；cold taken branch 即使顺序取指也必须杀掉同包 Slot1 |
| `branch_dual_flush` | Slot0 branch 与 Slot1 ALU 同包时，EX 级误预测 flush 必须同拍杀掉 Slot1，防止错误路径写回 |
| `branch_fwd_matrix` | Branch 比较操作数来自 S0/S1 各级前递时，方向判断和 redirect 仍正确；覆盖分支比较前递矩阵 |
| `branch_dual_edge` | 分支双发边界场景：连续 branch/ALU 组合、taken/not-taken 切换和指令缓冲交互 |
| `waw` | 同周期 WAW 不阻止双发，Slot1 写回优先 |
| `loaduse_dual` | Slot0 load + 独立 Slot1 ALU 可双发，后续 load-use stall 正确 |
| `inst_buffer` | 单发时 slot1 进入缓冲，下拍作为 slot0 执行且不丢失 |

### 双发射补充测试（11 个）

针对基础测试未覆盖的关键盲区，按风险等级补充。

#### 前递与数据通路（3 个）

| 测试 | 验证重点 |
|------|----------|
| `fwd_s1` | **S1 跨槽前递**：S1 写 rd → 下一对 S0/S1 通过前递读取。分 4 部分分别测试 S1\_EX→S0/S1、S1\_MEM→S0/S1、S1\_WB→S0/S1、以及 S1\_EX 优先级高于 S0\_MEM 的正确性 |
| `waw_fwd` | **WAW 前递优先级**：S0 与 S1 同时写同一 rd 后，后续指令通过前递读回，验证 S1\_EX > S0\_EX 优先级在 EX/MEM/WB 三阶段均正确。含链式 WAW（连续两对双写） |
| `loaduse_cross` | **跨对 load-use 与 S1**：上一拍 S0 load → 本拍 S1.rs1 或 S1.rs2 依赖 load 结果 → 必须触发 stall。同时验证 S0 stall 时 S1 被正确冻结 |

#### 指令缓冲与 Flush（2 个）

| 测试 | 验证重点 |
|------|----------|
| `flush_instbuf` | **Flush 清空指令缓冲**：sw 单发→S1 入 buf→正常消费；beq taken→buf 中指令必须丢弃（不执行）；jal→buf 清空。若 buf 未清，错误路径指令会写入寄存器 |
| `instbuf_stall` | **指令缓冲 + 流水线 stall 交互**：sw→S1 缓冲→缓冲指令是 lw→下一拍 load-use stall→缓冲内容必须存活；快速 sw→buf→消费→sw→buf 连续填充-消费链；BP 循环中反复触发缓冲 |

#### 取指对齐与 S1 类型约束（2 个）

| 测试 | 验证重点 |
|------|----------|
| `pc_align` | **PC\[2\]=1 取指窗口**：分支跳转到非 8 字节对齐地址时仍需取到 `{PC+4, PC}` 并按序执行。同时测试 S1 位置为 load/store/branch 时阻止双发，以及 S1 位置为 branch 时正确进入 inst\_buf 并在下一拍作为 S0 执行 |
| `lui_auipc_s1` | **LUI/AUIPC 在 Slot1**：LUI/AUIPC 属于 ALU-type 但使用特殊操作数选择（alu\_src1=0/PC），验证 S1 解码器和 ALU 源 MUX 正确处理。含 AUIPC 精确 PC 值校验、LUI 结果前递给后续 sw、以及 8 对连续双发的持续吞吐压力测试 |

#### DCache 与分支预测交互（2 个）

| 测试 | 验证重点 |
|------|----------|
| `dcache_dual` | **DCache miss + 双发射 stall**：3 个同 set 不同 tag 的 store 驱逐 cache way → lw(miss) + addi(S1) 双发 → refill 期间 S1 流水线寄存器必须保持。第二部分验证 miss 恢复后 S1 结果能被后续指令正确前递。第三部分测试 write-allocate 路径的 store miss |
| `bp_dual` | **BP 误预测 + 双发射循环**：紧凑循环体内 ALU 双发 + 出口误预测 flush 两个 slot；嵌套循环 + 双发对累加器；JAL 子程序调用后返回点执行双发对并校验 ra；背靠背 branch→双发→branch 连续切换 |

#### Store Buffer 与 RAS（2 个）

| 测试 | 验证重点 |
|------|----------|
| `sb_stress` | **Store buffer 冲突 stall**：连续两次 store 命中同一 cache line → `sb_conflict` → S\_SB\_DRAIN 额外 stall 周期；三连 store（含覆盖写）验证 last-store-wins；store + 双发 ALU + store 交错场景 |
| `ras_overflow` | **RAS 溢出恢复**：4 层嵌套调用（RAS 容量内）验证正常返回；6 层嵌套（溢出 2 层）验证 `branch_flush` 纠正错误 RAS 预测后仍能正确返回；溢出恢复后再做 2 层调用验证 RAS 状态正常 |

---

## 丢失的测试（待重写）

源码已丢失，仅保留 `.hex` 生成物（在 `work/hex/` 下）；这些测试不在当前 `run_all.sh` 默认回归集中。

| 测试 | 原始目的 | 保留生成物 |
|------|----------|-----------|
| `coprime` | 互质计算（GCD 算法），测试深度嵌套分支 + 循环 | `rv32ui-p-coprime.{irom,dram}.hex` |
| `dcache_test` | DCache 功能测试（与 dcache_stress 可能重叠） | `rv32ui-p-dcache_test.{irom,dram}.hex` |

---

## 覆盖盲区

| 场景 | 风险 | 状态 |
|------|------|------|
| S1 跨槽前递 (EX/MEM/WB) | 高 | ✅ `fwd_s1` 覆盖 |
| WAW 前递优先级 | 高 | ✅ `waw_fwd` 覆盖 |
| Flush 清空指令缓冲 | 高 | ✅ `flush_instbuf` 覆盖 |
| PC[2]=1 取指窗口 / S1 类型约束 | 高 | ✅ `pc_align` 覆盖 |
| 跨对 load-use 与 S1 | 中 | ✅ `loaduse_cross` 覆盖 |
| LUI/AUIPC 在 S1 | 低 | ✅ `lui_auipc_s1` 覆盖 |
| DCache miss + 双发射 stall | 高 | ✅ `dcache_dual` 覆盖 |
| inst_buf + stall 交互 | 中 | ✅ `instbuf_stall` 覆盖 |
| BP 误预测 + 双发射循环 | 中 | ✅ `bp_dual` 覆盖 |
| Store buffer 冲突 stall | 中 | ✅ `sb_stress` 覆盖 |
| RAS 溢出（调用深度 > 4） | 低 | ✅ `ras_overflow` 覆盖（6 层嵌套） |
| Branch 比较前递矩阵 | 高 | ✅ `branch_fwd_matrix` 覆盖 |
| Branch+Slot1 同拍 flush 边界 | 高 | ✅ `branch_dual_flush` / `branch_dual_edge` 覆盖 |
| DCache refill 期间 branch flush | 高——曾出 bug | ✅ 架构上不可能：`ex_branch_flush` 被 `mem_allowin` 门控，cache miss 期间 flush 被延迟到 refill 完成后。`dcache_dual` 已隐式覆盖此延迟 flush 行为 |
| BTB 非分支指令误预测 + Load | 高——曾出 bug | ⚠️ 无法在小测试中复现：BTB alias 需 `PC[13:2]` 完全匹配（16KB 代码间距），小程序无法构造。修复已在 RTL 中（`cache_req` 不门控 `branch_flush`），真实程序上板时隐式覆盖 |
| FPGA 时序 / 上板约束 | 高 | ❌ 仿真无法覆盖，使用 `03_Timing_Analysis/run_vivado_flow.tcl` 生成时序报告；物理板使用 `PhysicalTwin_XC7A35T/run_build.sh` |
