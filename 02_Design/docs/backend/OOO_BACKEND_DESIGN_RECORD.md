# 乱序后端设计记录

本文档记录当前 RV32 双宽处理器改造成 FPGA 高性能乱序处理器时，已经确认的架构决定、第一版 RTL 基线，以及仍需单独展开的后续模块。

记录约定：

- **已确认**：后续设计默认遵守，除非重新讨论并修改本文档。
- **第一版基线**：已经足以指导第一版 RTL；若完整综合或性能数据出现反证，再显式修改本文档。
- **后续模块**：不是本节遗留的小开关，而是需要单独讨论的完整设计主题。
- 软件模型中的参数不自动成为硬件参数。

## 1. 总体目标

- **已确认**：目标平台是 FPGA，优先考虑时序、布线和可实现性，而不是照搬高端 ASIC 处理器。
- **已确认**：前端和重命名以双宽为基础。
- **已确认**：采用基于 PRF 的重命名结构，ROB 不保存通用寄存器结果值。
- **已确认**：当前乱序版本支持整数和 M 扩展；暂不考虑 F 扩展，也不为 F 扩展预留接口。
- **已确认**：后端设置 ALU0、ALU1、LSU、MDU 四个结果源/执行资源；每个 FU 每周期最多接收 1 条，同时全核每周期最多发射 2 条。四个 FU 提供功能和长延迟并行能力，不把 issue width 扩大为 4。
- **已确认**：ALU0 支持普通整数和真实控制流，ALU1 只支持普通整数指令。第一版每周期最多处理一条需要后端预测验证的真实控制流，不为 ALU1 复制重定向、恢复和清空通路。
- **已确认**：第一版采用 MDU 强优先且独占发射的简化策略。只有当 MDU IQ 中存在源操作数已准备好、未被 flush 且 MDU 当周期能够接收的指令时，才视为“MDU 可发射”；此时该周期只发射这一条 MDU 指令。该策略有意牺牲 MDU 发射周期中的潜在双发机会，以移除 MDU 与 INT/LS 的跨队列配对网络。

第一版后端主流程为：

```text
取指/预测
    -> 预译码/译码
    -> 重命名与资源分配
    -> IQ/LSQ等待
    -> 唤醒与选择
    -> PRF读取
    -> FU乱序执行
    -> PRF写回并标记ROB完成
    -> ROB按序提交
```

执行结果可以乱序写回 PRF，但架构状态必须按 ROB 顺序提交。

## 2. 重命名结构

### 2.1 基本组成

- **已确认**：采用 `RAT + RRAT + Free List + PRF + ROB`。
- **已确认**：RAT 保存推测状态下的逻辑寄存器到物理寄存器映射。
- **已确认**：RRAT 保存已经提交的映射。
- **已确认**：PRF 保存实际数据；ROB 只保存提交、恢复和异常所需的元数据。
- **已确认**：ROB 为环形 FIFO，所有需要保持程序顺序的指令都进入 ROB，不只记录带 `rd` 的指令。
- **已确认**：普通 PRF entry 不需要保存“推测/已提交”标志。一个值是否属于当前可见状态由 RAT/RRAT 映射决定。
- **已确认**：恢复时不清空 PRF；错误路径留下的值会在对应物理寄存器重新进入 Free List 后被覆盖。

- **已确认**：整数 PRF 为 64 项，物理寄存器号为 6 bit。当前不纳入浮点寄存器命名空间。
- **已确认，复位映射**：复位后使用唯一映射 `x0->P0、x1->P1、...、x31->P31`；`P0~P31` 在 `busy_map` 和 `committed_busy_map` 中为占用，`P32~P63` 为空闲。RAT 与 RRAT 的 `x0` 项永久为 `P0`，对 `rd=x0` 的指令按无目的寄存器处理。
- **已确认，复位 ready**：`P0~P31` 对应已经提交的初始架构状态，因此 `prf_ready` 置 1；空闲的 `P32~P63` 置 0。除 `P0` 始终返回常数 0 外，其他通用寄存器的数据复位值不构成架构保证，测试环境可以为了可重复性将其初始化为 0。
- **已确认，映射表载体**：RAT、RRAT 和两份 RAT checkpoint 均使用按逻辑寄存器展开的 6 bit FF 表，不采用 CAM、BRAM 或多副本 LUTRAM。当前总量仅为 `4 x 32 x 6 = 768 bit`，FF 可以直接提供组合查询、同周期多处更新和单周期整表恢复，也避免为两份 checkpoint 构造多端口存储器。
- **物理实现原则**：32 个逻辑寄存器的 RAT、RRAT 和两份 checkpoint 对应项尽量按寄存器号局部放置；保存和恢复在每个 6 bit 小项附近完成，RTL 不应先把 192 bit 快照汇聚到远端再绕回 RAT。若完整综合显示查询多路器成为关键路径，再允许综合器做局部复制，不在第一版手工维护多份 RAT 一致性。

### 2.2 双宽重命名相关性

- **已确认**：RV32I+M 每条指令最多查询 `rs1、rs2、rd旧映射`，双宽最坏是 6 个 RAT 组合查询位置；无效源和无效目的的查询结果直接忽略。它们不是 6 个同步 RAM 端口，而是从 32 项 FF 表形成的小型多路选择网络。
- **已确认，RAW**：同周期后槽指令读取的逻辑源寄存器若命中前槽的 `rd`，必须使用前槽刚分配的 `pdst`，不能使用重命名前的 RAT 映射。
- **已确认，WAW**：两条写同一逻辑寄存器的指令各自分配不同的 `pdst`；本周期结束后 RAT 指向最后一条写指令的 `pdst`。
- **已确认，WAW**：后一个写者记录的 `old_pdst` 必须是前一个写者刚分配的 `pdst`，不能直接使用周期开始时的 RAT 旧值。
- **已确认**：上述逻辑应显式实现同周期旁路，不能依赖 FPGA RAM 的读写优先模式。
- **已确认，RAT next-state**：先从周期开始时的 RAT 得到旧映射和两个槽的源映射，再按程序顺序应用槽 0、槽 1 的新映射；槽 1 对同一逻辑目的寄存器具有最终优先级。分支 checkpoint 保存的 `RAT_after_slot0/1` 也从这一份顺序化 next-state 取得，不能另外复制一套相关性逻辑。
- **已确认**：源操作数的物理编号进入 IQ/LSQ 和后续本地流水寄存器；普通 ROB entry 不保存 `psrc0/psrc1`。

### 2.3 重命名阶段资源检查

重命名/分配阶段至少检查：

- ROB 空位；
- 需要写 `rd` 的指令所需的空闲 PRF 数量；
- 目标 IQ 和 LSQ 的空位；
- 分支 checkpoint 是否可分配；
- 其他串行化或结构冲突条件。

- **已确认**：资源不足时采用前缀接收。双宽输入可以只接收槽 0，但不能越过槽 0 单独接收槽 1。
- **已确认**：每周期最多创建 1 个 checkpoint。若同周期出现两个需要 checkpoint 的 owner，后一个必须停住。
- **已确认**：完整的指令类别、立即数、源操作数使用情况、FU 类别和串行化属性在 predecode/decode 中产生；rename 的输入已经是解码后的紧凑操作。译码可以物理分散到现有 predecode/decode 两级，但 rename 自身保持一个流水级，不在 RAT/Free List 的反馈路径上再串入完整指令译码。
- **已确认**：只有得到 `psrc` 后才能生成的源 bank、重复源判断和 PRF 读取类型留在 rename 计算；它们不是重新译码。

### 2.4 Free List 与 PRF bank 对应

- **已确认**：Free List 使用 bitmap，而不是保存物理寄存器号的传统 FIFO。
- **已确认**：当前采用 `1=占用、0=空闲` 的语义，信号命名使用 `busy_map`，避免与 `free_map` 的相反极性混淆。
- **已确认**：64 位占用状态按物理寄存器号最低位拆成两个 32 位 bank：`busy_bank0[i]` 对应 `P(2*i)`，`busy_bank1[i]` 对应 `P(2*i+1)`。
- **已确认**：物理寄存器 tag 的最低位同时是 PRF bank 号，bank 内地址为 `ptag[5:1]`。
- **已确认**：Free List 使用两个并行的 32 bit 空闲检测和优先编码器，每个 bank 每周期最多给出一个新 `pdst`，不实现同 bank 的“第一空位、第二空位”两套分配器。
- **已确认**：只有一个新目的寄存器时，使用 1 bit 轮换指针选择优先 bank；若该 bank 没有空位则改用另一个 bank。成功分配后，下次优先选择另一个 bank，不在 rename 关键路径上计算两个 32 bit bitmap 的空闲数量。
- **已确认**：同周期有两个新目的寄存器时，正常情况从两个 bank 各取一个，较老写者取得轮换指针优先的 bank，较年轻写者取得另一个 bank。物理目的寄存器的 bank 并不是由逻辑 `rd` 预先指定的，因此只要两个 bank 都还有空位，就不存在“两条指令天然要求同一个 bank”的问题。
- **已确认，轮换指针更新**：本周期没有分配时指针不变；只分配一个 `pdst` 时，下一次优先选择本次实际分配 bank 的另一边；两个 bank 各分配一个时指针保持不变。这样按目的寄存器分配序列观察仍是 `bank0、bank1、bank0、bank1...`，不会因为一次双分配而连续两次偏向同一 bank。复位时先选择 bank0。
- **已确认**：若一个 bank 已空而另一个 bank 仍有两个以上空位，第一版仍只分配一项，并按前缀规则停住第二个写者。增加同 bank 双分配只改善这种接近 PRF 耗尽且分布严重失衡的情况，却会增加第二优先编码器并破坏目的 bank 的主动均衡，不值得作为第一版基线。
- **已确认**：当周期刚由 commit 释放的 `old_pdst` 从下一周期开始才可重新分配，不建设 `commit release -> rename allocate` 的同周期旁路。
- **已确认**：提交释放 `old_pdst` 时按其最低位写回对应 `busy_bank`。bitmap 更新可以同周期清除同一 bank 的多个 bit，不存在 FIFO 多入队端口问题。
- **已确认**：`P0` 永久占用且不可分配。

## 3. ROB

### 3.1 容量、指针和物理 bank

- **已确认，第一版容量**：ROB 为 32 项环形 FIFO。该容量与当前软件模型、64 项 PRF 和 32 个额外物理寄存器匹配；把 ROB 扩大到 64 项却不增加 PRF，只会主要帮助不写目的寄存器的指令，同时扩大年龄比较、选择性 flush 和全局 owner 布线，不作为第一版 FPGA 基线。
- **已确认，ROB tag**：物理 entry index 为 5 bit，完整 ROB tag 为 `1 bit generation/wrap + 5 bit index`。所有离开 ROB 本体的 owner 标识都携带完整 6 bit tag；entry 本地保存其 generation，迟到完成、异常和分支事件必须同时命中 `valid、index、generation` 才有效。
- **已确认，指针状态**：维护完整的 6 bit `head_tag`、`tail_tag` 和 0～32 的注册 `rob_count`。空位检查直接使用 `rob_count`，不在 Rename 关键路径上临时计算 head/tail 环形距离。完整 tag 仍用于年龄、选择性 flush 和 owner 验证，不能只依赖 count。
- **已确认，静态字段分 bank**：按 ROB index 最低位拆成两个 bank；bank0 保存偶数 entry，bank1 保存奇数 entry，bank 内地址为 `index[4:1]`，每个 bank 深度 16。`tail` 与 `tail+1`、`head` 与 `head+1` 即使跨越 31→0 也必然各落一个 bank，因此双分配和双提交都只要求每个 bank 一次写、一次读。
- **已确认，存储载体**：分配后不再改变的静态字段使用两份 `16 x width` LUTRAM bank，每个 bank 一次同步 Dispatch 写和一次异步 Commit 读；不用 BRAM，不复制成多读/多写大表，也不增加 Live Value Table。head 的最低位只控制最后一级交换，使两个 bank 的输出重新排列成“最老、次老”。
- **已确认，不按 fetch row 留洞**：不采用“同一个 Dispatch 包固定占据一整行、每行共享一个 PC”的 ROB row 方案。当前支持前缀接收，单条接收和重定向会让共享 PC 需要留洞或引入额外有效位规则；32 项窗口中直接为每项保存 PC 更简单，也不会浪费 ROB 容量。
- **已确认，不复用当周期提交位置**：Rename 只使用周期开始时已经空闲的 ROB 项。当周期刚提交而释放的位置从下一周期才可分配；ROB 满但本周期能够提交时，Dispatch 仍停一拍。这个罕见气泡切断 `complete/side-effect ready -> commit -> ROB free -> Rename accept` 的全核组合反馈，也消除同地址 LUTRAM 读写语义依赖。
- **已确认，恢复周期**：真正的后端分支恢复或精确异常恢复周期不做普通 ROB commit，也不接收新 Dispatch。分支恢复保持 head 不变，把 tail 截到预测 owner 之后并重算 count；下一周期再恢复提交。允许损失至多一个提交周期，以避免同一沿同时进行 head 前进、tail 截断、RRAT 提交和 checkpoint 恢复。

