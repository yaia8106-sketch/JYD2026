#!/usr/bin/env python3
"""
COE → 反汇编脚本
将 Vivado BRAM COE 文件中的 hex 指令转为 RISC-V 反汇编。

用法:
    python3 disasm_coe.py                  # 反汇编所有 single_issue/dual_issue 子目录
    python3 disasm_coe.py src0             # 反汇编 single_issue/src0 和 dual_issue/src0
    python3 disasm_coe.py single_issue/src0
    python3 disasm_coe.py dual_issue/src0

输出: 每个 IROM 目录下生成 irom_disasm.txt
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


def format_output(raw_disasm, words, base_addr=TEXT_BASE, source_desc=None):
    """格式化输出：提取有效反汇编行，跳过 objdump 文件头"""
    lines = []
    lines.append(f"# RISC-V Disassembly (base=0x{base_addr:08X}, {len(words)} instructions)")
    if source_desc:
        lines.append(f"# Source: {source_desc}")
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


def interleave_slot_words(slot0_words, slot1_words):
    """将双发射 slot0/slot1 IROM 还原为顺序指令流。"""
    words = []
    max_len = max(len(slot0_words), len(slot1_words))
    for i in range(max_len):
        if i < len(slot0_words):
            words.append(slot0_words[i])
        if i < len(slot1_words):
            words.append(slot1_words[i])
    return words


def find_irom_words(coe_dir):
    """读取一个 COE 目录中的 IROM，支持单发射和双发射目录。"""
    single_irom = coe_dir / "irom.coe"
    slot0_irom = coe_dir / "irom_slot0.coe"
    slot1_irom = coe_dir / "irom_slot1.coe"

    if single_irom.exists():
        return parse_coe(single_irom), "irom.coe"

    if slot0_irom.exists() and slot1_irom.exists():
        slot0_words = parse_coe(slot0_irom)
        slot1_words = parse_coe(slot1_irom)
        return (
            interleave_slot_words(slot0_words, slot1_words),
            f"irom_slot0.coe + irom_slot1.coe (interleaved, slot0={len(slot0_words)}, slot1={len(slot1_words)})",
        )

    return None, None


def discover_directories(script_dir):
    """扫描 single_issue/ 和 dual_issue/ 下包含 IROM COE 的目录。"""
    roots = [Path(script_dir) / "single_issue", Path(script_dir) / "dual_issue"]
    dirs = []
    for root in roots:
        if not root.is_dir():
            continue
        for child in sorted(root.iterdir()):
            if not child.is_dir():
                continue
            words, _ = find_irom_words(child)
            if words is not None:
                dirs.append(child)
    return dirs


def resolve_target_dirs(script_dir, targets):
    """将命令行目标解析为实际目录。"""
    if not targets:
        return discover_directories(script_dir)

    script_path = Path(script_dir)
    resolved = []
    for target in targets:
        target_path = Path(target)
        candidates = []

        if target_path.is_absolute() or len(target_path.parts) > 1:
            candidates.append(script_path / target_path)
        else:
            candidates.extend([
                script_path / "single_issue" / target,
                script_path / "dual_issue" / target,
                script_path / target,
            ])

        matched = False
        for candidate in candidates:
            if candidate.is_dir():
                words, _ = find_irom_words(candidate)
                if words is not None:
                    resolved.append(candidate)
                    matched = True

        if not matched:
            print(f"⚠ 目录 {target} 不存在或未找到 IROM COE，跳过")

    # 去重但保持顺序
    unique = []
    seen = set()
    for directory in resolved:
        key = directory.resolve()
        if key not in seen:
            unique.append(directory)
            seen.add(key)
    return unique


def process_directory(coe_dir, objdump):
    """处理一个 COE 目录"""
    words, source_desc = find_irom_words(coe_dir)
    if words is None:
        print(f"  ⚠ 未找到 {coe_dir}/irom*.coe，跳过")
        return False

    rel_name = os.path.relpath(coe_dir, os.path.dirname(os.path.abspath(__file__)))
    print(f"  📖 解析 {rel_name}/{source_desc} ...", end=" ")
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
    output = format_output(raw, words, source_desc=source_desc)

    # 写出
    out_path = coe_dir / "irom_disasm.txt"
    with open(out_path, "w") as f:
        f.write(output)
        f.write("\n")

    print(f"  ✅ 输出: {rel_name}/irom_disasm.txt")
    return True


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # 查找 objdump
    objdump = find_objdump()
    if not objdump:
        print("❌ 未找到 RISC-V objdump，请安装 riscv-gnu-toolchain")
        sys.exit(1)
    print(f"🔧 使用: {objdump}\n")

    target_dirs = resolve_target_dirs(script_dir, sys.argv[1:])

    for full_path in target_dirs:
        rel_path = os.path.relpath(full_path, script_dir)
        print(f"━━━ {rel_path} ━━━")
        process_directory(full_path, objdump)
        print()

    print(f"🎉 全部完成：处理 {len(target_dirs)} 个目录")


if __name__ == "__main__":
    main()
