# NSCSCC RTL 性能归因

这里的工具用当前 `core/nscscc` RTL 跑赛方 20 个 performance 程序，并统计
提交、流水线空泡、分支预测、I/D Cache、AXI outstanding 和写回/读回重叠等事件。
监控器只由运行脚本额外传给 Verilator，不在 `platform/nscscc/filelist.f` 中，因此
不会进入综合、实现或比赛提交的硬件。

零提交归因不是在 WB 空泡出现时猜测当前哪个模块正忙。监控器会在 IF/ID、ID/EX、
EX/MEM 或 MEM/WB 首次产生空泡时记录原因，再按 RTL 本身的 `valid/allowin/flush`
规则让原因标签随空泡前进。报告因此能区分 ICache refill 与正常取指响应、各类 RAW、
MulDiv 数据/结构冲突、串行化、EX 等待、DCache 查询/refill/脏写回、非缓存访问和异常；
所有因果桶必须与 `zero_commit_cycles` 严格守恒，否则运行器会直接报错。

顶层报告进一步以“双发射宽度 × 计时周期”为全部槽位，把 Slot 0 和 Slot 1 分别沿
流水线追踪，互斥归入 Retiring、Bad Speculation、Frontend Bound 和 Backend Bound。
它不仅覆盖零提交周期，也覆盖单提交周期缺失的第二个槽位；四类必须与全部槽位严格
守恒，Retiring 还必须与提交指令数一致，任何未分类槽位都会使运行失败。
第二层在相同槽位上继续互斥拆分：Bad Speculation 分成分支错误恢复与机器清空，
Frontend Bound 分成取指延迟与取指带宽，Backend Bound 分成 Core Bound 与 Memory
Bound。每组子类必须分别与自己的第一层父类严格相等。
第三层只继续拆 Core Bound：Load/repair 数据依赖、同组 RAW（且 RAW 是唯一阻塞
条件）、配对策略/指令类型限制、MulDiv、串行化以及其他核心执行阻塞。第三层同样
要求子类之和严格等于 Core Bound，且未分类必须为零。将“RAW 唯一阻塞”单列可避免
把仍受 `force_single` 或不支持指令组合限制的槽位误认为增加前递就能恢复双发。

第四、五层用于把值得做 RTL A/B 的方向继续缩窄：前端延迟会拆成 ICache refill、
取指查询/响应等待和前端无排队请求；前端带宽会拆成预测跳转、没有第二条指令和地址
不连续，并继续判断跳转目标是否已经在 FQ 中且本来可以配对。Load RAW 会按生产者在
EX、MEM-ready、MEM-wait 或多个阶段同时命中分类；同组 RAW 会按 ALU/LSU/MulDiv/CFI
生产者和消费者类型分类；配对限制则区分 `force_single`、双 LSU、双 CFI 和不支持的
槽位类型。每组仍做严格父子守恒检查，避免把重叠事件重复累计成虚假的收益。

ICache 还带有一个仿真专用 3C 影子模型。当前 8 KiB direct-mapped Cache 与一个
同容量、512 项全相连 LRU 模型接收相同的 16 B line 访问序列，据此把真实 miss
分成 Compulsory、Conflict 和 Capacity。分类状态从复位后预热，正式计数只覆盖
RDCNTVL 窗口；类别还会随真实 ICache refill 空泡传播到 WB，用实际损失槽位而非
简单的 miss 数量比例估算“理想消除冲突”的同频直接收益。被 redirect 取消的 miss、
真正发上 AXI 的 refill 和最终造成的前端空泡会分别报告。

监控器还包含一个不改变 RTL 的 DCache 提前查询影子模型，用于回答“在 ID 计算
Load 地址、让 BRAM 数据提前到 EX”是否值得实现。它同时统计两种策略：保守策略
拒绝任何来自当前 EX 的基址，激进策略允许普通 EX ALU 前递；两者都拒绝下一拍才
存在的 load-repair 基址，并按单读口的内部读、EX 回退、ID 查询优先级仲裁。最终
收益只在真实 DCache hit 后确认，同时扣除首版采用 stall/re-read 时的 Store→Load
同 word 冲突。报告会列出地址覆盖率、端口 grant、可修复消费者类型和每个程序的
事件模型收益；这个数字用于决定是否动微架构，不能代替实现后的 RTL A/B。

