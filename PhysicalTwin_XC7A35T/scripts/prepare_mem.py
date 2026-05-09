#!/usr/bin/env python3

import argparse
import re
import sys
from pathlib import Path
from typing import List, Tuple


NOP = 0x00000013
DRAM_PHYS_PAGES = 48
DRAM_PAGE_WORDS = 1024


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


def word_or_fill(words: List[int], index: int, fill: int) -> int:
    return words[index] if index < len(words) else fill


def pack_dram_pages(words: List[int], pages: List[int]) -> List[int]:
    packed = []
    for phys_page in range(DRAM_PHYS_PAGES):
        if phys_page >= len(pages):
            packed.extend([0] * DRAM_PAGE_WORDS)
            continue

        logical_page = pages[phys_page]
        logical_base = logical_page * DRAM_PAGE_WORDS
        for offset in range(DRAM_PAGE_WORDS):
            packed.append(word_or_fill(words, logical_base + offset, 0))
    return packed


def write_dram_banks(out_dir: Path, words: List[int]) -> List[Path]:
    bank_paths = []
    for bank in range(DRAM_PHYS_PAGES // 16):
        start = bank * 16 * DRAM_PAGE_WORDS
        end = start + 16 * DRAM_PAGE_WORDS
        path = out_dir / f"dram_bank{bank}.mem"
        write_mem(path, words[start:end], 16 * DRAM_PAGE_WORDS, 0)
        bank_paths.append(path)
    return bank_paths


def unique_ordered(values: List[int]) -> List[int]:
    seen = set()
    out = []
    for value in values:
        if value not in seen:
            seen.add(value)
            out.append(value)
    return out


def page_range(first: int, last: int) -> List[int]:
    return list(range(first, last + 1))


def dram_page_map(coe_set: str) -> List[int]:
    name = Path(coe_set).name

    if name == "src0":
        raise ValueError(
            "dual_issue/src0 is not supported by this XC7A35T physical DRAM "
            "mapping. Its full dynamic working set exceeds the 48-page board "
            "limit, so building it would produce an invalid early-exit/error-path image."
        )
    elif name == "src1":
        pages = page_range(0x00, 0x2C) + [0x34]
    elif name == "src2":
        pages = page_range(0x00, 0x2C) + page_range(0x3A, 0x3C)
    else:
        pages = page_range(0x00, DRAM_PHYS_PAGES - 1)

    pages = unique_ordered(pages)
    if len(pages) > DRAM_PHYS_PAGES:
        raise ValueError(
            f"DRAM page map for {coe_set} needs {len(pages)} pages, "
            f"but only {DRAM_PHYS_PAGES} physical pages are available"
        )
    for page in pages:
        if page < 0 or page > 0x3F:
            raise ValueError(f"invalid logical DRAM page 0x{page:x}")
    return pages


def unmapped_nonzero_words(words: List[int], pages: List[int]) -> List[int]:
    mapped = set(pages)
    return [
        index
        for index, word in enumerate(words)
        if word != 0 and (index // DRAM_PAGE_WORDS) not in mapped
    ]


def write_dram_map(path: Path, coe_set: str, pages: List[int]) -> None:
    lines = [
        "`ifndef PHYSICAL_DRAM_MAP_VH",
        "`define PHYSICAL_DRAM_MAP_VH",
        f"`define PT_DRAM_PHYS_PAGES 6'd{DRAM_PHYS_PAGES}",
        "",
        "function automatic logic [5:0] pt_dram_page_map(input logic [5:0] page);",
        "    begin",
        "        case (page)",
    ]
    for phys_page, logical_page in enumerate(pages):
        lines.append(
            f"            6'h{logical_page:02x}: pt_dram_page_map = 6'd{phys_page};"
        )
    lines.extend(
        [
            "            default: pt_dram_page_map = 6'h3f;",
            "        endcase",
            "    end",
            "endfunction",
            "",
            "`endif",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="ascii")


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
    parser.add_argument("--rom-depth-words", type=int, default=1024)
    parser.add_argument("--dram-depth-words", type=int, default=DRAM_PHYS_PAGES * DRAM_PAGE_WORDS)
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

    slot0_mem = out_dir / "irom_slot0.mem"
    slot1_mem = out_dir / "irom_slot1.mem"
    dram_mem = out_dir / "dram.mem"
    dram_map = out_dir / "physical_dram_map.vh"
    mapped_pages = dram_page_map(args.coe)
    unmapped_words = unmapped_nonzero_words(dram_words, mapped_pages)
    if unmapped_words:
        first = unmapped_words[0]
        raise ValueError(
            f"DRAM page map for {args.coe} would drop {len(unmapped_words)} "
            f"non-zero words; first at logical page 0x{first // DRAM_PAGE_WORDS:02x}"
        )

    dram_phys_words = pack_dram_pages(dram_words, mapped_pages)
    if args.dram_depth_words != len(dram_phys_words):
        raise ValueError(
            f"physical DRAM depth must be {len(dram_phys_words)} words "
            f"for this board build"
        )
    dram_bank_mems = write_dram_banks(out_dir, dram_phys_words)

    write_mem(slot0_mem, slot0_words, args.rom_depth_words, NOP)
    write_mem(slot1_mem, slot1_words, args.rom_depth_words, NOP)
    write_mem(dram_mem, dram_phys_words, args.dram_depth_words, 0)
    write_dram_map(dram_map, args.coe, mapped_pages)

    include = out_dir / "physical_mem_paths.vh"
    include.write_text(
        "\n".join(
            [
                "`ifndef PHYSICAL_MEM_PATHS_VH",
                "`define PHYSICAL_MEM_PATHS_VH",
                f'`define PT_IROM_SLOT0_MEM "{slot0_mem}"',
                f'`define PT_IROM_SLOT1_MEM "{slot1_mem}"',
                f'`define PT_DRAM_MEM "{dram_mem}"',
                f'`define PT_DRAM_BANK0_MEM "{dram_bank_mems[0]}"',
                f'`define PT_DRAM_BANK1_MEM "{dram_bank_mems[1]}"',
                f'`define PT_DRAM_BANK2_MEM "{dram_bank_mems[2]}"',
                "`endif",
                "",
            ]
        ),
        encoding="utf-8",
    )

    print(f"COE set: {args.coe}")
    print(f"IROM slot0 words: {len(slot0_words)} / {args.rom_depth_words}")
    print(f"IROM slot1 words: {len(slot1_words)} / {args.rom_depth_words}")
    print(f"DRAM logical words: {len(dram_words)}")
    print(f"DRAM physical words: {len(dram_phys_words)} / {args.dram_depth_words}")
    print(
        "DRAM logical pages: "
        + ", ".join(f"0x{page:02x}" for page in mapped_pages)
    )
    print(f"Generated: {out_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
