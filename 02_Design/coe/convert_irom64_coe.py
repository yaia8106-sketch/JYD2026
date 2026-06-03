#!/usr/bin/env python3
"""Generate 64-bit IROM COE files from the existing 32-bit COE programs."""

from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path


NOP = "00000013"
IROM64_DEPTH = 4096
MAX_SOURCE_WORDS = 4096


def normalize_word(word: str, width: int) -> str:
    word = word.strip()
    if word.lower().startswith("0x"):
        word = word[2:]
    if not re.fullmatch(r"[0-9a-fA-F]+", word):
        raise ValueError(f"invalid hex word: {word!r}")
    return word.upper().zfill(width)[-width:]


def read_coe_words(path: Path, width: int = 8) -> list[str]:
    words: list[str] = []
    in_vector = False

    for raw_line in path.read_text().splitlines():
        line = raw_line.split("//", 1)[0].split("#", 1)[0].strip()
        if not line:
            continue

        radix_match = re.match(r"memory_initialization_radix\s*=\s*(\d+)\s*;", line, re.I)
        if radix_match:
            radix = int(radix_match.group(1))
            if radix != 16:
                raise ValueError(f"{path}: only radix=16 is supported, got radix={radix}")
            continue

        vector_match = re.match(r"memory_initialization_vector\s*=(.*)", line, re.I)
        if vector_match:
            in_vector = True
            line = vector_match.group(1)
        elif not in_vector:
            continue

        for item in line.replace(";", ",").split(","):
            item = item.strip()
            if item:
                words.append(normalize_word(item, width))

    if not words:
        raise ValueError(f"{path}: no memory_initialization_vector words found")
    return words


def interleave_slots(slot0_words: list[str], slot1_words: list[str]) -> list[str]:
    words: list[str] = []
    for idx in range(max(len(slot0_words), len(slot1_words))):
        words.append(slot0_words[idx] if idx < len(slot0_words) else NOP)
        words.append(slot1_words[idx] if idx < len(slot1_words) else NOP)
    return words


def write_irom64_coe(path: Path, words: list[str]) -> None:
    if len(words) > MAX_SOURCE_WORDS:
        raise ValueError(
            f"{path}: {len(words)} 32-bit source words exceed current IROM address range "
            f"({MAX_SOURCE_WORDS} words)"
        )

    lines = [
        "memory_initialization_radix=16;",
        "memory_initialization_vector=",
    ]
    for idx in range(IROM64_DEPTH):
        low_idx = idx * 2
        high_idx = low_idx + 1
        low = words[low_idx] if low_idx < len(words) else NOP
        high = words[high_idx] if high_idx < len(words) else NOP
        suffix = ";" if idx == IROM64_DEPTH - 1 else ","
        lines.append(f"{high}{low}{suffix}")

    path.write_text("\n".join(lines) + "\n")


def validate_dual_matches_single(name: str, single_words: list[str], dual_dir: Path) -> None:
    slot0 = dual_dir / "irom_slot0.coe"
    slot1 = dual_dir / "irom_slot1.coe"
    if not (slot0.exists() and slot1.exists()):
        return

    dual_words = interleave_slots(read_coe_words(slot0), read_coe_words(slot1))
    expected_prefix = dual_words[: len(single_words)]
    if expected_prefix != single_words:
        raise ValueError(f"{name}: dual_issue slots do not match single_issue/irom.coe")

    trailing = dual_words[len(single_words) :]
    if any(word != NOP for word in trailing):
        raise ValueError(f"{name}: dual_issue slots contain non-NOP data after single_issue program")


def program_names(coe_root: Path) -> list[str]:
    names: set[str] = set()
    for family in ("single_issue", "dual_issue"):
        family_dir = coe_root / family
        if not family_dir.is_dir():
            continue
        for child in family_dir.iterdir():
            if child.is_dir():
                names.add(child.name)
    return sorted(names)


def convert_program(coe_root: Path, name: str) -> tuple[str, int, Path]:
    single_dir = coe_root / "single_issue" / name
    dual_dir = coe_root / "dual_issue" / name
    out_dir = coe_root / "irom64" / name
    out_dir.mkdir(parents=True, exist_ok=True)

    if (single_dir / "irom.coe").exists():
        words = read_coe_words(single_dir / "irom.coe")
        source = single_dir / "irom.coe"
        validate_dual_matches_single(name, words, dual_dir)
        dram_src = single_dir / "dram.coe"
    elif (dual_dir / "irom_slot0.coe").exists() and (dual_dir / "irom_slot1.coe").exists():
        words = interleave_slots(
            read_coe_words(dual_dir / "irom_slot0.coe"),
            read_coe_words(dual_dir / "irom_slot1.coe"),
        )
        source = dual_dir
        dram_src = dual_dir / "dram.coe"
    else:
        raise ValueError(f"{name}: no irom.coe or irom_slot0/1.coe found")

    write_irom64_coe(out_dir / "irom64.coe", words)
    if dram_src.exists():
        shutil.copy2(dram_src, out_dir / "dram.coe")

    return (str(source.relative_to(coe_root)), len(words), out_dir)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--coe-root",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="COE root directory, default: this script's directory",
    )
    parser.add_argument(
        "names",
        nargs="*",
        help="Program names to convert. If omitted, convert every program found.",
    )
    args = parser.parse_args()

    coe_root = args.coe_root.resolve()
    names = args.names or program_names(coe_root)
    if not names:
        raise SystemExit(f"no COE programs found under {coe_root}")

    for name in names:
        source, word_count, out_dir = convert_program(coe_root, name)
        print(f"{name}: {source} -> {out_dir.relative_to(coe_root)}/irom64.coe ({word_count} words)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
