#!/usr/bin/env python3
"""
COE → 反汇编脚本
将 Vivado BRAM COE 文件中的 hex 指令转为 RISC-V 反汇编。

用法:
    python3 disasm_coe.py                  # 反汇编所有子目录
    python3 disasm_coe.py src0             # 只反汇编 src0
    python3 disasm_coe.py src0 src1        # 反汇编 src0 和 src1

输出: 每个目录下生成 irom_disasm.txt
"""

import sys
import os
import struct
import subprocess
import tempfile
from pathlib import Path

# RISC-V objdump 路径（按优先级查找）
OBJDUMP_CANDIDATES = [
    "riscv64-unknown-elf-objdump",
    "riscv32-unknown-elf-objdump",
    "riscv-none-elf-objdump",
]

# IROM 基地址
TEXT_BASE = 0x80000000


def find_objdump():
    """查找系统中可用的 RISC-V objdump"""
    for name in OBJDUMP_CANDIDATES:
        try:
            subprocess.run([name, "--version"], capture_output=True, check=True)
            return name
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    return None


def parse_coe(coe_path):
    """解析 COE 文件，返回 32-bit 整数列表"""
    words = []
    in_vector = False

    with open(coe_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(";"):
                continue

            if "memory_initialization_vector" in line:
                in_vector = True
                # 处理同一行有数据的情况 (vector=xxx)
                if "=" in line:
                    data_part = line.split("=", 1)[1].strip()
                    if data_part:
                        line = data_part
                    else:
                        continue
                else:
                    continue

            if not in_vector:
                continue

            # 去掉行末分号/逗号
            line = line.rstrip(";").rstrip(",").strip()
            if not line:
                continue

            # 可能一行有多个值（逗号分隔）
            for token in line.split(","):
                token = token.strip()
                if token:
                    try:
                        words.append(int(token, 16))
                    except ValueError:
                        pass

    return words


def disassemble(words, objdump, base_addr=TEXT_BASE):
    """将 32-bit 指令列表通过 objdump 反汇编"""
    # 构建 raw binary
    binary = b""
    for w in words:
        binary += struct.pack("<I", w & 0xFFFFFFFF)

    # 写入临时 bin 文件
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        tmp.write(binary)
        tmp_path = tmp.name

    try:
        # 用 objdump -b binary -m riscv:rv32 -D 反汇编
        result = subprocess.run(
            [
                objdump,
                "-b", "binary",
                "-m", "riscv:rv32",
                "-D",
                "--adjust-vma", f"0x{base_addr:08x}",
                "-EL",  # little-endian
                tmp_path,
            ],
            capture_output=True,
            text=True,
        )
        return result.stdout
    finally:
        os.unlink(tmp_path)


def format_output(raw_disasm, words, base_addr=TEXT_BASE):
    """格式化输出：提取有效反汇编行，跳过 objdump 文件头"""
    lines = []
    lines.append(f"# RISC-V Disassembly (base=0x{base_addr:08X}, {len(words)} instructions)")
    lines.append(f"# {'='*70}")
    lines.append("")

    # 从 objdump 输出中提取指令行
    for line in raw_disasm.splitlines():
        line = line.strip()
        # objdump 指令行格式: "80000000:	0013d117          	auipc	sp,0x13d"
        if line and ":" in line and "\t" in line:
            # 检查是否以地址开头
            addr_part = line.split(":")[0].strip()
            try:
                int(addr_part, 16)
                lines.append(line)
            except ValueError:
                pass

    return "\n".join(lines)


def process_directory(coe_dir, objdump):
    """处理一个 COE 目录"""
    irom_path = os.path.join(coe_dir, "irom.coe")
    if not os.path.exists(irom_path):
        print(f"  ⚠ 未找到 {irom_path}，跳过")
        return False

    dir_name = os.path.basename(coe_dir)
    print(f"  📖 解析 {dir_name}/irom.coe ...", end=" ")

    words = parse_coe(irom_path)
    print(f"{len(words)} 条指令")

    if not words:
        print(f"  ⚠ 文件为空，跳过")
        return False

    # 统计指令类型
    branch_count = 0
    jal_count = 0
    jalr_count = 0
    for w in words:
        opcode = w & 0x7F
        if opcode == 0x63:    # B-type
            branch_count += 1
        elif opcode == 0x6F:  # JAL
            jal_count += 1
        elif opcode == 0x67:  # JALR
            jalr_count += 1

    print(f"  📊 跳转统计: Branch={branch_count}, JAL={jal_count}, JALR={jalr_count}")

    # 反汇编
    print(f"  🔧 反汇编中...")
    raw = disassemble(words, objdump)
    output = format_output(raw, words)

    # 写出
    out_path = os.path.join(coe_dir, "irom_disasm.txt")
    with open(out_path, "w") as f:
        f.write(output)
        f.write("\n")

    print(f"  ✅ 输出: {dir_name}/irom_disasm.txt")
    return True


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # 查找 objdump
    objdump = find_objdump()
    if not objdump:
        print("❌ 未找到 RISC-V objdump，请安装 riscv-gnu-toolchain")
        sys.exit(1)
    print(f"🔧 使用: {objdump}\n")

    # 确定要处理的目录
    all_dirs = ["src0", "src1", "src2", "current"]

    if len(sys.argv) > 1:
        target_dirs = sys.argv[1:]
    else:
        target_dirs = all_dirs

    for d in target_dirs:
        # 优先查找 single_issue/ 下的目录
        full_path = os.path.join(script_dir, 'single_issue', d)
        if not os.path.isdir(full_path):
            full_path = os.path.join(script_dir, d)  # fallback
        if not os.path.isdir(full_path):
            print(f"⚠ 目录 {d} 不存在，跳过\n")
            continue

        print(f"━━━ {d} ━━━")
        process_directory(full_path, objdump)
        print()

    print("🎉 全部完成！")


if __name__ == "__main__":
    main()
