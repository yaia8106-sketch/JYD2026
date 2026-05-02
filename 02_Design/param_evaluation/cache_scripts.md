# Cache 参数评估脚本

> 所有脚本精确匹配 `dcache.sv` 的行为：
> Write-Through + Write-Allocate, 1-entry Store Buffer, LRU 替换。

---

## cache_sim.py

**用途**：模拟 DCache 命中率，评估不同配置的性能收益。

**方法**：
1. ISA 级模拟收集所有 DRAM Load/Store 地址
2. 对多种 Cache 配置模拟命中/缺失
3. 估算 250MHz + DCache vs 200MHz 无 Cache 的性能对比

**内置配置**：
- 容量: 1KB / 2KB / 4KB
- 关联度: 直接映射 / 2-way / 4-way
- 行大小: 16B / 32B

**输出**：每程序的访存特征（唯一 word 数、地址范围）+ 各配置命中率 + 加速比估算。

```bash
python3 cache_sim.py
```

---

## cache_sweep.py

**用途**：大规模并行扫描 DCache 配置空间。

**方法**：
1. 先收集 4 程序的访存 trace
2. 对 864 种配置组合并行回放（`multiprocessing.Pool`）
3. 按平均命中率排序

**扫描维度**：

| 参数 | 取值 |
|------|------|
| 容量 | 512B, 1KB, 2KB, 4KB, 8KB, 16KB |
| 关联度 | 1, 2, 4, 8 way |
| 行大小 | 8B, 16B, 32B, 64B |
| 写策略 | Write-Through, Write-Back |
| Store Buffer | 0, 1, 2, 4 entry |

**输出**：Top N 配置，含四程序各自命中率和 BRAM 开销估算。

```bash
python3 cache_sweep.py
```

**关键发现**（已归档到 `full/cache_analysis.md`）：
- 2KB 和 4KB 使用相同的 2 个 BRAM18（零 BRAM 成本升级）
- 组相联对测试程序收益极小，2-way 足够
- 全局瓶颈是 DCache→DRAM 纯布线（0 级逻辑），与 Cache 容量无关
