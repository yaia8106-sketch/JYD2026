# COE 文件目录

本目录存放 Vivado Block Memory Generator 使用的初始化文件（`.coe`）。

---

## 目录结构

```
coe/
├── current/          ← 当前使用的 COE（数字孪生平台调试用）
│   ├── irom.coe      1273 行指令，hex 格式
│   └── dram.coe      12 个 word 初始数据
│
├── src0/             ← 用途不明，比赛方或早期测试提供
│   ├── irom.coe      2037 行指令
│   └── dram.coe      12 个 word 初始数据
│
├── src1/             ← 用途不明
│   ├── irom.coe      1911 行指令
│   └── dram.coe      12 个 word 初始数据
│
└── src2/             ← 用途不明
    ├── irom.coe      1998 行指令
    └── dram.coe      12 个 word 初始数据
```

## 使用说明

- **调试和仿真时默认使用 `current/` 下的文件**
- `src0/`、`src1/`、`src2/` 来源不明（可能是比赛方提供的不同测试程序），暂不使用
- 所有 COE 文件格式均为 `memory_initialization_radix=16`（十六进制）

## COE 格式参考

```
memory_initialization_radix=16;
memory_initialization_vector=
00108117,
03010113,
...
00008067;     ← 最后一行以分号结尾
```

在 Vivado Block Memory Generator 中使用：
- IROM IP → Other Options → Load Init File → 选择 `irom.coe`
- DRAM IP → Other Options → Load Init File → 选择 `dram.coe`
