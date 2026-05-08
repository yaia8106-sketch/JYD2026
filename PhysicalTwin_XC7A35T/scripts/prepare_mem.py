#!/usr/bin/env python3

import argparse
import re
from pathlib import Path
from typing import List, Tuple


NOP = 0x00000013


def read_coe(path: Path) -> List[int]:
    text = path.read_text(encoding="utf-8")
    match = re.search(
        r"memory_initialization_vector\s*=\s*(.*?);",
        text,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not match:
        raise ValueError(f"{path} does not contain memory_initialization_vector")

    body = re.sub(r"//.*?$", "", match.group(1), flags=re.MULTILINE)
    body = re.sub(r"--.*?$", "", body, flags=re.MULTILINE)
    return [
        int(token.replace("_", ""), 16) & 0xFFFFFFFF
        for token in re.findall(r"[0-9a-fA-F_]+", body)
    ]


def write_mem(path: Path, words: List[int], depth: int, fill: int) -> None:
    padded = words[:depth] + [fill] * max(0, depth - len(words))
    path.write_text(
        "".join(f"{word:08x}\n" for word in padded),
        encoding="ascii",
    )


def split_or_read_irom(coe_dir: Path) -> Tuple[List[int], List[int]]:
    slot0 = coe_dir / "irom_slot0.coe"
    slot1 = coe_dir / "irom_slot1.coe"
    single = coe_dir / "irom.coe"

    if slot0.exists() and slot1.exists():
        return read_coe(slot0), read_coe(slot1)
    if single.exists():
        words = read_coe(single)
        return words[0::2], words[1::2]

    raise FileNotFoundError(
        f"cannot find irom_slot0/1.coe or irom.coe under {coe_dir}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", default=".")
    parser.add_argument("--coe", default="dual_issue/current")
    parser.add_argument("--rom-depth-words", type=int, default=4096)
    parser.add_argument("--dram-depth-words", type=int, default=16384)
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    project_dir = workspace / "PhysicalTwin_XC7A35T"
    out_dir = project_dir / "generated"
    out_dir.mkdir(parents=True, exist_ok=True)

    coe_dir = workspace / "02_Design" / "coe" / args.coe
    if not coe_dir.is_dir():
        raise FileNotFoundError(f"COE directory not found: {coe_dir}")

    slot0_words, slot1_words = split_or_read_irom(coe_dir)
    dram_words = read_coe(coe_dir / "dram.coe")

    for name, words in (("irom_slot0", slot0_words), ("irom_slot1", slot1_words)):
        if len(words) > args.rom_depth_words:
            raise ValueError(
                f"{name} has {len(words)} words, larger than {args.rom_depth_words}"
            )

    dropped = dram_words[args.dram_depth_words :]
    nonzero_dropped = [word for word in dropped if word != 0]
    if nonzero_dropped:
        raise ValueError(
            f"DRAM depth {args.dram_depth_words} would drop "
            f"{len(nonzero_dropped)} non-zero words"
        )

    slot0_mem = out_dir / "irom_slot0.mem"
    slot1_mem = out_dir / "irom_slot1.mem"
    dram_mem = out_dir / "dram.mem"

    write_mem(slot0_mem, slot0_words, args.rom_depth_words, NOP)
    write_mem(slot1_mem, slot1_words, args.rom_depth_words, NOP)
    write_mem(dram_mem, dram_words, args.dram_depth_words, 0)

    include = out_dir / "physical_mem_paths.vh"
    include.write_text(
        "\n".join(
            [
                "`ifndef PHYSICAL_MEM_PATHS_VH",
                "`define PHYSICAL_MEM_PATHS_VH",
                f'`define PT_IROM_SLOT0_MEM "{slot0_mem}"',
                f'`define PT_IROM_SLOT1_MEM "{slot1_mem}"',
                f'`define PT_DRAM_MEM "{dram_mem}"',
                "`endif",
                "",
            ]
        ),
        encoding="utf-8",
    )

    print(f"COE set: {args.coe}")
    print(f"IROM slot0 words: {len(slot0_words)} / {args.rom_depth_words}")
    print(f"IROM slot1 words: {len(slot1_words)} / {args.rom_depth_words}")
    print(f"DRAM words: {len(dram_words)} / {args.dram_depth_words}")
    if dropped:
        print(f"DRAM trailing zero words cropped: {len(dropped)}")
    print(f"Generated: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
