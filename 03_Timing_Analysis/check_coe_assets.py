#!/usr/bin/env python3
"""Check COE import assets used by the Vivado project."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

NOP = "00000013"
SLOT_DEPTH = 4096


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
        if not token or "=" in token:
            continue
        token = token.removeprefix("0x").removeprefix("0X")
        if re.fullmatch(r"[0-9a-fA-F]+", token):
            words.append(f"{int(token, 16) & 0xFFFF_FFFF:08X}")
    return words


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"ERROR: {message}")


def resolve_source(workspace: Path, coe_name: str) -> Path:
    candidates = [
        workspace / "02_Design" / "coe" / coe_name,
        workspace / "02_Design" / "coe" / "single_issue" / coe_name,
    ]
    for path in candidates:
        if path.is_dir():
            return path
    tried = "\n  ".join(str(path) for path in candidates)
    raise SystemExit(f"ERROR: COE directory not found for {coe_name}; tried:\n  {tried}")


def check_same_words(label: str, src: Path, dst: Path) -> None:
    src_words = parse_coe(src)
    dst_words = parse_coe(dst)
    require(src_words == dst_words, f"{label} import is stale: {src} != {dst}")
    print(f"[OK] {label}: {len(src_words)} words synced")


def check_irom_slots(irom: Path, slot0: Path, slot1: Path) -> None:
    base = parse_coe(irom)
    slots = [parse_coe(slot0), parse_coe(slot1)]
    require(
        len(base) <= SLOT_DEPTH,
        f"irom.coe has {len(base)} words, but CPU IROM supports {SLOT_DEPTH} instruction words",
    )

    for slot_id, words in enumerate(slots):
        require(
            len(words) == SLOT_DEPTH,
            f"irom_slot{slot_id}.coe has {len(words)} words, expected {SLOT_DEPTH}",
        )
        for index, actual in enumerate(words):
            src_index = index * 2 + slot_id
            expected = base[src_index] if src_index < len(base) else NOP
            require(
                actual == expected,
                "irom_slot{slot}.coe mismatch at bank word {bank} "
                "(source word {src}): expected {exp}, got {got}".format(
                    slot=slot_id,
                    bank=index,
                    src=src_index,
                    exp=expected,
                    got=actual,
                ),
            )

    print(
        "[OK] IROM slots: slot0=even words, slot1=odd words, "
        f"depth={SLOT_DEPTH}, pad={NOP}"
    )


def check_xci_binding(xci: Path, expected_name: str, required: bool = True) -> None:
    if not xci.exists():
        if required:
            raise SystemExit(f"ERROR: missing XCI: {xci}")
        print(f"[WARN] skip missing XCI: {xci}")
        return

    text = xci.read_text(encoding="utf-8", errors="ignore")
    require(expected_name in text, f"{xci} does not reference {expected_name}")
    print(f"[OK] XCI binding: {xci.name} -> {expected_name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("coe_name", nargs="?", default="current")
    parser.add_argument(
        "--workspace",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="CPU_Workspace root",
    )
    parser.add_argument("--skip-xci", action="store_true")
    args = parser.parse_args()

    workspace = args.workspace.resolve()
    source = resolve_source(workspace, args.coe_name)
    imported = (
        workspace
        / "JYD2025_Contest-rv32i"
        / "digital_twin.srcs"
        / "sources_1"
        / "imports"
        / "JYD2025"
        / "resource"
        / "coe"
    )
    ip_dir = (
        workspace
        / "JYD2025_Contest-rv32i"
        / "digital_twin.srcs"
        / "sources_1"
        / "ip"
    )

    required = [
        source / "irom.coe",
        source / "dram.coe",
        imported / "irom.coe",
        imported / "dram.coe",
        imported / "irom_slot0.coe",
        imported / "irom_slot1.coe",
    ]
    for path in required:
        require(path.exists(), f"missing file: {path}")

    print(f"[INFO] source : {source}")
    print(f"[INFO] import : {imported}")
    check_same_words("IROM", source / "irom.coe", imported / "irom.coe")
    check_same_words("DRAM", source / "dram.coe", imported / "dram.coe")
    check_irom_slots(
        imported / "irom.coe",
        imported / "irom_slot0.coe",
        imported / "irom_slot1.coe",
    )

    if not args.skip_xci:
        check_xci_binding(ip_dir / "IROMEven32" / "IROMEven32.xci", "irom_slot0.coe")
        check_xci_binding(ip_dir / "IROMOdd32" / "IROMOdd32.xci", "irom_slot1.coe")

    print("[PASS] COE assets are consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
