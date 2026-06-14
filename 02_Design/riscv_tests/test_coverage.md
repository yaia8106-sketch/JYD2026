# 测试覆盖说明

本文记录默认回归中各测试程序覆盖的处理器行为。

脚本入口分类见 `SCRIPT_CLASSIFICATION.md`。简要原则：

- `functional/run_all.sh` 属于常规功能正确性 / smoke 入口。
- `functional/special/run_axi_adapter.sh`、`functional/special/run_student_top_axi.sh`、`functional/special/run_student_top_smoke.sh` 属于特殊功能正确性 smoke。
- `performance/short/run_perf.sh`、`performance/long/run_coe_perf.sh` 属于性能 / 长跑 / COE 入口，不作为默认 smoke gate。
- `performance/branch/run_branch_diag.sh` 属于性能诊断入口，聚焦分支预测，不作为默认 smoke gate。
- 新增 correctness case 应进入 `run_all.sh` 体系；性能实验和 COE 检查不要混入短功能回归。

## 默认回归规模

`functional/run_all.sh` 默认配置为运行 4 个 RTL 定向测试和 81 个处理器程序。
这里描述的是覆盖规模，不等同于当前工作区已经通过这些测试。

- 1 个双 bank ABTB 定向测试：命中、未命中、更新、2-way LRU
  替换、同 set 别名、slot 屏蔽、双 CFI 程序顺序选择、错误路径 LRU
  屏蔽、所有 bank/way 的 CFI 候选、重复 tag 的 way0 优先、由 update PC
  自动选 bank，以及查询/更新同周期冲突和 update LRU 优先级。
- 1 个 Stage-1 direction 单模块测试：8-bit committed GHR、256-entry
  2-bit PHT、bank0/bank1 PC/GHR hash、四状态 taken/not-taken 饱和、GHR
  shift、无 confirmed update 时保持、无 write-to-read bypass 的边沿可见性和
  8-bit index alias，以及同一 PHT row 多个在途分支使用 prediction-time
  counter snapshot 训练时可能丢失精度更新的已知风险。
- 1 个 `cpu_top` ABTB 影子集成测试：slot0 JAL/bank0、slot1
  CALL/bank1、prediction-time hit/way metadata 到 EX、miss allocation 与 hit
  update、taken/not-taken branch 写入资格、RET hint、普通间接 JALR 忽略、
  redirecting CFI 同周期训练、错误路径年轻指令抑制、FTQ/FQ stall metadata
  保持、slot0 taken/JAL/JALR/redirect kill slot1 时 sidecar metadata 不泄漏
  到后续有效 dequeue、stall/redirect/FQ wrap-around 覆盖，以及
  reset/invalid 不更新。该集成测试验证 ABTB shadow metadata 和 EX 训练链路；
  `frontend_abtb.pred_next_pc` 仍不接真实 steering。泄漏检查以物理 FQ entry
  为身份：reference model 只跟随真实 even/odd sidecar write，按 head parity/row
  对有效 dequeue 比较 hit/way；redirect 后同一 PC 合法 refetch 不会再误判为
  killed slot 泄漏。
- 1 个 `frontend_ftq` pair-policy 定向测试：同 fetch block 双发、
  cross-packet pairing、slot0/slot1 RAW（rs1/rs2）、`rd=x0` 不形成 RAW、
  force-single、pred-taken 抑制、ALU+ALU、ALU+load、ALU+store、ALU+JAL、
  non-control+branch、不支持 pair 类型、slot0 JAL/JALR/system kill slot1、
  stall 后 pair 信息保持、redirect 清除旧 pair 信息、FQ wrap-around、
  同 PC redirect 后合法 refetch、enqueue/dequeue 同周期，以及
  cross-packet follower 被后续 overwrite。
- 38 个基础 RV32I/smoke 测试：`simple` + 官方 `rv32ui` 指令测试（不包含 `fence_i`）。
- 2 个综合访存测试：`ld_st`、`st_ld`。
- 4 个压力测试：`dcache_stress`、`axi_backend_stress`、`counter_stress`、`bp_stress`。
- 27 个双发射、分支预测、DCache、RAS 相关测试。
- 1 个 RV32M 覆盖测试：`m_ext`。
- 9 个 Zicsr / Trap / Timer 测试：`zicsr_basic`、`zicsr_edge`、`csr_forwarding`、`csr_trap_stall`、`trap_mret`、`trap_slot1`、`trap_flush`、`trap_nested`、`timer_irq_basic`。

2026-06-12 FTQ pair eligibility 收敛轮记录：VCS license 已恢复并实际运行。
`functional/run_all.sh` 中 ABTB standalone、ABTB shadow integration、FTQ
pair-policy 定向测试均 PASS，CPU functional regression 为 81/81 PASS。

