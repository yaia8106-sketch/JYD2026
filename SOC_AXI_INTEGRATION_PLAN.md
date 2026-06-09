# SoC AXI Integration Plan

## 1. Current State

当前工程不是“板级主线已经用 AXI 连接 BRAM”的状态。

现在实际分成两条路径：

- `student_top`
  - 当前板级主线仍然使用它。
  - DCache 后端仍然走 `dcache_bram_backend`。
  - 外部存储仍然是原来的 BRAM/IP 方案。

- `student_top_axi`
  - 这是处理器侧 AXI 版本。
  - DCache 后端走 `dcache_axi_backend -> axi_master_adapter`。
  - 它已经能暴露 AXI master 接口，但当前板级主线没有切到它。

所以当前工程更准确的描述是：

```text
主线板级工程: top -> student_top -> BRAM backend
备用 AXI 路径: student_top_axi -> AXI master signals
```

## 2. Overall Goal

最终目标是搭一个完整 SoC：

```text
CPU
  |
AXI interconnect / SmartConnect
  |---------------- DDR/MIG
  |---------------- DMA
  |---------------- Accelerator
  |---------------- HDMI / frame buffer path
  |---------------- AXI-Lite MMIO peripherals, if needed
```

BRAM 和 DDR 可以共存：

- BRAM：适合 IROM、boot code、小容量低延迟数据、调试用 scratch area。
- DDR：适合大容量数据，例如图像、权重、feature map、frame buffer。

## 3. What To Add Next

下一步不应该直接乱接 IP，也不应该先生成一堆 Vivado 脚本。

下一步应该先加一个明确的 SoC 集成边界：

```text
CPU core / student_top_axi
        |
        v
SoC memory and MMIO boundary
        |
        v
AXI fabric / external memory path
```

也就是说，下一步要补的是：

1. 地址规划
2. cacheable / non-cacheable 区域划分
3. `student_top` 和 `student_top_axi` 的切换策略
4. AXI interconnect 接入点
5. DDR、DMA、加速器、HDMI 的总线角色

## 4. Proposed Phases

### Phase 0: Clean Current State

目标：确认当前工程只有一条清晰主线。

- 保留 `student_top` 作为 BRAM 基线。
- 保留 `student_top_axi` 作为 AXI 处理器端入口。
- 不切换 Vivado board top。
- 不新增 Vivado 脚本目录。
- 不新增未说明用途的目录。

### Phase 1: Define Address Map

先写清楚地址，而不是先写 RTL。

建议第一版：

```text
0x8000_0000 - 0x8FFF_FFFF   Cacheable memory
0x9000_0000 - 0x9FFF_FFFF   Non-cacheable DMA / accelerator buffers
0xA000_0000 - 0xA0FF_FFFF   AXI-Lite MMIO peripherals
0x8020_0000 - 0x8020_FFFF   Existing local MMIO, if kept local
```

这里需要决定：

- LED、数码管、timer、CSR 是否继续直连本地 MMIO。
- DMA、accelerator、HDMI 是否走 AXI-Lite 控制寄存器。
- DDR 哪些区域 cacheable，哪些区域 non-cacheable。

### Phase 2: CPU AXI Path In Simulation

目标：先确认 `student_top_axi` 的 AXI master 行为稳定。

已有基础：

- `axi_master_adapter.sv`
- `dcache_axi_backend.sv`
- `student_top_axi.sv`
- `tb_student_top_axi.sv`
- `axi_ram_model.sv`

下一步应该补：

- 更明确的 AXI transaction trace。
- cacheable load/store 的地址覆盖。
- MMIO 请求不进入 AXI 的断言。
- read/write response 错误处理策略。

### Phase 3: Decide First Real AXI Slave

第一颗真实 AXI slave 有两个选择：

1. AXI BRAM Controller
   - 好处：简单，适合验证 AXI 接线。
   - 坏处：不是最终大容量存储方案。

2. MIG / DDR
   - 好处：更接近最终 SoC。
   - 坏处：IP、时钟、calib、约束和调试复杂度高。

建议：

```text
先用 AXI BRAM 验证总线接线，再接 MIG/DDR。
```

但实现时必须先写清楚：

- 要改哪个 top。
- 是否保留原 `student_top`。
- AXI BRAM 只是 bring-up 组件，不是最终系统主存。

### Phase 4: Add Interconnect

当 CPU 之外还要挂 DMA 或 accelerator 时，才需要正式加 interconnect。

典型结构：

```text
CPU AXI master ----\
                   AXI interconnect ---- DDR/MIG
DMA AXI master ----/          |
                              +---- AXI-Lite peripherals
                              +---- Accelerator control/status
```

这个阶段需要解决：

- master arbitration
- address decode
- response routing
- outstanding depth
- clock domain crossing

### Phase 5: Add DMA And Accelerator

DMA 的角色：

- 从 DDR 读输入图像、权重或 feature map。
- 把数据搬到 accelerator。
- 把 accelerator 输出写回 DDR。

Accelerator 的角色：

- 接收输入数据。
- 执行神经网络相关计算。
- 输出结果或中间 feature map。

CPU 的角色：

- 配置 DMA。
- 配置 accelerator。
- 管理 buffer 地址。
- 处理中断或轮询完成状态。

### Phase 6: Add HDMI Path

HDMI 通常读取 frame buffer。

```text
DDR frame buffer -> HDMI display controller -> HDMI output
```

如果 accelerator 的输出要显示：

```text
Accelerator output buffer -> CPU/DMA format conversion -> frame buffer -> HDMI
```

## 5. What Not To Do Now

当前不要做这些事：

- 不要随手创建新的脚本目录。
- 不要把 Tcl 脚本当作主要交付内容。
- 不要在没确认地址规划前切换 board top。
- 不要直接把 DDR、DMA、accelerator、HDMI 一次性全接上。
- 不要删除 `student_top` 的 BRAM 基线。

## 6. Immediate Next Step

下一步建议只做一件事：

```text
写清楚 SoC 地址映射和外设归属。
```

然后再决定第一笔 RTL 改动。

第一笔 RTL 改动建议是：

```text
给 student_top_axi 增加更完整的仿真检查，确认：
1. 普通 memory 请求会进入 AXI。
2. LED/SEG/timer 这类本地 MMIO 不会进入 AXI。
3. AXI read/write response 能正确回传给 DCache。
```

这样做的好处是：先把处理器端边界验证清楚，再接真实 IP。

