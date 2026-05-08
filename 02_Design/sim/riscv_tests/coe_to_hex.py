#!/usr/bin/env python3
"""Convert a Vivado .coe memory file to one-word-per-line $readmemh hex."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def parse_coe(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"//.*", "", text)
    text = re.sub(r"#.*", "", text)

    marker = re.search(r"memory_initialization_vector\s*=", text, re.IGNORECASE)
    if marker:
        text = text[marker.end() :]

    words: list[str] = []
    for token in re.split(r"[\s,;]+", text):
        token = token.strip()
        if not token:
            continue
        if "=" in token:
            continue
        token = token.removeprefix("0x").removeprefix("0X")
        if not re.fullmatch(r"[0-9a-fA-F]+", token):
            continue
        words.append(f"{int(token, 16) & 0xFFFF_FFFF:08x}")

    return words


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("coe", type=Path)
    parser.add_argument("hex", type=Path)
    parser.add_argument("--min-words", type=int, default=1)
    args = parser.parse_args()

    words = parse_coe(args.coe)
    if not words:
        raise SystemExit(f"no initialization words found in {args.coe}")
    while len(words) < args.min_words:
        words.append("00000000")

    args.hex.parent.mkdir(parents=True, exist_ok=True)
    args.hex.write_text("\n".join(words) + "\n", encoding="ascii")
    print(f"{args.coe}: {len(words)} words -> {args.hex}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
