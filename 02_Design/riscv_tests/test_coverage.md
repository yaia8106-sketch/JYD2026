# 测试覆盖说明

本文记录默认回归中各测试程序覆盖的处理器行为。

## 默认回归规模

`run_all.sh` 默认运行 76 个测试：

- 38 个基础 RV32I/smoke 测试：`simple` + 官方 `rv32ui` 指令测试（不包含 `fence_i`）。
- 2 个综合访存测试：`ld_st`、`st_ld`。
- 3 个压力测试：`dcache_stress`、`counter_stress`、`bp_stress`。
- 24 个双发射、分支预测、DCache、RAS 相关测试。
- 1 个 RV32M 覆盖测试：`m_ext`。
- 8 个 Zicsr / Trap 测试：`zicsr_basic`、`zicsr_edge`、`csr_forwarding`、`csr_trap_stall`、`trap_mret`、`trap_slot1`、`trap_flush`、`trap_nested`。

## 基础 RV32I 指令测试

| 分类 | 测试 | 覆盖内容 |
|------|------|----------|
| ALU-R | `add`, `sub`, `and`, `or`, `xor`, `sll`, `srl`, `sra`, `slt`, `sltu` | 寄存器-寄存器运算，含 0、-1、符号位、溢出相关边界值 |
| ALU-I | `addi`, `andi`, `ori`, `xori`, `slli`, `srli`, `srai`, `slti`, `sltiu` | 寄存器-立即数运算，含立即数符号扩展和移位量 |
| Load | `lb`, `lbu`, `lh`, `lhu`, `lw` | 字节、半字、字读取，以及符号扩展/零扩展 |
| Store | `sb`, `sh`, `sw` | 字节、半字、字写入，以及写掩码 |
| Branch | `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu` | 正向/反向分支，taken/not-taken，带符号和无符号比较 |
| Jump | `jal`, `jalr` | 跳转目标、返回地址写入、JALR 低位清零 |
| Upper | `lui`, `auipc` | 高位立即数加载，AUIPC 相对 PC 计算 |
| Smoke | `simple` | 最小启动、执行、PASS 路径 |

## 综合访存测试

| 测试 | 覆盖内容 |
|------|----------|
| `ld_st` | 不同宽度 load/store 混合访问同一数据区，验证读取扩展和写掩码组合 |
| `st_ld` | store 后紧随 load，验证写入后可见性和 store/load 相关处理 |

## RV32M 扩展测试

| 测试 | 覆盖内容 |
|------|----------|
| `m_ext` | MUL/MULH/MULHSU/MULHU、DIV/DIVU、REM/REMU 的正负数、零、符号位、除零、`INT_MIN / -1` 溢出、结果前递、背靠背 M 指令、load 后 M 操作数、M 位于 Slot1 取指位置时顺序化、wrong-path M 指令清除 |

## 压力测试

### `dcache_stress`

| # | 场景 | 覆盖内容 |
|:-:|------|----------|
| 1 | Store 后立即 Load 同一 word | store buffer forwarding / 写后读可见性 |
| 2 | 同一 cache line 内不同 word 访问 | 行内多 word 数据保持 |
| 3 | 跨 set/tag 冲突访问 | 2-way 替换、refill、LRU 更新 |
| 4 | MMIO 读取夹在 cacheable 访问之间 | non-cacheable 访问不破坏 cacheable 数据 |
| 5 | 连续 store-load 循环 | store buffer drain 与连续写后读 |
| 6 | 分支跨过 cache miss 指令 | flush 与 pending cache 请求交互 |
| 7 | 多个 set 写入后逆序读回 | 多 set 状态保持和 refill 后读回 |

### `counter_stress`

| # | 场景 | 覆盖内容 |
|:-:|------|----------|
| 1 | 单次 LW -> ADDI -> SW -> LW | load-modify-store 基本链 |
| 2 | 多轮计数循环 | 热循环中的 cache 一致性和累积结果 |
| 3 | 循环后最终值检查 | 多次读写后的最终数据正确性 |
| 4 | 空操作后再次读回 | 流水线排空后的数据保持 |
| 5 | 函数调用栈操作与 DRAM 访问交错 | SP 相关访存、调用返回、普通 DRAM 访问组合 |

### `bp_stress`

| # | 场景 | 覆盖内容 |
|:-:|------|----------|
| 1 | tight loop 和嵌套 loop | 分支方向预测稳定性 |
| 2 | 奇偶交替、相关分支、多路 if-else | 方向模式切换和选择器行为 |
| 3 | 多级调用、递归、JALR 返回 | BTB、RAS、JALR 预测和返回修正 |
| 4 | load 后紧邻 branch、长分支链 | load-use、前递、分支 flush 组合 |