[FPGA 多 bank ROB 研究](https://past.date-conference.com/proceedings-archive/2017/pyear/PAPERS/2012/DATE12/PDFFILES/12.5_2.PDF)指出，把不同访问时机的 ROB 字段拆开并按超标量宽度分 bank，可以避免用复制 RAM 和 Live Value Table 模拟多端口 ROB。当前设计采用相同的物理原则，但利用“双宽连续编号天然一偶一奇”消除论文中执行回写 bank 冲突：乱序完成状态不写静态 LUTRAM，而是按 3.3 节写 FF 位图。

### 3.2 ROB 字段和存储分层

ROB 不保存一个完整 `decoded_uop_t`，也不把所有字段打包成同一块多端口数组。第一版分为以下三类。

#### 高频、多来源更新状态：FF 位图

每项使用局部 FF 保存：

- `valid`；
- `generation`；
- `complete`；
- `exception_valid`；
- 条件分支的 `actual_taken`；
- 真实控制流的 `resolved_next_pc_valid`。

这些位需要接受乱序完成、ALU0 分支解析、异常、commit 和选择性 flush 的按项更新，不能放入只有一个写地址的 LUTRAM。物理上按偶/奇 entry 各形成 16 bit 局部块，但语义上仍是 32 项位图。

#### Dispatch 后不变的提交元数据：两 bank LUTRAM

每项保存：

- `has_dest`；
- 逻辑目的寄存器 `ldst[4:0]`；
- 新物理映射 `pdst[5:0]`；
- 被替代的旧物理映射 `old_pdst[5:0]`；
- 3 bit `commit_class`，第一版编码普通指令、条件分支、Load、Store、串行指令五类；
- 对 Load/Store 有效的 `lsq_idx`，位宽由后续 LSQ 深度参数直接推导。

没有 `rd` 的指令仍占用 ROB 项，但 `has_dest=0`，三个目的寄存器字段统一写 0。`JAL/JALR` 在提交阶段除可能更新 RRAT 外不需要特殊动作，归入普通类；只有会更新 GHR 的条件分支使用条件分支类。

#### 冷数据：独立的两 bank LUTRAM

每项保存完整 `PC[31:0]` 和 `inst[31:0]`。PC 用于精确异常和中断边界，指令字用于非法指令信息、提交 trace 和调试；它们不参与普通 complete/年龄判断，也不与 RRAT/Free List 控制打包在同一个宽选择器中。正常提交时调试输出可以在提交沿寄存这些冷数据，不让它们进入架构状态更新的关键控制路径。

另设一份 `32 x 32 bit` 的 `resolved_next_pc` 单写单读 LUTRAM，只在 ALU0 解析条件分支、JAL 或 JALR 时按 ROB index 写入，ROB 头提交控制流时读取；对应有效位使用上述 FF 位图。它不是预测 metadata，也不参与普通提交资格判断，唯一用途是在控制流恰好成为最后一条提交指令时正确更新第 9.4 节的 `architectural_next_pc`。ALU0 每周期最多解析一条，所以不需要多写口；双提交也只读取“本周期最后一条真正提交的指令”，若槽 1 提交就无需读取槽 0 的下一 PC，因此一个读口足够。complete 下一周期才可见于提交，保证提交读取时数据已经写入。

下列内容明确不放入普通 ROB entry：

- `psrc0/psrc1`、立即数、ALU/MDU 操作和完整执行控制；这些已保存在对应 IQ/FU 本地；
- 通用寄存器结果值；结果只保存在 PRF；
- 预测目标、PHT/ABTB 训练资料、RAT 快照和 Allocation Mask；它们属于 branch checkpoint；
- 每项 branch mask；当前只需用完整 ROB tag 与恢复 owner 比较年龄即可选择性清除，两项 checkpoint 不要求再复制一份分支位图到全部 ROB entry；
- 每项一份异常原因和 32 bit `tval`；宽异常信息按 3.3 节只保留最老一条；
- Load/Store 地址与 Store 数据；它们属于 LSQ/SQ；
- CSR 写数据和完整特权控制；第一版由单项串行槽保存到 ROB 头执行，不扩宽全部 ROB entry。

当前竞业达封装不消费按序提交 trace。若其他平台必须在 commit 时输出寄存器写回值，使用可按构建裁剪的调试 shadow，并明确放在功能 ROB 之外；第一版性能配置不为了调试给 PRF 增加永久读端口，也不改变“ROB 不保存架构结果”的功能边界。

### 3.3 完成状态和异常信息写入

- **已确认，完成位不是多端口 RAM**：32 个 `complete` FF 可以在一个时钟沿置位多项。每个完成来源只把 `valid + 完整 ROB tag` 送到 ROB 附近，先验证 generation，再局部译码为 one-hot；所有存活来源的 one-hot mask 并行 OR 后写入完成位，不做“每周期只收两条”的年龄仲裁。
- **已确认，正常带 `rd` 指令**：只有 bank0/bank1 的 PRF 实际写入事件设置最终 complete，因此这类完成每周期最多两条。无目的寄存器指令、`rd=x0`、分支控制完成和后续 SQ 完成可以在同周期另外置位，ROB 允许总完成数瞬时大于 issue/commit width。
- **已确认，无同周期完成到提交旁路**：本周期新产生的 complete 在时钟沿锁存，下一周期才参加 ROB 头提交判断。不建立 `FU/PRF -> complete -> commit -> RRAT/Free List` 的跨模块组合链；这只增加完成到退休的一拍可见延迟，不降低流水稳定后的每周期双提交吞吐。
- **已确认，异常分层**：每个异常 owner 都设置自身的 `exception_valid` 和可处理完成状态，但全核只维护一份 `oldest_exception` 宽记录，包含 `valid、owner_rob_tag、cause、tval`。异常 PC 和指令字在 owner 到达 ROB 头时从冷数据 bank 读取，不在宽记录中重复保存。
- **已确认，多异常同周期**：所有有效异常 entry 的一位标志都可以同时置位；当前宽记录和本周期新异常候选先过滤 flush，再并行比较 ROB 年龄，只把最老候选写入 `oldest_exception`。较年轻异常的 cause/tval 可以丢弃：若较老异常存活，它必然先触发精确异常；任何能够清除较老异常的恢复事件都比它更老，也必然同时清除这些更年轻异常。
- **已确认，异常记录恢复**：若分支恢复杀死 `oldest_exception.owner`，则清空宽记录；因为它已经是已知最老异常，此时所有其他已知异常也都严格更年轻并被同一分支杀死。若 owner 不在恢复范围内则原样保留。迟到异常必须通过完整 ROB tag 验证，访存 replay/内存顺序违例使用重放或重定向通路，不能伪装成不可撤销的架构异常。

[BOOM ROB](https://docs.boom-core.org/en/latest/sections/reorder-buffer.html)同样为每项保存一位异常标志，而只为最老异常保存 cause 和错误地址等宽状态。RISC-V 精确陷阱最终需要的 `mepc、mcause、mtval` 分别来自 ROB 冷数据 PC、`oldest_exception.cause` 和 `oldest_exception.tval`；`mtval` 的具体合法值遵守[RISC-V Privileged ISA](https://docs.riscv.org/reference/isa/priv/machine.html)。[AMD UG901](https://docs.amd.com/r/2025.1-English/ug901-vivado-synthesis/Choosing-Between-Distributed-RAM-and-Dedicated-Block-RAM?contentId=aBKFGaNF1aFhM4nCRwkHZg)规定分布式 RAM 同步写、异步读，因此上述静态两 bank 可以在 Dispatch 沿写入，并在后续 Commit 周期组合读取。

### 3.4 提交和物理寄存器释放

第一版 ROB 每周期最多提交两条，严格采用程序顺序前缀：槽 0 不能提交时槽 1 也不能提交；槽 0 可以而槽 1 暂时不可以时只提交槽 0。两条都能提交时，RRAT、`committed_busy_map` 和所有架构副作用按“先槽 0、再槽 1”的 next-state 更新。

- **已确认，提交检查**：两个 head 候选的 `valid、complete、exception_valid、commit_class` 和对应外部副作用 ready 并行预计算；最终只形成 `commit0 = slot0_can_commit`、`commit1 = commit0 && slot1_can_commit` 的短前缀关系，不串行执行两套完整检查。
- **已确认，异常前缀**：若槽 0 带异常，本周期不做普通提交，进入精确异常流程。若槽 1 带异常而槽 0 可以正常提交，本周期只提交槽 0；下一周期槽 1 成为唯一 ROB 头后再处理异常，避免正常提交与全局异常恢复在同一沿发生。
- **已确认，指针更新**：普通周期按 0、1、2 条实际提交数量更新 `head_tag` 和 `rob_count`，并清除对应 valid/complete/exception/`resolved_next_pc_valid` 位。静态 LUTRAM 内容不需要清零；generation 与 valid 会阻止旧 payload 被迟到事件再次使用。
- **已确认，提交宽度依据**：Rename 和全局 issue 的长期吞吐上限都是每周期两条，因此双提交足以匹配稳定吞吐。乱序执行偶尔同周期完成三条以上只会同时置位多项 complete，随后由 ROB 以每周期最多两条排出，不需要扩大 RRAT、Free List 和提交副作用端口。

带 `rd` 的指令到达 ROB 头且允许提交时：

1. RRAT 的 `ldst` 更新为该指令的 `pdst`；
2. ROB 中记录的 `old_pdst` 归还 Free List；
3. 该 ROB entry 出队。

释放的是被新提交映射替代的旧物理寄存器，不是刚写回的新 `pdst`。

ROB RTL 至少设置下列断言：

- `rob_count <= 32`，并且有效 entry 的数量始终等于 `rob_count`；
- head 开始的前 `rob_count` 个完整 tag 恰好对应所有有效 entry，不允许环形窗口中出现洞；
- 双分配和双 head 读取的两个 index 必须分别落入不同 bank，两个 bank 每周期各不超过一次静态写；
- 任何 complete、异常或分支更新都必须命中相同 generation 的有效 owner；已经提交、恢复清除或重新分配后的旧 tag 不得改变新 entry；
- `commit1` 有效必然蕴含 `commit0` 有效，异常 owner 不能作为普通提交离开 ROB；
- `oldest_exception.valid` 时，其 owner 必须是有效且带异常的 ROB entry，并且所有其他有效异常 entry 都不得比它更老。

## 4. 分支 checkpoint 与恢复

### 4.1 checkpoint 数量

- **已确认：实现 2 个分支 checkpoint。**
- **已确认**：checkpoint 在对应 owner 经过重命名/分配时创建，而不是等到它进入 FU 或执行结束时才创建。
- **已确认**：ALU0 发现预测错误后立即恢复，不等待对应指令成为 ROB 头。
- **已确认，哪些指令申请 checkpoint**：当前前端在 ABTB 未命中时会顺序取指，真实控制流的最终方向/目标纠错仍统一留给 ALU0。因此第一版中，条件分支、`JAL`、`JALR` 都申请 checkpoint；不能因为 `JAL` 的真实目标可以由 PC 和立即数计算，就假设它一定已经在前端得到验证。
- **已确认，错误 CFI 预测**：若一条实际不是控制流的指令携带了会改变下一取指地址的 taken 预测，Decode/Rename 在这条指令真正获得前缀接收时，用已知顺序地址 `PC+4` 发出一次前端纠错并抑制同周期更年轻槽。该指令本身仍按真实类型进入 INT、LS、MDU 或串行槽；由于程序顺序分配保证此刻后端中不存在比它更年轻的状态，所以无需 checkpoint 和后端 RAT 恢复。
- **已确认，纠错优先级边界**：错误 CFI 的 Decode 纠错必须等 owner 真正被接收才发出；资源停顿时保持原指令和纠错请求。更老的 ALU0 误预测或 ROB 头精确异常优先于它。该窄路径只处理“预测 taken、实际非 CFI”的类型错误，不重新引入完整的 Decode 分支方向预测。
- **已确认，预测器修复**：`decode_cfi_fix` 同时携带预测时的 ABTB bank/way/set 信息，使前端在下一沿清除对应 valid，避免同一条普通指令反复被当作控制流。该失效操作不写 PHT、不分配新 ABTB 项；若与一条正常的 ALU0 控制流训练写同周期冲突，罕见的失效操作优先，允许丢掉这一次普通训练，不增加更新 FIFO。即使该 way 已在期间被替换，误清只降低预测性能，不影响架构正确性。
- **已确认，错误 CFI 断言**：`decode_cfi_fix` 有效必然伴随 owner 的 Dispatch 接收，owner 必须进入其真实目标结构，且同周期不得接收任何严格年轻指令；反过来，owner 未被接收时不得发出或丢失该纠错。该 owner 不分配 checkpoint。
- **已确认**：真实控制流仍只保留“ALU0 解析、同一套 checkpoint 恢复”这一条后端纠错路径。将来若增加能在任何年轻指令进入 Rename 前完成的直接 `JAL` 目标验证，才可以重新讨论省略 `JAL` checkpoint。

[香山 PredChecker](https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/IFU/PreDecoder/#ifu-submodule-predchecker)同样显式检查 non-CFI、JAL 和目标地址预测错误，并在指令进入后端前修正有效范围。当前设计只采纳其中保证任意指令类型都能正确处理所必需的 non-CFI 检查；不照搬完整两级 PredChecker，直接 `JAL` 仍由 checkpoint + ALU0 统一恢复。

选择 2 个的主要原因是目标为 FPGA，需要限制 RAT 快照、恢复选择和全局布线成本。

已删除的阶段性 C 模型曾表明，在使用 M 扩展的目标程序中：

- 动态 checkpoint 指令约占 2.85%；
- 2 个 checkpoint 仅约 2.4 万周期满，占约 2.13 亿周期的 0.011%；
- 从 2 个增加到 4 个，性能提升约 0.009%。

不使用 M 扩展的二进制会用移位、加法和循环分支执行软件乘除法，动态 checkpoint 指令约占 18.12%，2 个 checkpoint 会成为明显瓶颈。但当前决定以使用 M 扩展的目标工作负载和 FPGA 布线成本为准。

上述旧模型只把条件分支和 `JALR` 计为 checkpoint 指令，没有覆盖当前已经确认的直接 `JAL`，因此这些满周期和百分比只能作为“2 项已经很少形成压力”的下界证据，不能再当作精确硬件统计。2 项仍作为第一版 FPGA 基线；再次比较 checkpoint 数量前，必须先把新后端模型的分配范围改对。对应旧 C 模型已在完成阶段性用途后删除，不再维护。

2026-07-23 又在 `/tmp` 的模型副本中把 `JAL` 加入 checkpoint 范围，以当前 `INT=4、LS=2、MDU=1` 对六程序做了 2 项/3 项聚焦复测。目标 `new_with_Mext` 从 2 项增加到 3 项只减少 `3249 / 624696448 = 0.000520%` 的周期，IPC 仅从 `0.608847` 变为 `0.608850`，所以补齐 JAL 后仍不改变 2 项决定。其他五个程序减少约 `0.68%~2.11%` 周期，说明 2 项不是所有二进制的通用最优值，而是针对带 M 目标负载和 FPGA 布线成本的明确取舍。该临时模型仍未对齐 5.5 节最终发射策略，也不生成错误路径，因此只用于这次容量复核，没有写回工程源码。

### 4.2 分支误预测恢复

- **已确认**：恢复 RAT 到预测 owner 保存的 checkpoint。
- **已确认**：清除 ROB、IQ、LSQ 中该 owner 之后的年轻指令。
- **已确认**：回收该 checkpoint owner 之后错误路径分配的物理寄存器。
- **已确认**：RRAT 不恢复，因为它只包含已经提交的状态，从未被错误路径修改。
- **已确认**：PRF 不清空。
- **已确认**：checkpoint 保存 RAT 快照，并保存该 owner 之后年轻指令新分配物理寄存器的 Allocation Mask。
- **已确认，checkpoint 身份**：每个槽至少保存 `valid、owner_rob_tag、RAT快照、Allocation Mask` 以及该预测 owner 执行/训练所需的资料。槽号本身不表示年龄；恢复和预测正确释放都必须同时命中槽号与 `owner_rob_tag`，防止槽复用后迟到事件操作了新 owner。
- **已确认，前端状态边界**：乱序第一版的 GHR 按 4.4 节只在条件分支 commit 时更新，当前也没有推测更新的 uRAS，因此后端 checkpoint 不保存或恢复 GHR/RAS 状态。预测时的 PHT index/counter、ABTB hit/way/type 等训练资料仍随 owner 保存；若将来引入推测 GHR/uRAS，必须显式给 checkpoint 增加对应快照，不能继续沿用本条假设。
- **已确认，槽分配**：两个槽使用固定低编号优先寻找空位，不增加轮换状态。创建时写入 owner 的完整 ROB tag；需要判断哪些 checkpoint 更年轻时比较 owner ROB tag，而不是比较 checkpoint 槽号。
- **已确认**：Allocation Mask 与当前 `busy_map` 不是同一个状态。每个 checkpoint 保存 `alloc_mask_bank0[31:0]` 和 `alloc_mask_bank1[31:0]`；owner 创建它时清零，之后的年轻分配在对应 mask 中置位。
- **已确认**：预测错误时恢复 RAT checkpoint，并执行 `busy_bankX &= ~alloc_mask_bankX`，回收 owner 之后分配的物理寄存器。预测正确时只释放 checkpoint，不能根据 Allocation Mask 回收寄存器。
- **已确认，RAT 快照位置**：checkpoint 保存的是“已经执行完 owner 自身重命名”之后的 RAT。双宽槽 0 是 owner 时保存 `RAT_after_slot0`，槽 1 是 owner 时保存 `RAT_after_slot1`。这样 JAL/JALR 自身的链接寄存器新映射会保留，恢复时只撤销严格年轻指令。
- **已确认，创建时的 Allocation Mask**：新 checkpoint 不记录 owner 自身分配的 `pdst`；槽 0 创建 checkpoint 时，初始 mask 只包含同周期槽 1 这条更年轻指令的分配，槽 1 创建时初始 mask 为 0。已经存在的更老 checkpoint 则记录本周期两个槽中所有成功接受的新 `pdst`。
- **已确认，普通周期更新**：把两个成功分配的 `pdst` 分别变成两个 bank 内的 one-hot 位，先按程序顺序形成“槽 0 分配”“槽 1 分配”和后缀 mask，再并行 OR 到每个活动 checkpoint。每周期最多创建一个 checkpoint，因此不需要解决两个新快照同时写入的问题。
- **已确认，误预测恢复**：恢复 checkpoint `C` 时，使用 `C.alloc_mask` 清除当前 `busy_map`；同时释放 `C` 并使所有年轻 checkpoint 失效。仍然存活的更老 checkpoint 必须执行 `older.alloc_mask &= ~C.alloc_mask`，不能保留已经回收的位，否则这些物理编号重新分配后，更老 checkpoint 将来恢复时可能误释放新 owner。
- **已确认，同周期状态规则**：误预测或精确异常恢复周期禁止新的 Rename/Dispatch 和普通 commit，因此恢复 mask 不与新分配或提交释放竞争。分支恢复只清除 checkpoint Allocation Mask 标记的年轻物理寄存器，严格更老的指令等下一周期再提交；第一版也不在恢复沿重新分配任何被回收的位。
- **已确认，checkpoint 槽复用**：预测正确或 owner 自身异常时只释放对应 checkpoint，不回收其 Allocation Mask。为切断“ALU0 结果 -> rename 资源检查”的长反馈，当周期刚释放的 checkpoint 槽从下一周期才允许重新创建；若周期开始时两个槽都占用，即使本周期有 owner 释放，rename 仍停住新的 checkpoint 指令一拍。

[BOOM Rename Stage](https://docs.boom-core.org/en/latest/sections/rename-stage.html)同样使用位向量 Free List 和每分支 Allocation List；其实现会在误预测回收寄存器时从其他 Allocation List 中清除同一批位。这里采用相同的正确性规则，但只保留两个 checkpoint，并按两个 PRF bank 物理拆分。

### 4.3 精确异常恢复

- **已确认**：FU 可以提前发现异常并写入对应 ROB entry，但不能立即改变架构状态。
- **已确认**：异常指令到达 ROB 头时才进入精确异常处理。
- **已确认**：异常恢复以 RRAT 的已提交映射为基准，清除异常指令及其年轻状态；不要求为每条可能异常的指令预先保存分支式 checkpoint。
- **已确认**：PRF 同样不需要清空。
- **已确认**：除 RRAT 外，再维护一个 64 bit `committed_busy_map`，它恰好标记 RRAT 当前映射到的物理寄存器。正常双提交时，它按程序顺序移除每条指令的 `old_pdst` 并加入 `pdst`；同周期 WAW 时，较年轻提交对较老提交的中间映射具有最终优先级。`P0` 始终保持占用。
- **已确认**：精确异常真正处理时执行 `RAT <= RRAT`、`busy_map <= committed_busy_map`、`prf_ready <= committed_busy_map`，并清空所有未提交 ROB/IQ/LSQ、checkpoint 和执行流水状态。所有已提交物理寄存器必然已经写回，因此把这些 ready 位设为 1 是成立的；其他 PRF 数据不清零。
- **已确认**：这 64 bit 已提交占用图避免在恢复关键路径上对 RRAT 的 32 个 6 bit 映射做 32 路 one-hot 展开，也避免为了异常逐项 WALK ROB。它只增加一份小状态，适合当前 FPGA 和已有 RRAT 方案。
- **已确认，状态不变量**：RRAT 的 32 个映射必须互不重复，且其 one-hot 并集必须逐位等于 `committed_busy_map`；因此该 map 的置位数恒为 32，`RRAT[x0]=P0` 且 `committed_busy_map[P0]=1`。RTL 对这些关系设置断言，双提交 WAW 用“先老后新”的 next-state 检查。
- **已确认**：若双提交检查发现槽 1 是异常指令，只在本周期提交更老的槽 0；下一周期等异常指令成为唯一 ROB 头后再开始恢复。异常极少，多花一拍可以消除“正常提交和全局恢复在同一沿修改 RRAT/Free List”的特殊情况。
- **已确认，恢复优先级**：精确异常发生在 ROB 头，因此若它与一个年轻分支误预测同时出现，异常恢复和异常入口 PC 优先，年轻分支事件被整条流水 flush。普通分支误预测优先于新的 Rename/Dispatch。
- **已确认，checkpoint owner 自身异常**：若控制流 owner 在 ALU0 发现的是异常而不是一个可继续执行的正确下一 PC，本周期只把异常写入 ROB，不做误预测恢复和预测器训练；它占用的 checkpoint 直接释放，但不按 Allocation Mask 回收年轻寄存器。年轻状态可以继续保持推测，等该异常成为 ROB 头时再由 RRAT/`committed_busy_map` 一次性精确恢复。保留这个 checkpoint 到 ROB 头只会无谓阻塞两个槽，并不增加正确性。

[BOOM 的 Committed Map Table](https://docs.boom-core.org/en/latest/sections/rename-stage.html#resets-on-exceptions-and-flushes)用于在异常/flush 时单周期恢复已提交映射；当前设计在相同思路上额外保存已提交物理寄存器占用图，从而让 bitmap Free List 和 `prf_ready` 也能一起恢复。

### 4.4 预测器状态在乱序执行下的更新

- **已确认，GHR 必须按程序顺序更新**：现有顺序核在 EX 更新 GHR 时，执行顺序就是程序顺序；改成乱序后，年轻分支可能先于老分支执行，不能继续直接按 ALU0 完成顺序移位。第一版把 GHR 更新移动到 ROB commit，只在条件分支真正提交时写入实际 taken/not-taken。
- **已确认，双提交规则**：ROB entry 为条件分支保存 `actual_taken`。同周期提交两条时，先检查槽 0、再检查槽 1；每遇到一条条件分支就顺序移入一位，最后一次性写回 8 bit GHR。JAL/JALR、错误 CFI Decode 纠错和异常指令都不改变 GHR。
- **已确认，ABTB/PHT 仍在解析时训练**：预测时保存的 ABTB hit/way/type、PHT index/counter 在 ALU0 解析真实控制流时使用，因为 ALU0 每周期最多解析一条，不增加训练端口。这样训练早、checkpoint 也能在解析后立即释放。
- **已确认，训练事件与 flush**：误预测 owner 自己产生的 ABTB/PHT 训练必须保留，不能被它同周期发起的 flush 误杀；若同周期有更老的精确异常/恢复使该 owner 本身失效，则不产生训练。一旦一个有效训练事件进入前端的单级写寄存器，后续更晚到来的 flush 不撤销它，这与第一版允许非架构预测表受到少量错误路径污染的取舍一致。
- **已确认的折中**：一个后来被更老分支或异常清除的年轻控制流，可能已经给 ABTB/PHT 留下训练；这些结构不是架构状态，错误路径污染只影响之后的预测率，不影响程序正确性，第一版不为它们建设撤销日志。GHR 不允许这种污染，始终只接收已经提交的条件分支。
- **已确认，metadata 生命周期**：执行检测和 ABTB/PHT 训练所需的预测 metadata 保存到 checkpoint，解析后即可丢弃；提交时只需 ROB 中已有的控制流类型和新增的 `actual_taken`，不把整套预测 metadata 复制进 ROB。
- **断言**：ALU0 解析不得直接修改 GHR；一次双提交对 GHR 的移位次数必须等于本次真正提交的条件分支数，并严格保持槽 0、槽 1 顺序；被 flush 或发生异常的条件分支不得在以后提交时更新 GHR。

## 5. Issue Queue 和仲裁

### 5.1 队列组织

- **已确认**：后端设置三个 IQ/调度域：INT IQ 由 ALU0/ALU1 共享，LS IQ 对应 LSU，MDU IQ 对应乘除单元。
- **已确认**：INT IQ 每周期最多向两个 ALU 提供两条不同指令，LS IQ 和 MDU IQ 各最多向自己的 FU 提供一条指令；全核最终最多批准两条。局部选择结果只有获得全局批准后，才能离开 IQ、占用 PRF 读口并进入 FU。
- **已确认**：采用非压缩式 IQ。entry 释放后留下空洞，通过 valid bitmap 寻找空位，不在每周期整体搬移队列内容。
- **原因**：非压缩式结构更适合并行 ready 比较和年龄选择，也避免压缩队列的大量移位与长布线。
- **已确认的第一版硬件基线**：INT IQ 为 4 项、LS IQ 为 2 项、MDU IQ 为 1 项。后续软件模型和独立 FPGA 综合仍用于检查该选择，但在没有新的反证前，RTL 按这一组深度设计。
- **已确认**：双宽 Dispatch 不进行真正的年龄比较，输入槽 0 天然比槽 1 老。采用前缀接收：槽 1 只有在槽 0 已被接收后才能接收，不能因为槽 1 的目标 IQ 有空位就越过被阻塞的槽 0。
- **已确认**：接收条件不能只看一个 `full` 位，而要按两条指令的实际需求检查 ROB、Free List、目标 IQ、LSQ 和 checkpoint 的剩余容量及当周期分配带宽。先用资源初态检查槽 0，再用“扣除槽 0 需求后的状态”检查槽 1；FU 当前是否忙、源是否 ready 和未来 PRF 读 bank 配对不影响指令先进入 IQ。
- **已确认**：每个 IQ 直接使用 `free_mask = ~valid_bitmap` 寻找空位，不另设 IQ Free List。采用固定低编号优先，不保存轮换指针；IQ 地址不表示年龄，低编号 entry 被更频繁使用不会改变 ROB 年龄顺序。
- **已确认**：INT IQ 根据 4 bit `free_mask` 并行产生编号最小和第二小的两个空位；由于仅有 16 种输入，可实现为小型固定组合表，而不构造长的“选一次、屏蔽、再选一次”级联。LS IQ 对 2 bit 空闲状态直接译码，MDU IQ 只检查唯一 entry。
- **已确认**：两条指令进入同一 IQ 时，槽 0 使用第一个空位，槽 1 使用第二个空位；只有一条请求该 IQ 时，它使用第一个空位。
- **已确认**：第一版只把周期开始时已经无效的 entry 视为空位，不复用本周期即将发射并清除的位置。该选择可能在 IQ 恰好满时多停一个周期，但切断 `issue grant -> IQ free -> Rename/Dispatch backpressure` 的反向长组合路径。
- **已确认**：一条指令的 ROB、PRF、IQ、LSQ/checkpoint 等分配必须由同一份接收结果在同一个时钟沿原子更新。flush 优先于新 Dispatch；flush 当周期不向 IQ 写入新指令。

### 5.2 年龄和 ALU 功能限制

一条 IQ 指令能够参加当周期选择，至少要满足：该位置确实有指令、所有需要的源操作数都已经准备好、指令没有被恢复操作取消，并且对应 FU 当前能够接收它。这里的 `valid` 表示“该 IQ 位置确实有指令”，`ready` 表示“源数据保证能在随后的 PRF 读取周期使用”，`FU compatible` 表示“该执行单元支持这种指令”。

- **已确认**：IQ entry 保存该指令的 ROB tag，用 ROB 环形顺序判断年龄。
- **已确认**：不需要让 ROB 反向保存 IQ 地址来完成普通年龄仲裁。
- **已确认**：年龄比较必须包含 ROB index 和 wrap/generation 信息，并相对 ROB head 判断，不能只比较裸 index。
- **已确认**：INT IQ 的 4 个位置之间共有 6 组两两年龄关系，这 6 组比较并行完成，并由同一份比较结果得到完整年龄顺序。第一版不采用“先选一次、屏蔽获选项、再串行选一次”的长组合链。
- **已确认**：只有 ALU0 可以执行真实控制流。概念上的分配规则是从老到年轻查看：这类 `alu0_only` 指令只能占用 ALU0；普通整数指令优先占用 ALU1，在 ALU1 已占用而 ALU0 空闲时也可占用 ALU0。
- **已确认**：若最老的两条指令都是 `alu0_only`，只发射其中更老的一条，并继续寻找能够送入 ALU1 的最老普通整数指令。年轻普通指令越过暂时无法使用 ALU0 的控制流指令执行，属于正常的推测性乱序执行。
- **已确认**：跨 IQ/FU 的全局发射上限为 2。IQ entry 只有获得最终发射批准后才离开队列，局部选中不能提前清除 entry。

### 5.3 PRF 读取类型和冲突判断

- **已确认**：第一版没有 32 位结果前递网络；除立即数和 `x0` 外，已准备好的源操作数都从 PRF 读取。因此一条指令会占用哪些 PRF bank 读口，在完成重命名后就是静态信息，不需要在仲裁时判断数据来自前递还是 PRF。
- **已确认**：当前 RV32I+M 指令执行时最多读取两个 PRF 源操作数。ROB 中保存的 `old_pdst` 只是提交时释放旧映射所需的元数据，不是第三个 PRF 数据读请求。
- **已确认**：指令进入 IQ 时保存一个 3 bit 的 `prf_read_pattern`，即“PRF 读取类型”。它表示下列六种情况之一：不读 PRF、只读一次 bank0、只读一次 bank1、两次都读 bank0、两个 bank 各读一次、两次都读 bank1。
- **已确认**：任意两条指令能否同时读取 PRF，只需检查两者对 bank0 和 bank1 的读取次数是否都不超过 2。两条指令各提供 3 bit 读取类型，兼容性可以实现为一张 6 bit 输入的小型固定表，而不必在关键路径上临时解析四个完整物理寄存器号。
- **已确认**：4 项 INT IQ 的 6 种两两组合并行检查是否合法。优先选择“第一条尽量老、第二条也尽量老”的合法组合；若最老指令无法与任何其他指令配对，但较年轻的两条指令可以合法双发，则允许较年轻组合双发，最老指令继续留在 IQ。不能因为最老指令暂时找不到搭档而浪费一个本来可用的发射位置。
- **已确认**：ALU 功能限制和 PRF 读取冲突共同决定两条指令是否能够配对。例如一对指令不能同时包含两条 `alu0_only` 指令，也不能让任意一个 PRF bank 承担超过两个有效读取。
- **已确认**：仲裁和 PRF 读取是两个独立流水级。仲裁周期结束时锁存被选指令的 `psrc`、目标 FU 和窄读请求归属；下一周期在各 bank 内并行整理两个物理读口并完成 LUTRAM 组合读取。
- **已确认，单条指令重复源优化**：rename 在得到两个 `psrc` 后计算 `src1_reuse_src0 = src0_used && src1_used && (psrc0 == psrc1)`. 命中时只产生一次 PRF 读取，返回后在目标 FU 本地把同一个 32 bit 数据送给两个源。这个 6 bit 比较只属于一条指令，不进入跨 entry 年龄和配对网络。
- **已确认**：两条不同指令即使读取同一个 `psrc`，第一版仍各自占用一次 PRF 读口。跨指令合并需要额外的 tag 比较、返回多播和动态端口计数，容易把布线重新引入全局仲裁，不采用。
- **已确认**：`prf_read_pattern` 已经扣除 `P0`、立即数、未使用源和上述单指令重复源，因此仲裁看到的就是实际物理读次数。

### 5.4 可提前计算的信息和最终仲裁

- **已确认的设计原则**：凡是只由指令编码和重命名结果决定、在 IQ 等待期间不会变化的信息，都可以在预译码、译码或重命名阶段提前计算，并随 IQ entry 保存。这样可以用少量存储位换取更短的仲裁组合路径。
- 预译码/译码阶段可以提前得到：指令属于普通整数、分支、访存还是乘除法，实际使用几个源寄存器，立即数和 `x0` 是否占用 PRF 读口，以及允许进入哪些 FU。
- 重命名阶段得到 `psrc` 后，可以提前得到每个源寄存器所在的 PRF bank，并生成上述 3 bit `prf_read_pattern`。源 bank 只有在逻辑寄存器映射为物理寄存器后才能确定，不能在更早的纯译码阶段猜测。
- 必须留到仲裁阶段决定的内容包括：当前 IQ entry 是否仍然有效、源操作数此刻是否已经准备好、FU 是否空闲、哪些候选被 flush 取消、当前候选之间的年龄关系，以及最终两条指令能否共同满足 FU 和 PRF 端口限制。
- **已确认**：提前计算只生成并保存仲裁元数据，不会在重命名阶段提前预留 FU 或 PRF 读口，也不会提前决定未来一定发射哪条指令。
- **已确认，第一版流水边界**：读取类型在 rename 预计算；IQ ready、年龄、配对和最终方案选择在一个仲裁周期完成；PRF bank 物理读口整理和 LUTRAM 读取在下一周期完成。第一版不在两者之间再增加一个可见流水级。
- **已确认**：完整后端布局布线若仍不能达到 5 ns，先把年龄关系、配对合法性和各候选 payload 并行预计算，再做最后一级小选择，并对两个 PRF bank 及其消费者做局部布局。只有这些手段仍失败时，才重新讨论额外流水级；不能在 RTL 中悄悄改变 issue-to-execute latency。

### 5.5 全局两条指令的最终选择

- **已确认**：不建设把 INT、LS、MDU 全部候选放在一起比较年龄、枚举所有组合的全局最优网络。MDU 使用独占通路；MDU 不发射时，`LS + INT` 和 `INT + INT` 两套双发方案并行计算，最后只进行一次方案选择。
- **已确认，MDU 通路**：MDU 可发射时优先单发射 MDU，本周期不再批准其他队列的发射结果。MDU 是第一版的简化特例，不属于“尽可能填满两个发射位置”的范围。
- **已确认，`LS + INT` 方案**：LS IQ 的 2 个 entry 分别与 INT IQ 的 4 个 entry 并行进行配对检查，共产生 8 个配对是否合法的判断。参与检查的 LS 指令必须已经满足源操作数、LSQ/内存顺序、LSU 可接收和 flush 条件；INT 指令必须已经满足源操作数、至少一个 ALU 可执行和 flush 条件；两条指令合计对每个 PRF bank 的读取次数均不得超过 2。
- **已确认，`LS + INT` 的年龄选择**：对每个 LS entry，从与它兼容的 INT entry 中选择最老者；若两个 LS entry 都能组成双发组合，则选择其中较老的、且已经满足 LSQ 发射条件的 LS。这样只在各自 IQ 内使用年龄，不对 8 个跨队列组合进行全局年龄排序。若较老 LS 无法配对而较年轻 LS 能够安全发射并成功配对，可以采用较年轻 LS 的组合。
- **已确认，`INT + INT` 方案**：INT IQ 独立并行检查 4 个 entry 的 6 种两两组合，继续遵守 ALU0 才能执行控制流、每周期最多一条 `alu0_only` 指令、两条指令不能造成 PRF 读 bank 超额等限制。选择时优先较老的合法组合，但若包含最老指令的组合全部不合法而年轻指令之间存在合法组合，仍然批准年轻组合双发。
- **已确认，最终优先次序**：

```text
MDU 可发射                  -> MDU 单发
否则 LS + INT 可以双发      -> 发射 LS + INT
否则 INT + INT 可以双发     -> 发射 INT + INT
否则 LS 可以单发            -> 发射最老且允许发射的 LS
否则 INT 可以单发           -> 发射最老且有可用 ALU 的 INT
否则                        -> 本周期不发射
```

- **已确认**：`LS + INT` 双发优先于 `INT + INT` 双发，但 LS 单发不能压过 INT 双发。也就是说，LS 已经 ready 却找不到兼容 INT 时，仍要采用并行算出的 INT 双发方案，不能直接浪费第二个发射位置。
- **已确认**：该方案在 MDU 独占规则之外，以“本周期发射条数最大”为首要目标：只要 2 个 LS entry 与 4 个 INT entry 之间存在合法组合，或 INT 内部存在合法组合，就批准两条。若所有组合都超过实际 FU 或 PRF bank 端口能力，仲裁器无法凭空补足物理资源，此时允许单发。
- **已确认**：上述两套方案必须并行计算。“LS 配对失败后再串行启动 INT 双发选择”只是一种行为描述，不能成为 RTL 的组合级联结构。
- **已确认，第一版不加防饥饿计数器**：固定优先级可能让一条找不到搭档的 LS 或 INT 老指令多等待一些周期，但不会造成永久死锁。若它挡住 ROB 头，ROB 最终会填满并停止接收新指令，有限数量的年轻候选被发射后，这条已经 ready 的老指令必然获得单发机会。第一版只增加“各队列 ready 但未获选周期”性能计数，不把等待计数器和强制覆盖逻辑接入最终仲裁；以后引入 LSQ replay 或其他可反复重新入队行为时重新检查这一证明。

### 5.6 从 IQ 交接到 PRF 读取级

- **已确认**：全局仲裁逻辑上最多产生两条获选结果，可以概念性称为 slot 0/slot 1，但 RTL 不实现一个中央双槽宽指令存储。最终结果直接写入目标 ALU0、ALU1、LSU 或 MDU 附近的选择/owner 寄存器；PRF 附近只保存两条窄读请求描述，宽执行 payload 在下一周期并行读取。
- **已确认**：目标 FU 由仲裁结果决定，不由逻辑 slot 编号固定绑定。`LS + INT` 分别进入 LSU 和相应 ALU，`INT + INT` 分别进入 ALU0/ALU1，MDU 独占时只有 MDU 入口接收。
- **已确认**：IQ entry 只有在全局最终批准、目标 FU 的操作数保持位置已经预留、两条指令合计的 PRF bank 读次数合法且没有 flush 时才算交接成功。交接成功的同一个时钟沿必须清除 IQ `valid`，并锁存目标 FU、ROB tag、源物理寄存器、重复源标记和被选 entry 编号；局部选中或全局方案中的临时候选不能提前离开 IQ。
- **已确认**：指令一旦交接成功，其所有权转移给 FU/PRF 读取流水寄存器。刚交接时，本地寄存器通过“已锁存的 entry 编号”暂时引用 IQ 中尚未改写的执行 payload；PRF 读取周期结束时再把 payload、操作数和 valid 一起锁存到 FU 本地。此后下游停顿时由本地寄存器保持全部内容，不把指令退回 IQ，也不使用重新发射来解决普通反压。
- **已确认**：ALU 和 LSU 的入口采用可停顿流水寄存器，并允许同一时钟沿完成“旧指令前进、新指令接替”。入口能够接收的条件是“当前为空，或当前旧指令本周期确定能进入下一级”。旧指令不能前进时保持原内容，并只屏蔽对应 FU 的新发射；其他 FU 仍可工作。
- **已确认**：不把 IQ 的“禁止同周期复用”规则套用到 FU 入口。若 FU 入口必须先变空一整周期才能重新接收，流水化 ALU 的最大接收率会下降到最坏每两周期一条。
- **已确认**：第一版不增加入口备用保持项、深本地队列或 credit 计数。先综合允许同沿前进/接替的局部反压路径；若该路径不能满足时序，再增加局部 skid entry 切断路径，而不是降低 ALU/LSU 的正常接收率。
- **已确认，第一版 MDU**：复用当前单 owner 的 Mul/Div 单元，一条 MDU 指令从接收到结果被 bank 接收期间占有该单元；忙碌时由本地 busy/owner 阻止新 MDU 发射，完成结果未被消费时保持。第一版不把 MUL 改成每周期可接收的新流水结构；若以后单独流水化 MUL，再为多项在途乘法结果重新设计 owner、flush 和输出反压。
- **已确认，窄读请求顺序**：两条获选指令形成两个窄请求包，每包只带两个 `psrc`、实际读使能、重复源标记、目标 FU 和 ROB tag。四个可能的请求固定按“包 0 源 0、包 0 源 1、包 1 源 0、包 1 源 1”排列。`LS+INT` 时包 0 为 LS、包 1 为 INT；`INT+INT` 时按 ALU0/ALU1 排列；单发和 MDU 独占只使用包 0。
- **已确认，bank 内物理端口整理**：最终仲裁只保证每个 bank 不超过两个请求，不在年龄选择结果之后继续串行计算具体物理端口。PRF 读取周期内，bank0 和 bank1 分别对上述四个固定位置并行产生“本 bank 第一个请求”和“本 bank 第二个请求”的 one-hot 结果，直接驱动两份 LUTRAM 的地址，并用同一份 one-hot 把数据送回原请求位置。这不是第二次仲裁，不会失败或重试。
- **已确认**：下一周期使用已经寄存的 entry 编号读取 IQ 的静态执行 payload；该读取与 PRF 组合读并行，周期末把操作类型、立即数、`pdst`、LSQ 标识及 PRF 操作数一并锁存到已经预留的目标 FU 操作数保持寄存器。该寄存器之后若因执行侧反压而停顿，只保持本地内容，不再引用 IQ，也不重新读取 PRF。
- **已确认，PRF 读取级不反压 IQ**：IQ 交接一旦在仲裁沿成立，目标操作数保持位置已经被保留，随后一个 PRF 读取周期必须在下一时钟沿完成捕捉；中途没有“端口后来冲突、再试一次”或“下游临时拒绝”的路径。唯一可以取消这次捕捉的是按 ROB tag 命中的 flush。捕捉完成后的普通停顿全部由 FU 本地寄存器承担。
- **已确认**：物理端口整理不得放在“最终最老组合已经选出”之后、再以串行计数方式写进仲裁沿寄存器。独立综合中这种写法把 IQ 到端口 owner 寄存器的路径拉到 19 层逻辑；采用固定四请求、两个 bank 并行 one-hot 的读周期网络。
- **已确认**：`P0` 和未使用源不产生读使能；`src1_reuse_src0` 命中时源 1 不产生第二个请求，返回后在目标 FU 本地复制源 0。flush 在 PRF 读取期间到来时允许 LUTRAM 和 payload 组合信号继续变化，但在周期末用 ROB tag 抑制被取消指令的操作数 valid。
- **已确认，简单 flush 方案**：任何分支 flush 发生的周期都暂停新的 IQ 到 PRF/FU 入口交接，不再尝试让当周期获选的更老指令继续通过；它们保留在 IQ，下一周期重新参加仲裁。这有意损失至多一个发射周期，以避免把额外的 ROB 年龄筛选串入最终交接路径。
- **已确认**：已经离开 IQ 的流水项不能在 flush 时全部清空。FU 入口控制寄存器、PRF 读取/owner 寄存器、操作数寄存器、执行流水寄存器和结果保持项必须携带 ROB tag 或等价的成组 kill 信息；分支误预测只取消严格年轻项，分支本身和更老项继续。valid 更新中 kill 优先于前进和接替。

### 5.7 IQ entry 字段和物理组织

公开实现给出的共同经验是：源寄存器 tag、ready 和选择状态会被每周期反复访问，而立即数、具体运算类型等执行 payload 只需要在指令被选中后读取。RSD 这个面向 FPGA 的乱序核明确把 wakeup/select 状态与 instruction payload RAM 分开；BOOM 和香山也把源就绪状态作为 entry 的独立调度状态。当前处理器采用同样的思想，但针对 `INT=4、LS=2、MDU=1` 的极小队列进一步简化。

- **已确认**：不把现有的完整 `decoded_uop_t` 原样复制到每个 IQ entry，也不在发射时回读 ROB 来补齐执行信息。三个 IQ 分别使用只适合本队列的紧凑 payload；执行真正需要的信息存在本地，提交、异常、恢复和内存顺序信息仍分别由 ROB、checkpoint 和 LSQ 管理。
- **已确认**：每个 entry 在 RTL 中逻辑拆成两部分。
  - “调度状态”只保存每周期参加唤醒、年龄、配对和 flush 判断的小量信息，使用独立 FF。
  - “执行 payload”保存写入后不再变化、只有该 entry 获选后才使用的信息。它不参与 ready/年龄/配对组合逻辑。
- **已确认**：当前三个 IQ 太浅，第一版两部分都采用按 entry 的 FF，不为了 4/2/1 项小表强行构造多写口 LUTRAM。执行 payload 只在分配时写入，普通等待、唤醒、发射和 flush 都不重写或清零它；有效性只由 `valid` 和流水级 owner 控制。若以后扩大 IQ，再单独综合比较 payload LUTRAM。

三个 IQ entry 共有的调度状态为：

- `valid`：该位置当前是否拥有一条尚未发射的指令；
- `rob_tag`：包含 ROB index 和翻转信息，用于年龄和选择性 flush；
- `psrc0/psrc1`：两个 6 bit 源物理寄存器号；
- `src0_ready/src1_ready`：两个源是否保证能在 PRF 读取周期取得；
- `src1_reuse_src0`：两个有效源映射到同一非零 `psrc` 时置位，使 PRF 只读一次并在 FU 本地复制；
- INT 和 LS 额外保存已经确定的 3 bit PRF 读取类型；MDU 独占发射且单条指令最多读两次，每个 bank 本来就有两个读口，因此 MDU entry 不需要保存该字段。

- **已确认**：重命名/分配在写 IQ 前把未使用的源、立即数源和 `x0` 全部规范化为 `P0`，并把对应 ready 置 1。由于 `P0` 永久保留且不可分配，`psrc==P0` 同时表示“操作数取常数 0、不占 PRF 读口”，IQ 不再重复保存两位 `src_used`。
- **已确认**：不写架构寄存器的指令把 `pdst` 规范化为 `P0`。FU 和写回侧用 `pdst!=P0` 判断是否产生 PRF 写入，IQ payload 不再重复保存 `dst_write`。

各队列增加的字段如下。

#### INT IQ

- 调度状态额外保存 `alu0_only`，表示这条真实控制流只能进入带重定向/恢复通路的 ALU0；普通整数指令为 0。最终仲裁不在关键路径上重新解码完整操作类型。
- 执行 payload 保存 `pdst`、ALU 操作、两个操作数的选择方式、32 bit 立即数、32 bit PC，以及分支条件、目标地址计算、对齐和链接结果 `PC+4` 所需的紧凑控制。
- 对分配了 checkpoint 的真实控制流，只额外保存 checkpoint 有效位和 1 bit checkpoint 编号。预测方向、预测目标、预测器训练资料、RAT 快照和 Allocation Mask 不复制到四个 INT entry；它们保存在以同一编号关联的两项 branch-checkpoint 状态中。ALU0 通过 checkpoint 编号和 owner ROB tag 取得并验证这些资料。

#### LS IQ

- 调度状态额外保存 LSQ 编号和 Load/Store 类别；LSQ 根据该编号返回当前是否允许发射。IQ 不复制会在 LSQ 中动态变化的地址有效、内存相关和 replay 状态。
- 执行 payload 保存 `pdst`、地址立即数、访问宽度和 Load 的有符号/无符号属性。Store 的写入数据仍由 `psrc1` 在发射后从 PRF 读取，不在 IQ 中保存 32 bit 数据。
- PC、异常 PC 和最终访存地址不重复保存：PC 由 ROB 保留用于精确异常，LSU 产生的地址或异常信息携带 ROB tag 写回 ROB/LSQ。

#### MDU IQ

- 唯一 entry 只保存公共的 ROB/source 状态，以及执行 payload 中的 `pdst` 和 3 bit 乘除法操作类型。
- 有符号、无符号、高半部分和余数选择已经包含在乘除法操作类型中，不再拆成重复控制位；MDU entry 不保存 PC、立即数、LSQ 信息或 PRF 读取类型。

下列内容明确不进入普通 IQ entry：

- 逻辑源/目的寄存器号、`old_pdst` 和提交映射；
- 32 bit 源操作数值和完整原始指令；
- ROB complete、异常原因和提交状态；
- RAT 快照、Allocation Mask 和完整预测器训练资料；
- Load miss、MSHR、内存相关、Store 已提交和 replay 状态；
- 投机 Load 唤醒的 poison/cancel/timer 状态。第一版没有这种推测唤醒，也不为未来功能提前增加布线。

- **已确认**：仲裁周期只从获选 entry 多路选择窄的 `psrc`、ROB tag 和 entry 编号。由于 IQ 不允许在发射沿立即复用该位置，发射后空出的 entry 最早在下一个时钟沿才会被新 Dispatch 覆盖；因此旧执行 payload 在整个 PRF 读取周期仍保持稳定。用已经寄存的 entry 编号读取执行 payload，并与 PRF 数据在同一个周期末锁存，不增加流水级，同时把 PC、立即数和宽控制多路选择从年龄仲裁尾部移走。
- **已确认**：执行 payload 按目标 FU 分别做本地选择，不建设一个包含三种 IQ 全部字段的全局宽总线。INT 最多形成两路 4 选 1，LS 为一路 2 选 1，MDU 唯一 entry 直接读取。
- **已确认，第一版**：译码时已经确定为非法、ECALL 或 EBREAK 的指令只进入 ROB 并记录完成/异常，不进入 IQ。CSR、MRET 和 FENCE 使用一个独立的单项串行槽，在成为 ROB 头且更老副作用已经排空后执行；它不计入三个乱序 IQ，也不让罕见的特权控制字段扩宽全部 INT entry。串行槽与 ALU0/特权单元的具体交接在 ROB/提交部分落实。

公开实现对照：

- [RSD：面向 FPGA 的乱序 RISC-V 处理器](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)把 IQ 划分为 wakeup、select 和 instruction payload RAM，并使用 RAM 保存不会参与每周期选择的 payload。
- [BOOM Issue Unit](https://docs.boom-core.org/en/latest/sections/issue-units.html)在 issue slot 中独立维护源操作数 presence/ready 状态，并把不同类型指令放入拆分的 IQ。
- [香山 IssueQueue](https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/backend/Schedule_And_Issue/IssueQueue/)展示了推测唤醒、取消和写回冲突跟踪所需的额外状态；当前第一版没有相应功能，因此不照搬这些字段。
- [BOOM Execute Pipeline](https://docs.boom-core.org/en/latest/sections/execution-stages.html)同样让 CSR 等有副作用指令采用非推测执行，为当前独立串行槽提供了参考。

## 6. PRF 和数据就绪

### 6.1 PRF 访问发生的位置

- **已确认**：重命名阶段只处理逻辑/物理寄存器编号和映射，不读取通用操作数数据。
- **已确认**：PRF 在指令被最终选中后读取，执行结果获得目标 bank 写入时隙后写回。
- **已确认**：PRF 端口需求由实际 FU 发射宽度、各指令源操作数数量和同周期写回数量决定，而不是简单由双宽 rename 推导成固定的 6 读 1 写。
- **已确认**：PRF 不使用 BRAM，获选存储阵列为 LUTRAM，并提供组合读。
- **已确认**：组合读不等于必须把选择和 PRF 读取塞进同一个流水级；PRF 读数据仍可以在下一个时钟沿寄存。
- **已确认**：整数 PRF 使用两个地址 bank，`bank=ptag[0]`，bank 内地址为 `ptag[5:1]`。两个 bank 分别保存偶数和奇数物理寄存器，不在 bank 之间复制数据。
- **已确认**：每个逻辑 bank 保存 `32x32 bit`，由两份内容完全相同的 `32x32 bit` LUTRAM 表组成。每份物理表提供 1 个组合读口和 1 个同步写口；同一 bank 的写入同时广播到两份表。
- **已确认**：每个 bank 每周期最多读取 2 个寄存器、写入 1 个寄存器。全 PRF 最多形成 4 个逻辑读和 2 个逻辑写，但两个写必须分别落到不同 bank。
- **已确认**：读取冲突在 IQ 仲裁时阻止；写入结果按 `pdst[0]` 送到对应 bank 的单级写回流水寄存器，同 bank 的额外结果必须留在 FU 输出保持寄存器中等待。
- PRF 逻辑读端口需求应按每周期实际发射指令的 PRF 源操作数总数计算；立即数和 `x0` 不占 PRF 读口。
- PRF 逻辑写端口需求应按同周期完成且需要写 `rd` 的结果数计算。它不等于 rename/commit width，旧 Load、MDU 和当前 ALU 的结果可能在同一周期碰撞。
- 若 PRF 分为多个地址 bank，则每个周期必须分别满足每个 bank 的读写端口限制；否则应在发射/写回仲裁中阻止冲突，或使用结果缓冲等待。
- **已确认**：以全核最多发射 2 条、4 个逻辑读口、每 bank 1 个写口作为第一版 PRF 端口基线。
- **已完成评估**：在 `xc7k325tffg900-2`、Vivado 2024.1、5 ns 约束下，对包含 2-of-4 选择、bank 端口路由、返回选择和写回选择的独立测试壳完成一次自由布局 post-route 比较：

| 方案 | WNS | LUT | FF | LUT Memory |
| --- | ---: | ---: | ---: | ---: |
| 单体 `64x32 4R2W` FF | -4.150 ns | 4913 | 2542 | 0 |
| 两个 `32x32 2R1W` FF bank | -3.412 ns | 4233 | 2582 | 0 |
| 两个 `32x32 2R1W` LUTRAM bank | -2.615 ns | 1212 | 585 | 88 |
| 两份完整 `64x32 2R2W` FF 副本 | -4.435 ns | 7332 | 4633 | 0 |

该测试壳的延迟包含外围仲裁和动态路由，不能解释为“纯 PRF 无法达到 200 MHz”。获选 LUTRAM 方案首条 PRF 读路径中，逻辑延迟约 0.628 ns、路由约 4.792 ns，其中 RAMD32 单元本身约 0.043 ns；结论是外围布线和端口分配需要流水化与局部布局，而不是 LUTRAM 存储访问本身过慢。
- **评估勘误**：上述首轮测试壳把物理寄存器最高位误写成 bank 位，而正式设计使用 `ptag[0]`。两个 bank 都是同样的 `32x32`，所以该错误不改变四种存储组织的规模和结构排名，但首轮随机 bank 冲突计数不能作为当前架构的数据。
- **已完成读回网络复测**：在 `/tmp` 中把 bank 修正为 `ptag[0]` 后，用 1000 个随机周期对照影子 PRF，新旧读回结果一致。若在最终仲裁结果之后再串行整理物理端口，post-route 的仲裁/端口 owner 路径为 8.087 ns、19 层逻辑，因此明确不采用。改为“仲裁沿锁存四个有序请求，PRF 读取周期内两个 bank 并行产生第一/第二请求 one-hot”后，PRF 读路径为 5.349 ns，其中逻辑 0.703 ns、布线 4.646 ns、8 层逻辑；整个测试壳 WNS 仍为 -1.803 ns，主要违例已转到测试壳的旧式串行 issue/write 选择。
- **结论边界**：复测只证明读回网络不需要额外增加一个流水级，并排除了错误的串行端口分配方式；它不代表完整 CPU 已经达到 200 MHz。正式 RTL 仍要使用当前 5.5 节的并行组合选择，并把 bank LUTRAM、读回 one-hot 和对应 FU operand FF 做局部布局。
- [AMD Vivado UG901](https://docs.amd.com/r/2025.1-English/ug901-vivado-synthesis/Choosing-Between-Distributed-RAM-and-Dedicated-Block-RAM?contentId=aBKFGaNF1aFhM4nCRwkHZg)规定分布式 RAM 为同步写、异步读。当前时序让生产者在时钟沿写入，消费者在该时钟沿之后的整个周期组合读取，因此可以自然看到新值；消费者不是在同一个沿捕捉旧的组合输出。
- **已确认**：执行完成和 PRF 写回解耦。每个 bank 设置一个单级写回流水寄存器，不使用可积压多项结果的深 FIFO。FU 结果只有在获得目标 bank 的固定写入时隙后，才同时进入该寄存器并向 IQ 发出提前 tag 唤醒；未获授权的结果必须留在 FU 输出缓冲并形成反压。
- **已确认**：单级写回寄存器至少保存 `valid、bank_addr/pdst、data、rob_idx` 和 flush 所需信息。旧内容在一个时钟沿写 PRF 时，同一时钟沿可以锁存下一项，因此每个 bank 可持续达到每周期一次写入。
- **已确认**：分支解析结果、重定向信息和执行阶段发现的异常在 FU 得到结果时立即写入 ROB 的对应元数据，不等待 PRF 写回。分支 checkpoint 也在解析正确时立即释放、误预测时立即发起恢复；是否写链接寄存器是另一条独立的 PRF 写回条件。
- **已确认，控制与数据分离**：ALU0 对真实控制流产生一次性的“预测验证完成”事件；`JAL/JALR` 的 `PC+4` 则作为独立数据等待目标 bank。写回冲突只能拖延数据，不能拖延已经算出的重定向、checkpoint 释放和预测器训练。
- **已确认，一次性约束**：若可写 `rd` 的控制流已经发送验证事件、但数据因结果保持项忙而仍停在 ALU0 执行输出寄存器，必须用本地 `control_sent` 等价状态记住事件已经消费；停顿期间不能每周期重复重定向、重复释放 checkpoint 或重复训练。数据被 bank 接收后该 owner 才完全离开 ALU0。无 `rd` 的控制流在一次性控制事件被接收后即可离开并标记完成。
- **不采用的默认方向**：不让 ROB 按程序顺序长期保存所有结果并在 ROB 头写 PRF。这样会使 ROB 重新承担数据存储和多端口读取功能，并与当前非数据捕捉、统一 PRF 的方案冲突。
- **已确认**：普通带 `rd` 且没有异常的指令只有在 PRF 实际写入时才设置最终 `complete`/`wb_done`。第一版 ROB 不为所有普通指令长期保存独立 `exec_done` 位；“已经算出但还没写 PRF”的状态由 FU 结果保持项或 `bank_wb_reg` 的 owner 表达。
- **已确认**：没有 `rd` 的分支在解析完成后即可完成；产生异常的指令在异常元数据写入 ROB 后即可等待头部处理，不要求把无效结果写 PRF。Store 的完成条件由后续 LSQ/SQ 设计定义，不套用 PRF `wb_done`。
- **已确认**：采用 `选择 -> PRF读 -> 执行` 三个独立组合周期，不合并选择与 PRF 读取。
- **已确认**：如果消费者在生产者写 PRF 的时钟沿之后才开始组合读，同地址会自然看到新值，不需要写回旁路。
- **已确认**：如果消费者要在生产者写 PRF 的同一个时钟沿锁存操作数，则不能依赖 FF/LUTRAM 的 write-first 语义，必须显式旁路或将消费者延后一拍。

### 6.2 IQ 中的就绪状态

- **已确认**：IQ 至少保存每个源操作数的物理 tag 和 ready 位。
- **已确认**：结果生产者必须最终产生一次可被等待者观察到的 `{valid, pdst}` 唤醒事件。仅写 PRF 而完全不唤醒，会使已经驻留 IQ 的依赖指令永久等待。
- **已确认，第一版**：采用 non-data-capture IQ，只保存 tag/ready，不在 IQ 中保存 32 位操作数，也不建设全局 32 位结果前递网络。操作数在仲裁之后统一从 PRF 读取。
- **已确认**：维护每个物理寄存器一位的全局 `prf_ready`。`P0` 永久为 1；新 `pdst` 分配给新生产者时对应位清零；只有结果实际写入 PRF 时才置 1。Free List 中物理寄存器遗留的旧值和旧 ready 不得被新 owner 使用，因此同周期新分配必须旁路覆盖旧状态。
- **已确认，状态载体**：`prf_ready`、`busy_map`、`committed_busy_map` 和各 checkpoint Allocation Mask 都是 64 bit FF 位图，并在物理上按偶/奇 bank 分成两个 32 bit 局部块。它们需要多处组合查询、按位置位/清零和恢复整体覆盖，不使用 BRAM/LUTRAM 伪装成单端口表。
- **已确认**：正常 commit 释放 `old_pdst` 时只清除 `busy_map`，不要求同时清除该项遗留的 `prf_ready`；空闲物理寄存器不可能被 RAT 指向，新 owner 分配该编号时会无条件把 ready 清零。这样不把 commit 释放线额外广播到 ready 表，异常恢复和分支回收仍按各自规则整体覆盖/清除。
- **已确认**：FU 完成事件的 `pdst` 只更新 IQ entry 的源 ready FF；不能让完成 tag 的组合比较结果直接串入同周期年龄仲裁。下一周期仲裁读取已经锁存的 ready 位。
- **已确认**：提前唤醒必须与 bank 写入时隙授权绑定。只有 `fu_result_valid && bank_write_slot_granted` 时，才能在同一周期向单级写回寄存器发送结果并向 IQ 广播 `pdst`。
- **已确认，按 bank 广播**：每周期最多产生两条唤醒 tag，分别固定属于 bank0 和 bank1。一个源物理寄存器的最低位已经确定其 bank，因此每个 IQ 源只与自己 bank 的那一条 `wb_accept` tag 比较，不同时比较两条广播；新 entry 检查当前 `bank_wb_reg` 时也只检查对应 bank。这把全局比较数量和跨 bank 布线减半。
- **已确认**：表示“PRF 中已经存在有效数据”的全局 `prf_ready` 只能在 PRF 实际写入时置位；提前一拍的 IQ 局部 ready 是基于已经预留写入时隙的调度承诺，两者语义不能混淆。
- **已确认，新 entry 初始化**：未使用的源、立即数源和 `x0` 初始化为 ready；同周期前一条指令新分配的 `pdst` 若被后一条作为源使用，必须初始化为 not-ready；其他有效 PRF 源在 `prf_ready[psrc]` 为 1、命中本周期 `wb_accept` 的提前唤醒，或命中当前 `bank_wb_reg` 将在本时钟沿实际写入的 `pdst` 时初始化为 ready。
- **已确认**：新 entry 必须同时捕捉“本周期刚获得固定写入时隙”的 tag 和“当前写回寄存器将在本沿写入”的 tag，避免指令恰好在两者之间进入 IQ 后永久错过一次性唤醒。两路或多路 tag 同时命中时做 OR，不需要区分来源优先级。
- **已确认，驻留 entry 更新**：对仍然有效且未发射、未被 flush 的 entry，每个源的 ready 采用保持置位语义：原来为 1 就保持为 1，原来为 0 且命中有效 `wb_accept` 时变为 1。ready 不因普通停顿重新清零。
- **已确认，Store 基线**：第一版 Store 必须等待地址基址和写入数据两个实际使用的源都 ready 后才可从 LS IQ 发射，不提前单独计算地址。若后续 LSQ 需要地址先行，再增加 Store 数据 tag/ready 的独立保存和读取通路。
- **已确认，entry 更新优先级**：reset/flush kill 最高；flush 当周期禁止新 enqueue。对 surviving entry，最终 issue 交接成功时清除 valid；否则保留 entry 并锁存 ready 唤醒结果。对空 entry，只有统一 Dispatch 接收结果批准时才写入 payload 和上述初始化 ready。由于第一版不复用同周期刚发射的位置，同一个 entry 不会同时发生 issue 清除和 enqueue 覆盖。
- **已确认，`prf_ready` 冲突约束**：同一个物理 tag 不应在同一时钟沿既作为仍存活的旧 owner 写回、又分配给新 owner；Free List、flush kill 和结果保持规则必须保证这一点，并设置断言。若实现中仍为防御性逻辑规定优先级，新 owner 的分配清零不能被已取消旧 owner 的迟到写入重新置位。

### 6.3 写回仲裁、结果保持和 flush

#### 每个 bank 独立仲裁

- **已确认**：bank0 和 bank1 分别设置一个独立的 `1-of-N` 写回仲裁器，不能先在所有 FU 中无约束地选择两个结果。每个结果根据 `pdst[0]` 只申请一个 bank，因此两个 bank 可以在同一周期各授权一个结果。
- **已确认**：按当前四个结果源 ALU0、ALU1、LSU、MDU，实现时先并行生成 `req_bank0[3:0]` 和 `req_bank1[3:0]`。每项请求至少满足 `result_valid && writes_prf && bank_match && !flush_kill`。
- **已确认**：同一个 bank 内使用 ROB 最老者优先，不采用按 FU 类型固定优先级或轮询。FU 输出项随结果保存 ROB tag；年龄比较使用包含 wrap/generation 的 ROB 环形顺序。
- **已确认**：四个结果源的六组两两年龄关系并行预计算一次，并由两个 bank 的请求 mask 共享。每个候选的 grant 由“自身请求有效且不存在更老的同 bank 请求者”并行产生，避免先分 bank、再串行扫描或重复选择形成长优先链。
- **已确认**：每个 bank 使用 one-hot grant 在最后一级选择 `data、pdst、rob_idx` 等 payload，并以该 bank 的单级 `bank_wb_reg` 为组合路径终点。年龄控制计算与 FU 的 32 bit 结果计算尽量并行，宽数据只经过最后的 one-hot 选择。

#### FU 输出保持和局部反压

- **已确认**：每个 FU 使用一个单项结果保持位置，并以 `valid/ready` 语义连接 bank 仲裁器。结果未获授权时，必须保持 `valid、data、pdst、rob_tag` 稳定并在下一周期重新申请。
- **已确认**：未获授权只反压对应 FU。已经发射的指令保留在 FU 本地流水寄存器中，不退回 IQ；其他 FU 和另一个 bank 可以继续工作。每个 FU 的本地 `can_accept` 与年龄/配对关系并行预计算，只在该 FU 候选请求入口做资格门控；不能等全局已经选中之后再发现下游不收、把指令退回 IQ，也不能让一个 FU 的反压串到其他 FU 的选择通路。
- **已确认**：结果保持位置允许同一时钟沿完成“旧结果获授权、新结果接替”。若旧结果未获授权，则不能让新结果覆盖它；FU 的上游执行/操作数寄存器必须停住。
- **已确认**：ALU0/ALU1 各自设置结果保持寄存器；MDU 可以利用其 `done/result` 保持到 `consume` 的状态，bank grant 对应正常 `consume`；LSU 设置 Load 返回结果保持寄存器，并要求 Cache/LSU 返回接口在未接收时保持结果或接受反压。
- **已确认，第一版**：每个 FU 只使用一个结果保持项，不增加深结果 FIFO 或第二个 skid entry。该选择足以保证正确性，并把等待限制在产生冲突的 FU 本地；后续性能计数若显示某个 FU 经常因同 bank 写冲突停顿，再把额外 entry 作为明确的第二版优化，而不是第一版遗留项。
- **已确认，候选来源**：保持项非空时，bank 仲裁看到的是保持项中的旧结果；保持项为空时，可以直接看到 FU 本周期新产生的结果。旧保持项获授权后，新结果可以在同一个时钟沿接替进入保持项，但新结果不能越过旧结果在同一周期再次获得 bank 授权。
- **已确认，普通 next-state**：保持项为空且新结果未获授权时，把新结果锁存进保持项；为空且新结果直接获授权时继续保持为空。保持项非空且未获授权时，原内容和 valid 必须保持稳定并反压 FU 上游；非空且获授权时，若上游同时有新结果则用新结果接替，否则清空。

#### 唤醒与固定写入承诺

- **已确认**：统一定义 `wb_accept = fu_result_valid && bank_grant && !flush_kill`。同一个 `wb_accept` 必须同时控制 `bank_wb_reg` 接收和 IQ tag 唤醒，禁止直接使用未经 bank 授权的 `fu_done/result_valid` 唤醒 IQ。
- **已确认**：结果一旦通过 `wb_accept` 唤醒仍然存活的 IQ 指令，就已经占有目标 bank 的下一次固定写入机会。进入 `bank_wb_reg` 后不再进行第二次仲裁；对应 PRF bank 写口只由该寄存器驱动。
- **已确认**：旧 `bank_wb_reg` 内容写入 PRF 的同一时钟沿可以接收下一项，因此每个 bank 可以持续每周期写一次。普通结果在 PRF 实际写入时才更新 `prf_ready` 和对应 ROB 的最终 `wb_done/complete`。
- **已确认**：正常时序为：`cycle n` 完成结果并进行 bank 仲裁；`edge n+1` 同时锁存 `bank_wb_reg` 和 IQ ready；`cycle n+1` 仲裁消费者并由 `bank_wb_reg` 驱动写口；`edge n+2` 写 PRF；`cycle n+2` 消费者组合读取新值。

#### 分支 flush

- **已确认**：checkpoint 恢复 RAT 和 Free List，PRF 内容不恢复。错误路径结果若在 flush 前已经写入 PRF，可以保留为不可达的旧值；恢复时钟沿之后仍滞留在 FU、LSU/MDU 或写回结构中的年轻迟到结果必须取消，防止其 `pdst` 被回收和重新分配后发生旧写覆盖。恢复沿开始前已经进入 `bank_wb_reg` 的唯一固定写入按下述特例处理。
- **已确认**：FU 输出保持项和 `bank_wb_reg` 均携带 ROB tag。分支预测错误时只清除严格年轻于该分支的项；比分支更老的结果和分支自身不能被误杀。
- **已确认**：flush 当周期全局暂停新的 IQ 发射交接；当周期局部或全局仲裁结果均不写入 FU/PRF 读取级，原 IQ entry 保留并在下一周期重新仲裁。已经位于 FU 入口、PRF 读取、操作数和执行流水级的项仍按 ROB tag 只清除年轻者，不能为了控制简单而误杀已经离开 IQ 的更老指令。
- **已确认**：任何 flush/恢复周期都不产生新的 bank grant、`wb_accept` 或 IQ 唤醒。年轻 DIV/MDU owner 被取消；已经发出的年轻 Load 请求允许物理访问结束，但返回结果必须丢弃。
- **已确认，恢复沿已经排定的写入**：周期开始时已经位于 `bank_wb_reg` 的结果，可以在恢复时钟沿完成原定的 PRF 物理写，即使它属于将被清除的年轻指令。这个时钟沿禁止新物理寄存器分配，恢复逻辑同时使该 ROB owner、RAT 映射和 ready 状态失效，因此这次写只是写入一个马上不可达的旧值，不会覆盖新 owner。这样不需要把刚产生的全局 flush 串到 LUTRAM 写使能的远端关键路径。
- **已确认，安全边界**：上述放宽只适用于恢复沿开始前已经进入 `bank_wb_reg` 的唯一固定写入。恢复沿之后，年轻的 FU 保持项、bank 写回项和迟到 LSU/MDU 结果必须全部失效；下一周期才允许重新分配被回收的 `pdst`，因此绝不允许错误路径结果在物理编号重新使用后继续写入。
- **已确认**：flush 取消已经唤醒的错误路径结果不违反固定写入承诺，因为对应消费者也会一起失效；对 flush 后仍然存活的 IQ 指令，已经发出的唤醒承诺不得撤销。

#### 精确 next-state 优先级

第一版统一采用以下顺序，不为 LSU 返回另开一条直达 PRF 的特殊通路：

1. hard reset 清除所有 valid，不产生 PRF 写入。
2. 精确异常恢复或分支 flush 时，禁止新 grant 和新唤醒。现有 `bank_wb_reg` 完成本沿已经排定的物理写后清空。分支恢复时，严格年轻 owner 的 ready/complete 置位被抑制，`C.alloc_mask` 覆盖的 `prf_ready` 清零；仍存活的更老 owner 可以正常完成本沿 ready/complete 更新。精确异常时没有更老未提交 owner，最终由 `prf_ready <= committed_busy_map` 和整条未提交 ROB 失效覆盖所有旧写回状态。
3. 同一个恢复沿，所有年轻 FU/执行/LSU/MDU 保持项清除，存活的更老保持项原样保留。FU 上游的 `ready` 在恢复周期拉低，不做“清掉一个、同沿再塞进一个”的特殊替换；存活的新结果由上游执行寄存器保持到下一周期。
4. 普通周期中，旧 `bank_wb_reg` 在时钟沿写 PRF、置 `prf_ready` 并标记 ROB 完成；同一个时钟沿可以装入本周期新 grant，因此每个 bank 仍能持续每周期写一项。
5. LSU 的 Load 返回必须先遵守 LSU 结果端的 `valid/ready` 规则：目标保持项忙时由 LSU/Cache 保持响应或在本地返回缓冲中保存；不能绕过 FU 保持项与 ALU/MDU 争抢 `bank_wb_reg`。

RTL 至少设置下列断言：

- 每个 bank 每周期最多一个 grant，每个 FU 每周期最多被一个 bank 接收；
- `wb_accept`、`bank_wb_reg` 装入和 IQ tag 唤醒三者必须对应同一 owner；
- 非 flush 周期中，存活的 `bank_wb_reg` 恰好写一次 PRF，PRF 实际写入与 `prf_ready`/ROB `wb_done` 使用同一 owner；
- flush 周期没有新 grant，恢复沿之后不存在任何年轻 `bank_wb_reg` 或 FU 结果保持项；
- FU 保持项未获授权且未被 kill 时，`valid、data、pdst、rob_tag` 必须保持稳定；
- LSU 返回在 `ready=0` 时不得丢失存活结果；被 flush 的返回不得进入写回；
- recovery 周期不得同时分配新 `pdst`，从而保证恢复沿允许的旧 PRF 物理写不会碰到新 owner；
- checkpoint 解析事件必须命中相同的槽号和 `owner_rob_tag`，恢复后被释放或被清除的槽不能再次接受旧 owner 的迟到事件；
- 同一个 ALU0 owner 的预测验证、checkpoint 释放/恢复和预测器训练最多各发生一次；`control_sent=1` 且数据未被 bank 接收时，数据 payload 必须保持而控制事件不得重发；
- 任意有效 RAT/RRAT 映射必须指向 busy 物理寄存器；RRAT 的 one-hot 并集始终等于 `committed_busy_map`。

## 7. 唤醒策略

第一版采用“完成结果获得固定写入时隙后，提前一拍进行 tag 唤醒”的统一基线，不使用依赖 32 位结果旁路的发射时推测唤醒。书中 8.5 所述的 Wake-up/Select 分级结构与此一致：ready 在时钟沿更新，年龄仲裁读取寄存后的 ready 状态。

- **已确认**：执行结果在 `cycle n` 产生后，同时申请对应 bank 的写入时隙和 IQ tag 唤醒。若授权成功，结果和 IQ ready 在 `edge n+1` 分别进入 bank 单级写回寄存器与 ready FF。
- **已确认**：`cycle n+1` 使用更新后的 ready FF 进行年龄仲裁；`edge n+2` 同时完成生产者 PRF 写入，以及消费者读地址、bank 端口和 owner 的锁存。
- **已确认**：`cycle n+2` 组合读取刚在 `edge n+2` 写入的 LUTRAM 新值；`edge n+3` 锁存 operand，`cycle n+3` 执行消费者。消费者不是在 PRF 写入的同一个沿捕捉数据，因此不依赖 write-first 或数据旁路。
- **已确认**：上述时序要求被唤醒结果确定在 `edge n+2` 写入。若目标 bank 没有可预留时隙，则结果必须留在 FU 输出缓冲，不能提前唤醒 IQ。
- **已确认**：DIV 不建设专用延迟广播网络；DIV 真正完成后参加所属 bank 的写入时隙申请。
- **已确认**：Load hit 在数据真正返回并可申请写入时隙后唤醒；Load miss 等 refill 完成。第一版不根据未确认的 Cache hit 进行数据推测唤醒。
- **已确认**：不在 bank 写口前设置更深 FIFO。结果的等待发生在 FU 输出保持寄存器；bank 仲裁器每周期从等待结果中最多为每个 bank 授权一项。
- **已确认，第一版边界**：不实现 32 bit 数据旁路，也不在指令发射时根据预测延迟提前唤醒。INT、MUL、DIV 和 Load 全部使用“真实结果获得 bank 固定写入时隙后唤醒”的统一规则。
- 局部 INT/MUL 旁路或发射时推测唤醒只作为未来可能的性能功能；在基线模型和完整 FPGA 时序证明其收益足以覆盖布线与取消逻辑之前，不进入第一版接口和 entry 字段。

唤醒广播只传递 `valid + pdst`，实际数据以 PRF 为稳定来源。错误路径 FU 输出结果和 bank 单级写回寄存器必须在物理寄存器重新分配前失效，避免旧结果覆盖重新使用的 `pdst`。

## 8. Load/Store 与统一 Store Queue

### 8.1 第一版组织

- **已确认**：继续使用一个共用的 LS IQ 调度 Load 和 Store，不另外拆出 Load IQ 与 Store IQ。LS IQ 只负责等待源操作数并选择谁进入 LSU；内存顺序和 Store 生命周期由 Store Queue 管理。
- **已确认，第一版容量**：只设置 **2 项统一 Store Queue**。不再额外保留一份独立的两项 D-Cache Store Buffer；当前 `dcache_store_buffer` 的地址、数据、字节掩码存储和最近 Store/refill 合并能力重构进统一队列。该选择有意用更早的 Store 分配停顿换取更少的存储、比较器和跨结构布线。
- **已确认**：统一 Store Queue 同时容纳尚未完成、已经完成但尚未提交、已经提交但尚未写完的 Store。每项至少保存 `valid、rob_tag、address、address_ready、data、data_ready、byte_mask、committed`；外设/非缓存属性按后续 LSU 接口需要增加。
- **已确认，两项专用控制**：不使用通用环形 FIFO 的 head、tail 和 count。两个 entry 各有 `valid`，另设一个 1 bit 选择状态：只有一个 entry 有效时，空闲 entry 就是下一个分配位置；两个 entry 都有效时，该位指出谁更老、应当先写出。`00/01/10/11` 直接给出空、单项和满状态。
- **已确认**：分配和最终写出仍保持程序顺序，但执行结果按 `sq_idx` 乱序写入各自项目。统一队列不能继续使用当前 Store Buffer 只有完整 payload 的简单 `push/pop` 接口。
- **已确认**：完整 Load Queue 和内存违例 replay 不作为第一版基线。Load 返回仍由 LSU/Cache 流水寄存器、单项结果保持和当前阻塞式 miss 状态保存；如果后续引入越过未知 Store 的推测执行，再重新增加 Load Queue 和恢复机制。

### 8.2 Store 生命周期和提交

- **已确认**：Store 在 Dispatch 时按程序顺序预留 Store Queue 项，并把 `sq_idx` 写入 LS IQ 与 ROB。双宽 Dispatch 按实际 Store 数量检查 0、1 或 2 个空位；两项均空时允许同周期两条 Store 分配两项，只有一项空闲时仍服从全局前缀接收。
- **已确认，Store 执行基线**：Store 仍等待地址基址和写入数据两个源都 ready 后才离开 LS IQ。LSU 一次得到地址、数据和字节掩码，并在执行完成沿写入预分配的 Store Queue 项；保留独立的 `address_ready/data_ready` 状态位，但第一版正常执行时二者同时置位。
- **已确认，ROB complete**：无异常 Store 在地址和数据都安全写入 Store Queue 后即可设置 ROB `complete`，不等待 D-Cache 或后端存储器。地址访问异常写入 ROB 异常元数据，并保证该 Store 永远不会被标成可提交写出。
- **已确认，统一队列提交**：Store 到达 ROB 提交位置时只把对应 Store Queue 项的 `committed` 置 1，不复制地址和数据到第二个写缓冲。该 Store 从此成为不可撤销的架构状态，可以离开 ROB，但仍占据 Store Queue 项。
- **已确认，释放条件**：只有选择状态指出的最老 Store 真正完成 D-Cache/后端写入后，才清除其 `valid`；若另一项仍有效，它自然成为新的最老项。已提交但未写完的项目不能被分支 flush 或异常恢复清除；两项都被占用时，新的 Store 在 Dispatch 阶段停住。
- **已确认**：D-Cache 只观察统一队列中“最老、已经提交、地址和数据完整”的 Store。直接 BRAM 平台在物理写入沿完成；需要写响应的平台保持该项直到响应返回。当前最近 Store 查询和 refill 数据合并可以继续复用，但不能再复制一份永久待写 payload。

### 8.3 Load 顺序检查和转发

- **已确认，保守执行**：Load 不越过任何地址尚未确定的旧 Store，不实现“假设未知 Store 不冲突”的地址推测，因此第一版没有 Store/Load 违例恢复。
- **已确认，旧 Store 记录**：由于统一 Store Queue 只有 2 项，每条等待中的 Load 保存 2 bit 旧 Store 掩码。Dispatch 时捕捉当时有效的旧 Store，并正确纳入同周期位于该 Load 之前的 Store；Store 真正写完释放物理项时，等待中的 Load 清除对应位，避免该位置复用后把年轻 Store 误认为旧 Store。
- **已确认，发射资格**：Load 的普通源 ready、LSU/Cache 可接收之外，其旧 Store 掩码指向的所有项目还必须 `address_ready=1`。这一条件作为 LS 候选资格进入仲裁，不等最终选中后再反悔。
- **已确认，地址检查**：Load 地址算出后，只与掩码指定的至多两个旧 Store 并行比较；无重叠时使用 D-Cache 结果。Cache 读取可以与两项比较并行启动，因为普通可缓存读取本身没有架构副作用，最终不应使用的返回值可以丢弃。
- **已确认，第一版转发范围**：若程序顺序上最新的重叠 Store 单独覆盖 Load 所需的全部字节，则直接使用该 Store Queue 数据；若只能部分覆盖，第一版不建设多 Store 与 Cache 的字节拼接网络，而是让 Load 保持等待，直到相关 Store 写出后重新读取。
- **已确认，特殊访问**：外设或其他可能因读取而产生副作用的非缓存 Load 不使用上述提前 Cache 读取，必须由后续 LSU/提交串行规则单独约束。

### 8.4 flush 和 checkpoint

- **已确认，两项直接恢复**：分支 checkpoint 不保存 Store Queue 指针。误预测时，两个 entry 分别用自身完整 `rob_tag` 与分支 owner 比较，直接清除严格年轻且 `committed=0` 的项；随后根据剩余 `valid` 状态重新得到空闲项和最老项。已经提交的最老前缀继续写出。
- **已确认**：精确异常恢复清除所有未提交 Store；已提交但仍在统一队列中等待写出的 Store 属于异常之前已经生效的架构状态，必须继续保留并最终写完。
- **已确认**：Load 的旧 Store 掩码只存在于仍等待的 LS IQ/LSU 本地状态；被恢复杀死的 Load 连同掩码一起清除，不为每条 Load 建立独立 checkpoint。

## 9. 全核控制与恢复时序

本节给出第一版乱序核的最终全核控制规则。这里的“全核控制”只负责决定当前周期是否发生恢复、采用哪一种恢复，以及各流水级在恢复和普通反压下能否前进；它不取代 ROB、IQ、LSU、MDU 各自的本地状态机。

书中 4.4、10.4.1～10.4.3 将恢复分为前端恢复和后端恢复，并指出后端只要在正确路径指令重新到达 Rename 前恢复完毕，就不必等待整个流水线排空。[BOOM Rename/ROB](https://docs.boom-core.org/en/latest/sections/rename-stage.html)使用分支快照和已提交映射表实现单周期映射恢复；[香山 CtrlBlock](https://docs.xiangshan.cc/projects/design/zh-cn/kunminghu-v3/backend/CtrlBlock/)同样集中选择重定向来源，并让 ROB 头冲刷优先于执行级重定向。当前设计采用相同的控制原则，但按 `ROB=32、IQ总计=7、SQ=2、checkpoint=2` 的规模做了明显简化。

### 9.1 控制结构：局部反压加一个小型恢复仲裁器

- **已确认**：不建设一个控制所有流水级的大状态机。普通停顿采用逐级的“有效/可接收”握手：下游不能接收时，上游只保持自己的指令和 owner，不冻结无关模块。
- **已确认**：全核只增加一个小型恢复仲裁器。它每周期最多选出一个事件，并把事件分成三类：
  1. **全部恢复**：精确异常、中断、MRET、FENCE.I 等 ROB 头架构事件，清除全部未提交状态；
  2. **年轻项恢复**：ALU0 发现分支预测错误，只清除预测 owner 之后的状态；
  3. **仅前端纠错**：Decode 发现“预测为 taken 控制流、实际不是控制流”，只清前端并跳到 owner 的 `PC+4`。
- **已确认**：后端只接收恢复种类、完整 6 bit owner ROB tag 和 checkpoint 槽号；32 bit 目标 PC 只送前端和 CSR 附近。不能把目标地址、异常宽信息和每个模块的清除向量打包成一条全核宽总线。
- **已确认**：执行和访存来源必须先把结果、owner 和一次性状态锁存在本地输出寄存器，再参加下一周期的全核恢复仲裁。不采用 `ALU比较/目标加法 -> 全核优先级 -> RAT/IQ/前端` 的同周期长组合路径。
- **已确认**：当前所有恢复状态都能在一个时钟沿更新，因此没有 `recovery_busy` 或“等待恢复完成”的多周期状态。目标 IROM 或 Cache 当时不 ready，只通过其本地握手等待，不能反过来延长 RAT/ROB 的恢复。

### 9.2 唯一的恢复优先级

优先级固定如下，前一项出现时后一项不产生任何状态修改：

| 优先级 | 事件 | 原因 |
| --- | --- | --- |
| 最高 | 复位 | 建立初始架构状态 |
| 1 | ROB 头精确异常 | 已经确定的最老同步异常不能被年轻事件越过 |
| 2 | ROB 精确边界上的已使能中断 | 在任何新的普通提交或尚未开始的串行动作之前进入中断 |
| 3 | ROB 头 MRET、FENCE.I 等串行重定向 | owner 自身完成后清除前端和更年轻状态 |
| 4 | 经 owner 验证的 ALU0 分支误预测 | 立即恢复，不等待该分支提交 |
| 5 | 本周期真正接收 owner 的 Decode 错误-CFI 纠错 | 只影响尚未进入后端的更年轻取指 |
| 最低 | 普通预测、Dispatch、Issue 和 Commit | 只在没有恢复事件时进行 |

具体规则如下：

- ROB 头若带同步异常，先处理异常；同周期到来的外部中断保持 pending，等陷阱状态允许后再次判断。RISC-V 没有规定同步异常与异步中断必须采用哪一种微架构先后顺序，本设计选择这一顺序以保留已经确定的最老异常。
- MRET、FENCE.I 等串行 owner 只有在 ROB 头、所需的旧副作用已经排空且本地操作允许开始时才形成重定向。若一个已使能中断在它开始前已经满足精确入口条件，中断先于该 owner；若 MRET 已经原子更新特权状态，则按 RISC-V 要求在其后的边界重新判断中断。
- 当前只有 ALU0 能产生真实控制流重定向，一个周期不存在两条执行级分支之间的年龄仲裁。若以后增加 Load replay 或第二条分支通路，执行级候选必须先用完整 ROB tag 选最老者，不能用固定端口号定优先级。
- 分支事件必须同时命中有效 ROB generation 和相同 checkpoint owner。被更老恢复杀死的迟到分支既不恢复、也不释放新 owner 的 checkpoint，更不能训练预测器。
- Decode 纠错只有在对应 owner 真正被前缀接收时才成立，并禁止接收同周期更年轻槽。若更老的后端恢复同时存在，本次 Decode 接收和纠错都取消，由更老事件重取。

### 9.3 三类恢复分别修改什么

| 部件 | 分支误预测：只清年轻项 | 异常/中断/串行重定向：全部恢复 | Decode 错误-CFI：仅前端 |
| --- | --- | --- | --- |
| 前端 PC、FQ、在途取指上下文 | 清空并跳到分支真实下一 PC | 清空并跳到对应架构目标 | 清空并跳到 owner 的 `PC+4` |
| RAT | 恢复 owner 的 checkpoint | 恢复为 RRAT | owner 自身照常重命名，不回滚 |
| Free List / `prf_ready` | 用 Allocation Mask 同时清除年轻 `pdst` 的占用和 ready | 两者均恢复为 `committed_busy_map` | 不额外修改 |
| RRAT | 不修改 | 不回滚；只保留恢复前已经提交的状态 | 不修改 |
| ROB | owner 保留，tail 截到 owner 之后 | 清除全部未提交 entry | owner 正常进入 ROB |
| 三个 IQ 和执行流水 | 保留严格更老者，清除严格年轻者 | 全部清除 | 不清后端 |
| 两项 Store Queue | 清除年轻且未提交的 Store | 清除全部未提交 Store | 不修改 |
| 已提交但尚未写完的 Store | 保留并继续向 Cache/内存写出 | 同样保留并继续写出 | 不修改 |
| PRF 数据阵列 | 不清空 | 不清空 | 不修改 |

ROB 的恢复只清 `valid/complete/exception/resolved_next_pc_valid` 等小状态并更新 tail/count，不清 32 项 PC、指令字和提交元数据阵列。IQ、SQ、FU 入口和结果保持项各自在本地用完整 owner tag 判断是否年轻。书中所警告的是同时广播很多分支编号并让每项做多组比较；当前只广播一个 6 bit 恢复 owner，且后端总共只有 7 项 IQ 和 2 项 SQ，不需要 branch mask 或多周期 WALK。

精确异常和中断都属于“全部恢复”，但 owner 是否退休不同：

- 同步异常的 owner 不退休，`mepc` 保存它的 PC；
- 中断发生在两条架构指令之间，不退休新的 ROB head；
- MRET、FENCE.I 这类“执行后重定向”的串行 owner 自身完成其架构动作并退休，只清它后面的状态。若以后有带 `rd` 的“退休并重定向”指令，RAT 应恢复到包含 owner 提交结果的 `RRAT_next`，不能恢复到周期初的 RRAT。

### 9.4 中断的精确入口

- **已确认**：外部中断先在 CSR/中断模块同步并形成 pending 状态，原始异步引脚不能直接驱动全核 flush。
- **已确认**：不为中断等待整个 ROB 排空，也不在中断一出现时无条件异步清流水线。ROB 在一个安全的提交边界接受中断，保存下一条尚未提交指令的 PC，然后按 RRAT 和 `committed_busy_map` 一拍清除全部未提交状态。这兼顾了精确性和响应时间。
- **已确认**：若 ROB 非空，中断的 `mepc` 直接取当前 head 的 PC；若 ROB 为空，则取一个新增的 32 bit `architectural_next_pc`。该寄存器表示“所有已提交指令之后的真实下一 PC”，复位时为复位地址，提交普通指令时更新为 `PC+4`，提交真实控制流时使用 ROB 的 `resolved_next_pc`；双提交时以最后一条真正提交的指令为准。进入异常、MRET 或其他全恢复目标后，它更新为对应重定向目标。
- **已确认**：中断入口周期不做普通双提交。这样 `mepc`、RRAT、Free List 和 ROB head 具有唯一、明确的边界，不需要猜测中断究竟落在同周期两条提交之间的哪个位置。
- **已确认**：可能产生不可撤销外部副作用的非缓存/MMIO 访问只能在 ROB 头执行；一旦其外部事务已经接受，本周期暂时不是中断安全边界，先完成该原子事务再判断中断。普通推测 Load 没有架构副作用；Store 只有提交后才允许向外写。
- **已确认**：已经提交并进入统一 Store Queue 写出阶段的 Store 属于架构状态，中断和异常不能取消它。中断处理程序的 Load 仍需查询这两项 Store Queue，保证能看到尚未落入 Cache 的已提交旧 Store。

[RISC-V Privileged ISA](https://docs.riscv.org/reference/isa/priv/machine.html)要求中断条件在有界时间内被重新判断，并规定陷阱时 `mepc` 保存被中断或发生异常的指令地址；上述 ROB 边界和 `architectural_next_pc` 正是这两个要求在当前乱序核中的实现。

### 9.5 普通反压、串行指令和恢复的关系

- **已确认**：FQ、Rename/Dispatch、三个 IQ、PRF 读取级、FU 输入/输出保持项、Cache 请求和写回寄存器分别维护本地 valid。下游不收时，只保持对应通路的 valid 和 payload；例如 DIV 忙只阻塞 MDU，Load miss 只阻塞 LSU 的新访存，某个 PRF bank 写冲突只反压请求该 bank 的结果源。
- **已确认**：恢复具有高于普通握手的优先级。恢复有效的周期不进行新的 Rename/Dispatch、IQ 到 PRF 读取级交接、bank 写回授权/唤醒或普通 ROB commit；被恢复杀死的 valid 在时钟沿清零，不能因为下游同时 ready 而误传。
- **已确认**：分支恢复周期已经在 `bank_wb_reg` 中排定的物理写仍可完成；严格更老 owner 的完成可以保留，年轻 owner 的 ready/complete 被恢复覆盖。除此之外，当周期新到达的 FU 结果必须保持到下一周期重新申请 bank。
- **已确认**：已提交 Store 的外部写握手是恢复暂停的例外，它继续前进；恢复只取消未提交 Store。分支之前已经发出的老 Load miss 和老 DIV 也继续执行，不能被一根无差别的全局 flush 误杀。
- **已确认**：CSR、MRET、FENCE、FENCE.I 使用 5.7 节所述单项串行槽。串行 owner 接收后，后续更年轻指令留在 FQ，不再进入 ROB/IQ，直到 owner 完成或被更老恢复清除。较老乱序指令仍可继续执行和提交，因此这不是“全核停止”。
- **已确认，双宽边界**：若串行 owner 或 Decode 已知必然陷阱的非法指令、ECALL、EBREAK 位于输入槽 0，本周期只接收槽 0；它位于槽 1 时可以先接收更老的槽 0，再接收 owner。owner 接收后统一阻止新的年轻 Dispatch；若 owner 被更老分支恢复清除，阻塞同步解除。
- **已确认**：FENCE 在 ROB 头等待所有要求排序的旧访存和已提交 Store 写出满足后退休；FENCE.I 在此基础上清空前端并从 `PC+4` 重取，若以后加入 I-Cache 还要同时使其内容失效。[RISC-V Zifencei](https://docs.riscv.org/reference/isa/unpriv/zifencei.html)允许简单实现通过清取指流水/I-Cache 来保证后续取指观察到之前的 Store。
- **第一版基线**：WFI 可以按 RISC-V 允许的方式实现为不真正停钟的 NOP；若以后增加低功耗等待状态，再单独增加本地 sleep 状态，不改变本节恢复优先级。
- **已确认**：继续保持已决定的“资源下一周期复用”规则：当周期 commit 的 ROB/PRF、发射的 IQ entry、释放的 checkpoint 和写完的 SQ entry 都不向本周期 Rename 提供组合空位。这切断 `执行/提交 -> 资源释放 -> Rename -> 全核反压` 的组合环。

### 9.6 错误路径的迟到结果

- **已确认**：每个已经离开 IQ 的在途操作都保留完整 ROB tag，所有完成、异常、写回和控制事件在修改状态前再次验证 owner。恢复只是让 owner 失效；数据阵列本身无需清零。
- **已确认**：分支恢复时，严格更老的 Load miss、DIV 和 FU 保持项继续运行；严格年轻者在本地取消。迭代 DIV 应提供 owner kill 后清 busy 的通路，避免一条已被清除的 32 周期除法继续占住 MDU。
- **已确认**：年轻 Load 已被存储后端接受时，能取消的本地 BRAM 请求立即取消；AXI 等不可取消请求进入 drain/drop 状态，返回数据只负责结束旧事务，不产生 PRF 写回、唤醒、ROB complete 或异常。选择性分支恢复不能把仍然存活的老 Load miss送入 drop。
- **已确认**：6 bit ROB tag 足以比较当前 32 项窗口的年龄，但它不是可以无限期复用的外部事务编号。任何可能晚于 ROB 多次绕回才返回的接口，必须一直保留“这是一个已取消旧事务”的本地状态直到返回排空，或显式携带更宽 transaction ID；不能在很久以后收到返回时仅重新比较 1 bit generation。
- **已确认，取指接口约束**：固定一拍 IROM 可用当前 epoch 丢掉 redirect 前的一拍返回。可变延迟 IROM 的返回包没有请求编号，因此必须保证最多一个请求在途，并且后端在旧响应排空前保持 `irom_req_ready=0`；redirect 后旧响应先被丢弃，正确 PC 请求随后才会被接受。当前 `irom_backend_adapter` 的 `IDLE -> READ -> RESP` 状态满足该约束。若将来允许多个取指请求在途，响应必须回传 epoch/transaction ID，仅扩大当前 2 bit 本地 epoch 不能解决错误配对。
- **已确认**：误预测 owner 自己的预测器训练和 Decode 纠错自己的 ABTB 失效可以随对应恢复保留；若同周期存在更老的 ROB 头恢复，使 owner 本身失效，则这些更新也取消。

### 9.7 恢复后哪一拍重新工作

执行级重定向先经过本地结果寄存器，下一周期完成全核选择。设 `edge x` 是真正更新 RAT、ROB、IQ 和前端 PC 的恢复时钟沿，则固定时序如下：

```text
edge x:
  原子完成 RAT/Free List/ROB/checkpoint 恢复；
  清除对应的前端、IQ、SQ 和执行 valid；
  前端 PC 锁存正确目标。

cycle x:
  前端立即用正确目标产生新的取指请求；
  分支之前仍存活的 IQ 指令立即重新参加仲裁；
  不再等待额外的 recovery_done。

edge x+1:
  存活且获选的老指令进入 PRF 读取级；
  固定一拍 IROM 接受正确目标请求并锁存其上下文。

cycle x+1:
  PRF 组合读取老指令操作数；
  IROM 返回数据进行预译码和 FQ 入队准备。

edge x+2:
  老指令操作数进入 FU；
  正确路径取指包进入 FQ。

cycle x+2:
  老指令执行；
  FQ 头向现有 IF/ID 边界送出正确路径指令。

edge x+3:
  正确路径指令进入 Decode 输入寄存器。

cycle x+3:
  完成 Decode、Rename 和资源检查。

edge x+4:
  最早的正确路径指令进入 ROB/IQ，并从这一周期开始参加后续仲裁。
```

上述是固定一拍 IROM、保留现有 FQ 到 Decode 寄存边界时的最早时间。可变延迟 IROM 只会在“正确目标请求被后端接受/返回”处增加等待，不会让后端恢复重新进入等待状态。第一版不建设 ALU0 结果直接组合驱动 IROM 地址的同周期旁路；少一拍误预测惩罚不值得换取一条跨 ALU、恢复仲裁和前端的长布线路径。

### 9.8 FPGA 物理实现和必须断言

- **已确认**：全核恢复只清 valid、位图、指针和小型映射状态，不给 ROB/IQ/流水寄存器的宽 payload 接同步 reset/flush 多路器。[AMD UG949](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Resets)指出高扇出复位会显著影响频率、面积和功耗；payload 在 valid=0 后保留旧比特不影响正确性。
- **已确认**：中央只产生一个已经寄存来源的恢复决定，各模块在本地并行计算 kill。若恢复 valid 扇出成为实现问题，允许综合和物理优化复制该驱动寄存器并按模块分组放置；不能为了复制而增加不同模块可见恢复的时钟差。[AMD UG949 的高扇出建议](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Replicate-High-Fanout-Net-Drivers)也优先采用受控的寄存器复制和局部负载分组。
- **已确认**：前端 target 寄存器放在前端附近；RAT/checkpoint/Free List 的恢复选择放在 Rename 附近；IQ、SQ、MDU、LSU 只接收窄 owner 信息。恢复总线不穿过 PRF 数据阵列。

RTL 至少设置以下断言：

- 一个周期最多一个恢复 winner，且高优先级事件出现时低优先级事件不得产生状态修改；
- 分支恢复 owner 必须同时命中有效 ROB generation 和 checkpoint owner；
- `resolved_next_pc_valid` 只能属于有效的真实控制流 owner，提交读取地址必须选择本周期最后一条真正提交的控制流；
- 恢复周期不得产生新 Dispatch、Issue 交接、bank grant/唤醒或普通 commit；
- 分支恢复沿之后，不得残留任何严格年轻的 IQ、SQ、FU、Load 或 MDU valid，严格更老者必须保持；
- 全部恢复后，不得残留未提交 ROB/IQ/FU 状态，已提交 Store Queue 项必须仍然存在；
- 任何迟到响应若 owner 已失效，不得写 PRF ready、ROB complete、异常或恢复状态；
- 可变延迟 IROM 在旧响应未排空时不得接受新请求；若以后改成多在途，必须验证返回 ID；
- 每次恢复只产生一个前端 redirect 脉冲，恢复后的第一次有效请求地址必须等于选中的目标；
- `architectural_next_pc` 在 ROB 为空时必须等于下一条应执行的架构 PC。

**本节已经收口。** 后续 RTL 综合可能要求复制寄存器、调整局部摆放或在可变延迟接口中增加保持项，但不能在没有重新修改本文档的情况下改变恢复优先级、精确边界、恢复后立即取指/发射或局部反压原则。至此“全核控制”不再列为待讨论模块。

## 10. 软件模型的边界

已经删除的阶段性 checkpoint C 模型曾采用以下配置：

```text
ROB=32
PRF=64
INT_IQ=16
MEM_IQ=8
rename=2
commit=2
simple_issue=2
MDU=1
LSU=1
regread=1
ALU=1
BR=1
MUL=3
DIV=32
Load hit/miss=2/10
Store=1
early_wakeup=on
```

这些是比较 checkpoint 数量时使用过的建模假设，不代表所有硬件参数已经确认。该模型采用正确路径/完美预测假设，只用于观察 checkpoint 资源压力；其源码和可执行文件已经删除。后续评估 bank 冲突、写回排队和 RAW 延迟时，应扩展当前 `cpp_arch_explorer` 后端模型以覆盖真实唤醒/写入时隙，不能复活这份旧模型。

新的后端/IQ 深度探索器已经放在 `02_Design/model/cpp_arch_explorer`。可执行程序为 `backend_iq_study`，单元测试为 `backend_model_tests`；它与同目录既有前端模型共用 RV32 功能执行器，但使用独立的后端周期模型和输出文件。其目的不是替代 RTL，而是比较 IQ 深度的边际性能收益。

当前后端模型已经保持下列已确认硬件行为：

- 双宽、按程序顺序的前缀 Rename/Dispatch；目标 IQ 满时即使其他 IQ 有空位也可能阻塞前端；
- 三个非压缩 IQ、ROB=32、PRF=64、两个物理寄存器 bank 和每 bank 每周期最多一次新 `pdst` 分配；
- INT 最多两个、LS/MDU 各一个局部候选，全局最多发射两条，并检查每个 PRF bank 最多两个有效源读取；
- source tag/ready、实际完成后的 bank 写入授权唤醒、每 bank 一个写口、FU 单项结果保持和同 bank 冲突反压；
- ALU/Branch、MUL、DIV、Load hit/miss、Store 的延迟和各 FU 的 initiation interval 分开建模；命中 LSU 默认每周期可接收一条，单个 Load miss 阻塞后续访存；
- ROB 按序双提交、Free List 在提交时释放 `old_pdst`、长延迟 ROB 头和资源满造成的反压；
- 当前 D-Cache 的 `2-way x 64-set x 16-byte`、write-through/write-no-allocate 和两项 Store Buffer 基础结构，以及保守的第一版内存顺序假设；
- 两个分支 checkpoint、每周期最多创建一个，以及可配置的正确路径/方向预测屏障敏感性。
- GShare 预测在动态指令流进入各后端配置前按程序序生成，默认使用 6 条动态指令的更新延迟；相同程序的误预测次数不得随 IQ 深度改变，IQ 只影响误预测分支的解析时刻和屏障长度。

模型输出不能只有 IPC，还应包括三个 IQ 的平均/峰值/分位占用、各 IQ 满周期、因目标 IQ 满造成的 Rename 阻塞、PRF 读 bank 冲突、全局 issue width 限制、FU busy、写回结果保持、ROB/PRF/checkpoint 资源阻塞、Load hit/miss、miss 阻塞、Store Buffer 满和 LSU 最大在途数量。软件扫描只选择性能候选，最终深度仍由候选配置的 FPGA 综合时序、布线和资源共同决定。

当前模型沿功能模拟器提供的正确路径运行。GShare 方向误判会阻塞正确路径直到分支解析并计入重定向延迟，但不生成错误路径的 ROB/IQ/PRF 占用；LS 采用保守的最老访存发射，尚未实现完整 LSQ 地址推测、Store-to-Load forwarding 和 replay。因此它适合比较队列过小、容量饱和点、PRF bank 与写回冲突，不适合单独给出最终 CPI。构建和结果默认放在 `/tmp`，正式扫描命令与字段说明见同目录 `README.md`。

2026-07-22 的首轮六程序数据曾把 LSU 建模成“上一条访存完成前不能接收下一条”。该轮可以保留 MDU 深度 2 没有性能损失、INT=16/20 边际收益很小等观察，但不能用来决定 LS IQ 深度。当前模型已将 Load 响应延迟与命中接收间隔拆开，并把 INT=4/6 加入扫描；旧的 `/tmp/backend_iq_round1` 结果不再作为第二轮容量结论。

**模型对齐提醒**：本节模型早于本文档的最终硬件规则，当前 `backend_model.cpp` 至少存在以下差异：

- 仍使用通用的全局候选配对，只取最老 LS 候选，并允许 MDU 与其他队列共同占用两个发射位置；尚未实现“MDU 独占、2 个 LS entry 与 4 个 INT entry 全部检查、`LS + INT` 与 `INT + INT` 两套方案并行选择”；
- 同一条指令的两个相同 `psrc` 仍按两次 PRF 读取计数，没有实现 `src1_reuse_src0`；
- checkpoint 只覆盖条件分支和 `JALR`，遗漏当前硬件规则要求的直接 `JAL`；模型也不产生“预测 taken、译码后实际非 CFI”的 Decode 前端纠错事件；
- GShare 在动态 trace 上按固定指令延迟预先生成结果，不是由模型中的 ROB commit 按程序顺序更新 GHR；
- 模型只沿正确路径运行，因此没有真正执行 Allocation Mask 回收、选择性 flush、恢复沿旧写回和迟到 LSU/MDU 结果取消。

已有深度扫描仍可作为队列容量的阶段性参考，但再次用模型比较最终发射策略、checkpoint 压力或精确 RAW 延迟前，必须先对齐上述行为。

## 11. 仍需单独展开的后续模块

本轮已经收口映射表物理载体与复位、PRF 读回、重复源、Free List/checkpoint next-state、checkpoint owner 范围、GHR 提交更新、ROB 容量/字段分层/物理 bank、完成位与最老异常记录、双提交前缀、异常时寄存器状态恢复、ALU0 控制/数据分离、写回/flush next-state 和第一版结果保持深度。剩余内容不是这些电路里的小开关，适合按完整模块继续讨论：

1. LSU/Cache 细节：统一两项 Store Queue 与现有 D-Cache 的提交、写响应和 refill 握手，Load 部分覆盖时的本地保持，以及阻塞式 miss 下的精确反压；
2. ROB/Commit 剩余外围：统一 Store Queue 的提交数量握手，以及 CSR 数据通路和各串行指令的具体完成条件；中断精确入口和全核恢复规则已经由第 9 节确定；
3. 执行单元细节：ALU0 分支接口、现有 MDU 接入乱序 owner/kill、LSU 返回握手和各级精确延迟；
4. 把 5.5 节最终发射策略、两项 checkpoint、本轮写回规则和第 9 节固定恢复罚时同步到软件模型，再进行完整后端 FPGA 综合、floorplan 和参数联合校准。