## 快速使用

在本目录运行：

```bash
# 最快的功能与计数冒烟检查
./run_rtl_perf_profile.py --benchmark bitcount --delay-mode none

# 推荐的完整 RTL A/B 测试（固定随机种子，20 个程序）
./run_rtl_perf_profile.py --delay-mode random

# 例如：8 个程序并行，每个 Verilated 模型内部使用 2 个线程
./run_rtl_perf_profile.py --delay-mode random --jobs 8 --model-threads 2

# RTL 或构建选项变化后强制重编译
./run_rtl_perf_profile.py --delay-mode random --force-rebuild

# 用现有基线和 RTL A/B 结果筛选能否达到 5%（可重复指定 --variant）
./analyze_5pct_directions.py \
  --variant candidate=/path/to/candidate-results \
  --repair-variant candidate
```

默认最多并行运行 4 个程序。`--jobs N` 控制同时运行的 benchmark 数量，
`--model-threads N` 控制每个 Verilated SoC 模型内部的线程数，两者互相独立。
单模型默认 1 线程，是因为当前小型 SoC 实测中跨线程同步开销更大，并非功能限制；
可以按机器情况把它设成 2 或更多。还可以多次指定 `--benchmark` 只跑若干程序。
实际 CPU 并行度大致按 `--jobs × --model-threads` 增长，内存则主要随
`--jobs` 增长。
脚本按 RTL、仿真环境、监控器和模型线程数生成构建指纹；输入未变化时会复用同一个
Verilator 可执行文件，不会为每个程序重新编译。

`analyze_5pct_directions.py` 同时给出三种口径：完整 RTL A/B 的总周期与逐程序几何
平均加速、提前 DCache 影子模型，以及由损失槽位推导的乐观上界。默认门槛是 5%，
并要求 RTL A/B 的 20 个程序全部通过。乐观上界低于门槛的方向可以直接淘汰；高于
门槛只表示“事件数量足够”，不能代替功能正确、时序可收敛的真实 RTL 实验。

结果默认写入 `/tmp/nscscc-rtl-perf-results`：

- `rtl_perf_profile.csv`：每个程序的原始计数和派生比率；
- `aggregate.json`：所有已选程序的聚合计数；
- `report.md`：便于阅读的性能归因摘要；
- `manifest.json`：RTL/程序哈希、Git 状态、延迟模式和构建指纹；
- `logs/`：每个程序的完整仿真输出。

## 数据边界

`--delay-mode random` 使用 Chiplab 自带的确定性 AXI 随机延迟注入器，适合快速
比较两版 RTL 和判断空泡主要来自哪里，但它不是 MIG + DDR3 的精确周期模型。
`--delay-mode none` 更快，只适合检查功能、事件计数和无等待存储体下的上限。
最终总周期应以线上 CI 或板上计数为准；比较两版结果时需保持同一延迟模式、
随机种子和程序哈希。

脚本检查每个 perf 程序自己的结果、最终 LED PASS 状态以及 RTL 仿真断言，并
关闭波形、逐指令文本 trace 和软件重编译；赛方的综合/实现 Tcl、布局布线策略
以及 PLL 配置均不参与也不会被修改。

随 Chiplab 提供的本地 NEMU 不支持 perf 启动代码中的 `CPUCFG`，其 uncached
store 地址比较也与当前 core 的 difftest 接口不兼容，所以这个快速归因脚本不
启用 NEMU。它不会修改原始 `inst_data.bin`；严格指令级正确性仍应由官方 func
验证覆盖，而这里的 20 个 perf PASS 用来守住实际性能工作负载的最终结果。

赛方 perf 在计时前后会经 16550 打印，而当前 Verilator 外设模型的发送就绪位
不会拉高。运行器仅在临时 `ram.dat` 中把 `UART_BASE` 数据初值指向一块仿真
scratch RAM，并令该位置的 LSR 字节为 THRE=1；指令和原始 bin 不变，格式化
代码仍照常执行。监控器同时检查正式计时窗口：如果窗口内真的
调用 `uart_putchar`，本次运行立即作废。补丁地址和机器码记录在 manifest 中。