## 双发射测试

### 基础双发射

| 测试 | 覆盖内容 |
|------|----------|
| `dual_alu` | Slot0 ALU + Slot1 ALU 无 RAW 时双发射和双发计数 |
| `raw_block` | Slot1 读取 Slot0 写入目标时退化单发 |
| `branch_single` | load-use / inst_buf 后的 Slot1 branch 提交和 fall-through 清除 |
| `branch_dual` | Slot0 branch + Slot1 ALU 的 not-taken 双发和 taken 清除 |
| `branch_dual_flush` | Slot0 branch 误预测时，同包 Slot1 被同拍清除 |
| `branch_fwd_matrix` | 分支比较操作数来自 S0/S1 各级前递时的方向判断 |
| `branch_dual_edge` | 连续 branch/ALU 组合、taken/not-taken 切换、指令缓冲交互 |
| `slot1_branch` | Slot0 ALU + Slot1 branch 的 taken/not-taken；Slot0 LSU + Slot1 branch 退化单发 |
| `waw` | 同周期 WAW 下 Slot1 写回优先 |
| `loaduse_dual` | Slot0 load + 独立 Slot1 ALU 双发，以及后续 load-use stall |
| `inst_buffer` | 单发时 Slot1 进入指令缓冲，并在后续周期作为 Slot0 执行 |

### 前递与数据相关

| 测试 | 覆盖内容 |
|------|----------|
| `fwd_s1` | Slot1 写回结果在后续 S0/S1 的 EX、MEM、WB 前递路径 |
| `waw_fwd` | Slot0/Slot1 同写同一寄存器后的前递优先级和链式 WAW |
| `loaduse_cross` | 上一拍 Slot0 load 被下一拍 S0/S1 使用时的 stall 和冻结 |
| `slot1_load` | Slot0 普通 ALU + Slot1 load 共享单端口 LSU，覆盖 LB/LBU/LH/LHU/LW、双发计数和后续 load-use stall |
| `slot1_store` | Slot0 普通 ALU + Slot1 store 共享单端口 LSU，覆盖 SB/SH/SW、同包 RAW 顺序化、load-use stall、S0 LSU 顺序化和 MMIO store |
| `slot1_jal` | Slot0 普通 ALU + Slot1 JAL 共享延迟重定向路径，覆盖链接地址、fall-through flush、双发计数和 S0 LSU + S1 JAL 顺序化 |

### 指令缓冲与 Flush

| 测试 | 覆盖内容 |
|------|----------|
| `flush_instbuf` | 分支/JAL flush 时清空指令缓冲，避免错误路径指令执行 |
| `instbuf_stall` | 指令缓冲内容遇到 load-use stall、连续填充/消费和分支循环时保持正确 |

### 取指对齐与 Slot1 类型约束

| 测试 | 覆盖内容 |
|------|----------|
| `pc_align` | PC[2]=1 的取指窗口、非 8 字节对齐目标、Slot1 为 store/branch 时的发射约束和 Slot1 load 对齐场景 |
| `lui_auipc_s1` | LUI/AUIPC 位于 Slot1 时的操作数选择、PC 计算、结果前递和持续双发 |

### DCache、分支预测、Store Buffer、RAS 组合

| 测试 | 覆盖内容 |
|------|----------|
| `dcache_dual` | DCache miss/refill 期间的双发射保持、miss 后前递、store miss write-allocate |
| `bp_dual` | 误预测 flush 与双发循环、嵌套循环、JAL 返回点双发、背靠背分支组合 |
| `sb_stress` | store buffer 冲突 stall、连续 store 覆盖写、store 与双发 ALU 交错 |
| `ras_overflow` | RAS 容量内调用、超出容量后的返回修正，以及恢复后的再次调用 |

## Zicsr 与 Trap 测试

### 覆盖范围

Zicsr / Trap 测试覆盖 M 模式下的最小 CSR 与同步异常行为：

