#!/usr/bin/env python3
"""Derive the terminal stop_pc for contest COE programs.

The contest images start at 0x8000_0000 with a small entry stub:

    setup stack
    jal init
    jal main / workload
    j .

The self-loop is near the reset vector, not near the end of the IROM image.
Using the first self-loop in the whole program is too broad, so this tool only
accepts a self-loop in the entry window after at least one startup JAL.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SELF_LOOP = "0000006f"
NOP = "00000013"


def read_words(path: Path) -> list[str]:
    words: list[str] = []
    in_vector = False
    for raw in path.read_text().splitlines():
        line = raw.strip().lower()
        if not line:
            continue
        if "memory_initialization_vector" in line:
            in_vector = True
            continue
        if "=" in line and not in_vector:
            continue
        line = line.split(";", 1)[0].strip().rstrip(",")
        if re.fullmatch(r"[0-9a-f]{8}", line):
            words.append(line)
    return words


def is_jal(word: str) -> bool:
    value = int(word, 16)
    opcode = value & 0x7f
    rd = (value >> 7) & 0x1f
    return opcode == 0x6F and rd != 0


def interleaved_words(slot0: list[str], slot1: list[str]) -> list[tuple[int, int, str]]:
    out: list[tuple[int, int, str]] = []
    max_len = max(len(slot0), len(slot1))
    for idx in range(max_len):
        out.append((idx, 0, slot0[idx] if idx < len(slot0) else NOP))
        out.append((idx, 1, slot1[idx] if idx < len(slot1) else NOP))
    return out


def derive_stop_pc(slot0_path: Path, slot1_path: Path, base: int, entry_bytes: int) -> tuple[int, int, int]:
    words = interleaved_words(read_words(slot0_path), read_words(slot1_path))
    saw_startup_jal = False

    for inst_idx, (bank_idx, slot, word) in enumerate(words):
        pc = base + inst_idx * 4
        if pc >= base + entry_bytes:
            break
        if is_jal(word):
            saw_startup_jal = True
        if word == SELF_LOOP:
            if not saw_startup_jal:
                raise ValueError(
                    f"entry self-loop found at 0x{pc:08x}, but no earlier startup JAL was seen"
                )
            return pc, bank_idx, slot

    raise ValueError(
        f"no entry fall-through self-loop ({SELF_LOOP}) found within 0x{entry_bytes:x} bytes"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="derive stop_pc from the entry fall-through self-loop in banked COE IROM"
    )
    parser.add_argument("--slot0", required=True, type=Path)
    parser.add_argument("--slot1", required=True, type=Path)
    parser.add_argument("--base", default="0x80000000")
    parser.add_argument("--entry-bytes", default="0x100")
    parser.add_argument("--explain", action="store_true")
    args = parser.parse_args()

    base = int(str(args.base), 0)
    entry_bytes = int(str(args.entry_bytes), 0)

    try:
        pc, bank_idx, slot = derive_stop_pc(args.slot0, args.slot1, base, entry_bytes)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(f"{pc:08x}")
    if args.explain:
        print(
            f"stop_pc=0x{pc:08x} source=entry_self_loop bank_index={bank_idx} slot={slot}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
