# 测试覆盖说明

> 记录每个测试用例验证了什么场景，方便定位 Cache/BP 相关 bug。

---

## 官方 RV32I 指令测试（37 个）

来自 [riscv-tests](https://github.com/riscv-software-src/riscv-tests) `isa/rv32ui/`。

| 分类 | 测试 | 验证内容 |
|------|------|----------|
| ALU-R | `add`, `sub`, `and`, `or`, `xor`, `sll`, `srl`, `sra`, `slt`, `sltu` | 寄存器-寄存器运算，含边界值（0, -1, 溢出） |
| ALU-I | `addi`, `andi`, `ori`, `xori`, `slli`, `srli`, `srai`, `slti`, `sltiu` | 寄存器-立即数运算，含符号扩展 |
| Load | `lb`, `lbu`, `lh`, `lhu`, `lw` | 各宽度读取 + 符号/零扩展 |
| Store | `sb`, `sh`, `sw` | 各宽度写入 + 字节选通（WEA） |
| Branch | `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu` | 正向/反向跳转，taken/not-taken，含边界比较 |
| Jump | `jal`, `jalr` | 跳转 + 链接寄存器写入，含 JALR 低位清零 |
| Upper | `lui`, `auipc` | 高位立即数加载，AUIPC 相对 PC 计算 |
| Misc | `simple` | 最小 smoke test |

每个测试含多个 case，自然产生前递、flush、stall 场景。

---

## 自定义综合测试

| 测试 | 来源 | 验证内容 |
|------|------|----------|
| `ld_st` | 官方补充 | 不同宽度混合读写同一地址，字节选通正确性 |
| `st_ld` | 官方补充 | Store 后立即 Load，验证 forwarding / store buffer |

---

## 自定义压力测试（`custom_tests/`）

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

### Phase3 dual-issue tests

| 测试 | 验证重点 |
|------|----------|
| `dual_alu` | 对齐 ALU+ALU 无 RAW 时 Slot1 提交，计数器递增 |
| `raw_block` | inst1 读取 inst0 的 rd 时退化单发，计数器不增 |
| `branch_single` | Slot0 branch 不双发，taken 后 fall-through 不提交 |
| `waw` | 同周期 WAW 不阻止双发，Slot1 写回优先 |
| `loaduse_dual` | Slot0 load + 独立 Slot1 ALU 可双发，后续 load-use stall 正确 |
| `inst_buffer` | 单发时 slot1 进入缓冲，下拍作为 slot0 执行且不丢失 |

---

## 丢失的测试（待重写）

源码已丢失，仅保留 `.dump` 反汇编（在 `work/hex/` 下）。

| 测试 | 原始目的 | dump 文件 |
|------|----------|-----------|
| `bp_stress` | 分支预测压力：简单循环、嵌套循环、交替方向、多级函数调用、JALR 间接跳转、递归、beqz 长链、Fibonacci、混合分支模式 | `rv32ui-p-bp_stress.dump` |
| `coprime` | 互质计算（GCD 算法），测试深度嵌套分支 + 循环 | `rv32ui-p-coprime.dump` |
| `dcache_test` | DCache 功能测试（与 dcache_stress 可能重叠） | `rv32ui-p-dcache_test.dump` |

---

## 覆盖盲区（已知未测试）

| 场景 | 风险 | 建议 |
|------|------|------|
| DCache refill 期间 branch flush | 高——曾出 bug | dcache_stress #6 部分覆盖，但未测 refill 中途 flush |
| BTB 非分支指令误预测 + Load | 高——曾出 bug | 已修复但无专项回归测试 |
| Store buffer 满时的 stall | 中——buffer 仅 1 entry | counter_stress 部分覆盖 |
| 连续多个 cache miss（pipeline stall 叠加） | 中 | dcache_stress #7 部分覆盖 |
| RAS 溢出（调用深度 > 4） | 低——RAS 4-deep 足够 | bp_stress 已丢失 |