VCS integration 覆盖计数为
64 次 slot1 kill、35 次 JAL、3 次 JALR、1 次 taken branch、195 次偶 head、
183 次奇 head、92 次单 entry dequeue、276 次双 entry dequeue、10 次 stall、
26 次 redirect、10 次同 PC 合法 refetch 和 30 个 EX update token。

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

### `axi_backend_stress`

| # | 场景 | 覆盖内容 |
|:-:|------|----------|
| 1 | store hit 后 load hit | DCache 基本写后读可见性 |
| 2 | byte store 后 evict/refill | 后端 byte strobe、store buffer 写回、重填后数据保持 |
| 3 | halfword store 后 evict/refill | 后端 halfword strobe、非整字写回和重填 |
| 4 | cache line 最后一个 word miss | refill final beat forwarding |
| 5 | 背靠背 store 后 evict/refill | store buffer drain 排序、多个写回后外存可见性 |

### `dcache_wna_edge`

| # | 场景 | 覆盖内容 |
|:-:|------|----------|
| 1 | cold SB store miss 后立即 LW 同 word | WT+WNA store miss 不分配，load refill 按 byte mask 合并 pending SB |
| 2 | SH store miss 到同 line 不同 word，随后 LW 另一个 word | refill merge 不能污染非目标 word |
| 3 | refill 完成后读取被 SH 修改的 word | pending SB 在非请求 beat 上也会合并进 cache line |
| 4 | SW store miss 到 line 最后一个 word | final refill beat forwarding 必须转发合并后的数据 |
| 5 | 两个 store miss 连续进入 2-entry SB，随后 LW 同 line | refill 同时合并两个 pending store，覆盖不同 word 的可见性 |
| 6 | 同 word 的 SW 后接 SB，随后第三个 store 在 SB full 时到达 | full 后 drain/stall/retry、年轻 store byte 覆盖老 store、第三个 store 继续参与 refill merge |

### `functional/special/run_student_top_axi.sh`

该脚本不是 `functional/run_all.sh` 默认回归的一部分，而是处理器侧 AXI master 集成 smoke：

| 场景 | 覆盖内容 |
|------|----------|
| DCache miss/refill | `student_top_axi -> dcache_axi_backend -> axi_master_adapter` 发出 AXI read burst |
| Store buffer drain | cacheable store 经 AXI AW/W/B 写回，带 `WSTRB` |
| 本地 MMIO | LED/SW/SEG/timer 地址保持在 `mmio_bridge`，不产生 AXI AR/AW |
| AXI transaction shape | read 使用 4-beat INCR burst，write 当前为 single-beat INCR |

### `functional/special/run_student_top_smoke.sh`

该脚本不是 `functional/run_all.sh` 默认回归的一部分，而是 `student_top` 板级封装短 smoke：

| 场景 | 覆盖内容 |
|------|----------|
| `simple` | `student_top -> cpu_top -> mmio_bridge -> virtual_led` 的最小 PASS 路径 |
| `dcache_stress` | `student_top` 封装下的 DCache、DRAM IP model、store buffer、MMIO 混合访问 |
| LED pass/fail | 监控 `0x8020_0040` LED MMIO 写，`1` 为 PASS，非零非 `1` 为 FAIL |
| IP model wiring | 使用 `student_top_ip_models.sv` 替代 Vivado IROM/DRAM IP，验证仿真接线没有断裂 |

### `bp_stress`

| # | 场景 | 覆盖内容 |
|:-:|------|----------|
| 1 | tight loop 和嵌套 loop | 分支方向预测稳定性 |
| 2 | 奇偶交替、相关分支、多路 if-else | 方向模式切换和选择器行为 |
| 3 | 多级调用、递归、JALR 返回 | BTB、RAS、JALR 预测和返回修正 |
| 4 | load 后紧邻 branch、长分支链 | load-use、前递、分支 flush 组合 |

### Branch Predictor Diagnosis Microbenchmarks

这些程序由 `utility/build_tests.sh` 生成 hex，主要由 `performance/branch/run_branch_diag.sh` 使用；必要时也可用 `run_perf.sh --set branch_diag` 做短 profiling。它们不属于 `functional/run_all.sh` 默认 correctness gate。

| 测试 | 诊断意图 |
|------|----------|
| `bp_s0_taken_loop` | 单个 S0 backward branch 的 taken 方向收敛，定位 high-BTB-hit 但持续 underpredict taken 的问题 |
| `bp_s0_not_taken_loop` | 同一 S0 branch 反复 not-taken，观察 overpredict taken / dir_to_fallthrough |
| `bp_s0_alternating` | 同一 S0 branch 交替 taken/not-taken，观察方向预测是否单边塌陷 |
| `bp_btb_alias_pair` | 两个相隔 512B 的 taken branch 故意映射到同一 direct-mapped BTB index，隔离 alias/capacity 行为 |
| `bp_wrongpath_pollution` | older taken branch 跳过 victim branch，随后正确路径 probe 同一 victim PC，配合 trace 检查 wrong-path update 污染 |