- 六类 Zicsr 指令语义：CSRRW、CSRRS、CSRRC、CSRRWI、CSRRSI、CSRRCI。
- `mstatus`：`MIE(bit3)`、`MPIE(bit7)` 的读写和 Trap/MRET 更新。
- `mtvec`：写入值读回保留，Trap 入口按 Direct 基址使用。
- `mscratch`：普通 32-bit 可读写暂存 CSR，支持完整读写和读改写。
- `mepc`：普通读写，以及 ECALL 时保存触发异常的指令地址。
- `mcause`：普通读写，以及 ECALL 时写入 M-mode environment call 原因 `11`。
- 未实现 CSR：读零，写忽略，不触发非法指令异常。
- 系统类指令顺序化：CSR、ECALL、MRET 只作为 Slot0 执行；位于 Slot1 位置时进入后续周期执行。
- 错误路径清除：被更老跳转/分支清除的 CSR、ECALL、MRET 不产生可见副作用。

这些测试不覆盖异步中断、Vectored Trap、多特权级切换、完整 `mstatus` 字段、计数类 CSR、非法指令异常和 `ebreak` Trap。

### 测试程序

| 测试 | 覆盖内容 |
|------|----------|
| `zicsr_basic` | Zicsr 六类基础读改写、旧值返回、零寄存器/零立即数字段语义、背靠背 CSR 可见性、`mscratch`、`mepc`、`mtvec` 基本读写、未实现 CSR 读零写忽略 |
| `zicsr_edge` | `mstatus` 写掩码，CSRRS/CSRRC 零源只读，常见未实现 CSR 读零写忽略，load-use 后 CSR 源操作数，CSR 位于 Slot1/指令缓冲时的顺序化，taken branch 后 wrong-path CSR 清除 |
| `csr_forwarding` | ALU 结果紧随写 CSR，CSR 旧值返回后紧随 ALU/branch 使用，CSR 读结果作为 store 数据、load 地址、store 地址和下一条 CSR 写源 |
| `csr_trap_stall` | 冷 DCache load 后紧随 CSR 写、ECALL、MRET 时，系统类指令等待更老访存完成后再提交或重定向 |
| `trap_mret` | ECALL 精确 Trap，`mepc/mcause/mstatus` 更新，handler 修改 `mepc` 后 MRET 返回，ECALL 后顺序指令不提前提交 |
| `trap_slot1` | ECALL 位于 Slot1 位置时顺序化后精确 Trap；handler 内 MRET 位于 Slot1 位置时顺序化后返回 |
| `trap_flush` | taken branch / JAL 后 wrong-path ECALL、MRET、`mtvec/mepc/mscratch` 写入被清除 |
| `trap_nested` | handler 内再次 ECALL，内层 Trap 覆盖 `mepc/mcause`，`mstatus.MIE/MPIE` 二次堆叠，两次 MRET 后返回外层指定目标 |

## 覆盖索引

| 场景 | 覆盖测试 |
|------|----------|
| S1 跨槽前递 | `fwd_s1` |
| WAW 前递优先级 | `waw_fwd` |
| Flush 清空指令缓冲 | `flush_instbuf` |
| PC[2]=1 取指窗口 / S1 类型约束 | `pc_align` |
| 跨对 load-use 与 S1 | `loaduse_cross` |
| Slot1 load 共享 LSU | `slot1_load` |
| Slot1 store 共享 LSU | `slot1_store` |
| Slot1 JAL 延迟重定向 | `slot1_jal` |
| LUI/AUIPC 在 S1 | `lui_auipc_s1` |
| DCache miss + 双发射 stall | `dcache_dual` |
| inst_buf + stall 交互 | `instbuf_stall` |
| BP 误预测 + 双发射循环 | `bp_dual` |
| Store buffer 冲突 stall | `sb_stress` |
| RAS 溢出与恢复 | `ras_overflow` |
| RV32M 乘除取余与边界条件 | `m_ext` |
| M 结果前递 / 背靠背 M / M wrong-path flush | `m_ext` |
| Zicsr 读改写与零源语义 | `zicsr_basic`, `zicsr_edge` |
| 未实现 CSR 读零写忽略 | `zicsr_basic`, `zicsr_edge` |
| CSR load-use / inst_buf / wrong-path flush 边界 | `zicsr_edge` |
| CSR 结果前递到 ALU/branch/store/load/CSR | `csr_forwarding` |
| CSR/ECALL/MRET 被前级 DCache miss stall 时保持和提交 | `csr_trap_stall` |
| ECALL/MRET 精确 Trap | `trap_mret` |
| ECALL/MRET 位于 Slot1 / 指令缓冲 | `trap_slot1` |
| wrong-path ECALL/MRET/关键 CSR 写入清除 | `trap_flush` |
| handler 内嵌套同步 Trap / `mstatus` 二次堆叠 | `trap_nested` |
