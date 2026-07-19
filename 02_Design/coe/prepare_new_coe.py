#!/usr/bin/env python3
"""Prepare contest 32-bit IROM/DRAM COE files for the IROM64 Vivado flow."""

from __future__ import annotations

import argparse
import re
import shutil
import tempfile
from pathlib import Path


NOP = "00000013"
IROM64_DEPTH = 4096
MAX_SOURCE_WORDS = 4096
COE_ROOT = Path(__file__).resolve().parent
DEFAULT_SOURCE_DIR = COE_ROOT / "new"
DEFAULT_OUTPUT_DIR = COE_ROOT / "irom64" / "new"


def resolve_input(source_dir: Path, stem: str) -> Path:
    candidates = [
        source_dir / stem,
        source_dir / f"{stem}.coe",
        source_dir / stem.lower(),
        source_dir / f"{stem.lower()}.coe",
    ]
    existing = [path for path in candidates if path.is_file()]
    if not existing:
        expected = ", ".join(path.name for path in candidates)
        raise ValueError(f"{source_dir}: missing {stem} COE; expected one of: {expected}")
    if len(existing) > 1:
        names = ", ".join(path.name for path in existing)
        raise ValueError(f"{source_dir}: multiple {stem} inputs found ({names}); keep exactly one")
    return existing[0]


def strip_comments(text: str) -> str:
    lines: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.split("//", 1)[0].split("#", 1)[0]
        lines.append(line)
    return "\n".join(lines)


def read_coe_words(path: Path, hex_digits: int) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError as error:
        raise ValueError(f"{path}: COE must be UTF-8/ASCII text") from error

    text = strip_comments(text)
    radix_match = re.search(
        r"memory_initialization_radix\s*=\s*(\d+)\s*;", text, re.IGNORECASE
    )
    if radix_match is None:
        raise ValueError(f"{path}: missing memory_initialization_radix")
    if int(radix_match.group(1)) != 16:
        raise ValueError(f"{path}: only radix=16 is supported")

    vector_match = re.search(
        r"memory_initialization_vector\s*=\s*(.*?)\s*;",
        text,
        re.IGNORECASE | re.DOTALL,
    )
    if vector_match is None:
        raise ValueError(f"{path}: missing semicolon-terminated memory_initialization_vector")

    raw_words = [word for word in re.split(r"[\s,]+", vector_match.group(1)) if word]
    if not raw_words:
        raise ValueError(f"{path}: memory_initialization_vector is empty")

    words: list[str] = []
    for index, raw_word in enumerate(raw_words):
        word = raw_word[2:] if raw_word.lower().startswith("0x") else raw_word
        if not re.fullmatch(r"[0-9a-fA-F]+", word):
            raise ValueError(f"{path}: entry {index} is not hexadecimal: {raw_word!r}")
        if len(word) > hex_digits:
            raise ValueError(
                f"{path}: entry {index} has {len(word) * 4} bits; expected at most "
                f"{hex_digits * 4} bits"
            )
        words.append(word.upper().zfill(hex_digits))
    return words


def write_irom64(path: Path, source_words: list[str]) -> None:
    if len(source_words) > MAX_SOURCE_WORDS:
        raise ValueError(
            f"IROM contains {len(source_words)} 32-bit words; current design supports at most "
            f"{MAX_SOURCE_WORDS}"
        )

    lines = ["memory_initialization_radix=16;", "memory_initialization_vector="]
    for entry_index in range(IROM64_DEPTH):
        low_index = entry_index * 2
        high_index = low_index + 1
        low_word = source_words[low_index] if low_index < len(source_words) else NOP
        high_word = source_words[high_index] if high_index < len(source_words) else NOP
        suffix = ";" if entry_index == IROM64_DEPTH - 1 else ","
        lines.append(f"{high_word}{low_word}{suffix}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def install_output(staging_dir: Path, output_dir: Path) -> None:
    output_parent = output_dir.parent
    output_parent.mkdir(parents=True, exist_ok=True)
    backup_dir = output_parent / ".new.previous"

    if backup_dir.exists():
        shutil.rmtree(backup_dir)

    replaced_existing = False
    try:
        if output_dir.exists():
            output_dir.rename(backup_dir)
            replaced_existing = True
        staging_dir.rename(output_dir)
    except Exception:
        if replaced_existing and backup_dir.exists() and not output_dir.exists():
            backup_dir.rename(output_dir)
        raise
    else:
        if backup_dir.exists():
            shutil.rmtree(backup_dir)


def prepare(source_dir: Path, output_dir: Path) -> tuple[Path, Path, int]:
    source_dir = source_dir.expanduser().resolve()
    output_dir = output_dir.expanduser().resolve()
    if not source_dir.is_dir():
        raise ValueError(f"contest COE directory not found: {source_dir}")

    irom_source = resolve_input(source_dir, "IROM")
    dram_source = resolve_input(source_dir, "DRAM")
    irom_words = read_coe_words(irom_source, hex_digits=8)
    dram_words = read_coe_words(dram_source, hex_digits=8)

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    staging_dir = Path(
        tempfile.mkdtemp(prefix=".new.staging-", dir=str(output_dir.parent))
    )
    try:
        irom64_output = staging_dir / "irom64.coe"
        dram_output = staging_dir / "dram.coe"
        write_irom64(irom64_output, irom_words)
        shutil.copy2(dram_source, dram_output)

        generated_irom = read_coe_words(irom64_output, hex_digits=16)
        generated_dram = read_coe_words(dram_output, hex_digits=8)
        if len(generated_irom) != IROM64_DEPTH:
            raise ValueError(
                f"generated IROM64 has {len(generated_irom)} entries; expected {IROM64_DEPTH}"
            )
        if generated_dram != dram_words:
            raise ValueError("generated DRAM does not match the contest DRAM input")

        install_output(staging_dir, output_dir)
    finally:
        if staging_dir.exists():
            shutil.rmtree(staging_dir)

    return irom_source, dram_source, len(irom_words)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Convert contest 32-bit IROM plus DRAM COE files into the normalized "
            "irom64/new directory used by the Vivado flow."
        )
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=DEFAULT_SOURCE_DIR,
        help=f"input directory (default: {DEFAULT_SOURCE_DIR})",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"output directory (default: {DEFAULT_OUTPUT_DIR})",
    )
    args = parser.parse_args()

    try:
        irom_source, dram_source, word_count = prepare(args.source_dir, args.output_dir)
    except (OSError, ValueError) as error:
        parser.exit(2, f"ERROR: {error}\n")

    output_dir = args.output_dir.expanduser().resolve()
    print("================================================================")
    print(" Contest COE preparation complete")
    print("================================================================")
    print(f"IROM source     : {irom_source}")
    print(f"DRAM source     : {dram_source}")
    print(f"32-bit words    : {word_count}")
    print(f"IROM64 output   : {output_dir / 'irom64.coe'}")
    print(f"DRAM output     : {output_dir / 'dram.coe'}")
    print("Packing order   : {instruction[2n+1], instruction[2n]}")
    print("Next step       : ./03_Timing_Analysis/build.sh <jobs> new")
    print("================================================================")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
