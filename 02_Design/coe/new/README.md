# 比赛 COE 放置目录

将比赛提供的两个 32-bit COE 文件放在本目录，文件名使用以下任一种形式：

- `IROM` 或 `IROM.coe`
- `DRAM` 或 `DRAM.coe`

然后在终端执行：

```bash
new
```

转换结果会写入 `../irom64/new/irom64.coe` 和
`../irom64/new/dram.coe`。原始比赛文件不会被修改。