### ABTB Stage-1 Direct Steering

`tb_frontend_abtb_steering.sv` 在 `ABTB_DIRECT_STEERING` build 下运行，
通过真实 EX confirmed training 建表，不层次化强写 ABTB/PHT/FQ 数组。direct
模式 28 个定向场景覆盖：

- cold miss legacy fallback、训练后 hit、bank0/bank1 JAL steering；
- `pc[2]=1` 时 bank1 作为第一条、JAL/JALR CALL 分类；
- 普通间接 JALR、B、RET 不由 ABTB steering；
- 双 bank 程序顺序、legacy 第一条 taken 压制 bank1；
- 同指令 ABTB/legacy target 冲突、stale target redirect/retrain；
- 正确 target 不产生多余 redirect、slot0 kill slot1、slot1 metadata 绑定；
- stall、redirect 后同 PC 合法 refetch、FQ wrap-around；
- redirect 与 ABTB update 同周期、older slot0 抑制 younger slot1。
- TYPE_BRANCH 的 PHT taken 结果保持 shadow，不改变 canonical PC；
- slot1 branch 携带 prediction-time PHT index/counter 到 EX；
- redirect 同周期更新 GHR且后续不恢复；
- older slot0 redirect 抑制 wrong-path slot1 PHT/GHR 更新；
- backend stall 保持 branch metadata，释放时只训练一次。

在额外定义 `ABTB_BRANCH_STEERING` 时，ABTB branch hit 会产生独立的
per-slot `stage1_branch_owned`。该 bit 表示 Stage-1 拥有该 branch 的方向预测，
不等同于仅表示 taken next-PC 来源的 `pred_source_abtb`。branch 模式额外覆盖：

- PHT taken branch hit 拥有 Stage-1 steering 并使用 ABTB target；
- PHT not-taken branch hit 保留 ownership，同时继续选择更年轻的 bank1 direct CFI；
- `TYPE_RET` 仍保持 legacy-only；
- owned bank0 branch 在程序顺序上压制 bank1 ABTB；
- owned branch metadata 在 backend stall 下保持，释放后只 confirmed update 一次。

`tb_frontend_ftq_canonical.sv` 的 4 个 direct-mode case 专门覆盖 canonical 单一事实源：
legacy NT + bank1 ABTB 被 BP1 改判 taken、legacy taken + bank1 ABTB 被改判
not-taken、first-instruction ABTB direct 不受 BP1 覆盖，以及 BP1 与 EX redirect
同周期时 EX 优先。first-instruction direct 场景还把 shadow `pred_taken` 固定为
0，证明 J/CALL steering 只依赖 raw tag hit/type/target，不依赖 PHT direction。
第二个场景同时覆盖 frontend stall 和 FQ metadata 一致性。

`ABTB_BRANCH_STEERING` build 下 canonical test 扩展为 7 个 case，新增 owned
taken branch 忽略 legacy/BP1 并 kill slot1、owned not-taken branch 继续选择
younger bank1 direct、双 owned not-taken branch 保持 per-slot ownership。

验证入口：

- VCS: `functional/frontend/run_steering.sh`
- direct CPU 81 项回归: `functional/run_all_abtb_direct.sh`
- branch steering CPU 81 项回归: `functional/run_all_abtb_branch.sh`

2026-06-14 结果：direct VCS 28 cases PASS；branch VCS 29 cases PASS；
canonical direct VCS 4 cases PASS；canonical branch VCS 7 cases PASS；
PHT/GHR VCS 9 cases PASS；direct CPU `81/81 PASS`；branch steering CPU
`81/81 PASS`。

2026-06-14 branch-focused profiling 使用
`performance/short/run_perf.sh --set branch_diag` 跑 19 个 RV32UI/微基准：
legacy、direct 和 branch steering 三种配置均为 19/19 PASS。该入口还验证
`legacy_fallback` 已排除 ABTB-owned not-taken branch，并新增
`stage1_abtb_owned` / `stage1_branch_owned_nt` 计数进入 CSV/JSON。
`stage1_abtb_owned` 是 canonical fetch block 级 ownership/selection 计数，
不是 per-slot CFI 数量；一个 block 最多增加一次。

`ABTB_BRANCH_REGISTERED_BP1_REDIRECT` 实验配置复用同一组 canonical case，
但把 BP1 correction 分成 pending edge 和下一拍 frontend override。VCS
canonical 7 cases、ABTB steering 29 cases 均 PASS；direct、branch、
registered-branch 三种 CPU 配置分别为 `81/81 PASS`。

同日四组 `branch_diag` 短 profiling 均为 19/19 PASS。registered-branch 与
未注册 branch 都是 `15273` cycles、IPC `0.7261`、mispredict `847`、
frontend redirect `772`。该 workload 在 branch steering 下记录的
`fe_bp1_applicable/override/redirect` 均为 0，因此相同结果只说明此测试集没有
触发 registered BP1 correction；多一拍 correction 代价由 canonical TB 定向
覆盖，不能从这组性能结果推断为零开销。

同日 5 ns whole-chip post-route 对比中，未注册 branch steering 为
WNS `-2.085 ns`、TNS `-2851.934 ns`，最差路径是 IROM 到
`current_pc_reg[7]/D`，data delay `7.099 ns`、12 levels。registered-BP1
实验为 WNS `-0.677 ns`、TNS `-115.199 ns`；IROM 到 `current_pc[D]`
已无可报告路径，最差路径转移到 IROM 到
`bp1_redirect_target_r[11]/CE`，data delay `5.448 ns`、9 levels。
registered override 到 `current_pc[D]` 为 `+1.160 ns`，IROM 到
`fq_pair_ok` 为 `-0.415 ns`。结果证明架构路径已切断，但整机仍未满足
5 ns 约束，因此该宏继续保持实验配置。

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
| `dcache_dual` | DCache miss/refill 期间的双发射保持、miss 后前递、store miss WNA 与 load refill 合并 |
| `dcache_wna_edge` | WT+WNA store miss 的 byte/half/word refill 合并、非目标 word 不污染、2-entry SB 满时 drain/retry 和年轻 store 覆盖 |
| `bp_dual` | 误预测 flush 与双发循环、嵌套循环、JAL 返回点双发、背靠背分支组合 |
| `sb_stress` | store buffer 冲突 stall、连续 store 覆盖写、store 与双发 ALU 交错 |
| `ras_overflow` | RAS 容量内调用、超出容量后的返回修正，以及恢复后的再次调用 |

## Zicsr 与 Trap 测试

### 覆盖范围

Zicsr / Trap 测试覆盖 M 模式下的最小 CSR、同步异常与机器定时器中断行为：

- 六类 Zicsr 指令语义：CSRRW、CSRRS、CSRRC、CSRRWI、CSRRSI、CSRRCI。
- `mstatus`：`MIE(bit3)`、`MPIE(bit7)` 的读写和 Trap/MRET 更新。
- `mtvec`：写入值读回保留，Trap 入口按 Direct 基址使用。
- `mscratch`：普通 32-bit 可读写暂存 CSR，支持完整读写和读改写。
- `mepc`：普通读写，以及 ECALL 时保存触发异常的指令地址。
- `mcause`：普通读写，ECALL 时写入 M-mode environment call 原因 `11`，机器定时器中断时写入 `0x80000007`。
- `mie/mip`：`mie.MTIE(bit7)` 读写，`mip.MTIP(bit7)` 反映 timer pending 状态。
- 机器定时器：`mtime/mtimecmp` MMIO pending、`mstatus.MIE`/`mie.MTIE` 屏蔽、精确中断入口和 MRET 返回。
- 未实现 CSR：读零，写忽略，不触发非法指令异常。
- 系统类指令顺序化：CSR、ECALL、MRET 只作为 Slot0 执行；位于 Slot1 位置时进入后续周期执行。
- 错误路径清除：被更老跳转/分支清除的 CSR、ECALL、MRET 不产生可见副作用。

这些测试不覆盖 Vectored Trap、多特权级切换、完整 `mstatus` 字段、除 MTIE/MTIP 之外的中断源、计数类 CSR、非法指令异常和 `ebreak` Trap。

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
| `timer_irq_basic` | `mtime/mtimecmp` 产生 MTIP，`mstatus.MIE`/`mie.MTIE` 屏蔽与使能，机器定时器中断写入 `mcause=0x80000007`，`mepc` 指向等待循环内未执行指令，handler 清 `mie` 后 MRET 返回 |

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
| WT+WNA store miss/refill merge 边界 | `dcache_wna_edge` |
| inst_buf + stall 交互 | `instbuf_stall` |
| BP 误预测 + 双发射循环 | `bp_dual` |
| Store buffer 冲突 stall | `sb_stress` |
| DCache 后端 byte/half/word 写回和 refill final beat | `axi_backend_stress` |
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
| 机器定时器 pending、屏蔽、精确中断和返回 | `timer_irq_basic` |
