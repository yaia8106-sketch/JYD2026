#!/usr/bin/env python3
"""Compare RV32I reference commits against tb_riscv_tests compact trace."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


REF_RE = re.compile(
    r"^REF pc=([0-9a-fA-F]+) rd=(\d+) wen=(\d+) data=([0-9a-fA-F]+) inst=([0-9a-fA-F]+)"
)
RTL_RE = re.compile(
    r"^\d+ WB[01] pc=([0-9a-fA-F]+) rd=(\d+) wen=(\d+) data=([0-9a-fA-F]+)"
)
IROM_BASE = 0x8000_0000


def load_ref(path: Path) -> list[dict[str, int]]:
    events = []
    for line in path.read_text(encoding="ascii", errors="ignore").splitlines():
        match = REF_RE.match(line)
        if match:
            pc, rd, wen, data, inst = match.groups()
            events.append(
                {
                    "pc": int(pc, 16),
                    "rd": int(rd),
                    "wen": int(wen),
                    "data": int(data, 16),
                    "inst": int(inst, 16),
                }
            )
    return events


def load_rtl(path: Path) -> list[dict[str, int]]:
    events = []
    for line in path.read_text(encoding="ascii", errors="ignore").splitlines():
        match = RTL_RE.match(line)
        if match:
            pc, rd, wen, data = match.groups()
            events.append(
                {
                    "pc": int(pc, 16),
                    "rd": int(rd),
                    "wen": int(wen),
                    "data": int(data, 16),
                }
            )
    while events and events[0]["pc"] < IROM_BASE:
        events.pop(0)
    return events


def effect(event: dict[str, int]) -> tuple[int, int, int]:
    if event["wen"] and event["rd"] != 0:
        return (1, event["rd"], event["data"] & 0xFFFF_FFFF)
    return (0, 0, 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ref", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument("--commits", type=int, default=2000)
    parser.add_argument("--name", default="coe")
    args = parser.parse_args()

    ref = load_ref(args.ref)[: args.commits]
    rtl = load_rtl(args.rtl)[: args.commits]
    if len(rtl) < len(ref):
        print(f"[FAIL] {args.name}: RTL trace too short, rtl={len(rtl)} ref={len(ref)}")
        return 1

    for index, (r_event, t_event) in enumerate(zip(ref, rtl), start=1):
        if r_event["pc"] != t_event["pc"]:
            print(
                f"[FAIL] {args.name}: commit {index} PC mismatch "
                f"ref=0x{r_event['pc']:08x} rtl=0x{t_event['pc']:08x} "
                f"inst=0x{r_event['inst']:08x}"
            )
            return 1

        if effect(r_event) != effect(t_event):
            print(
                f"[FAIL] {args.name}: commit {index} writeback mismatch "
                f"pc=0x{r_event['pc']:08x} inst=0x{r_event['inst']:08x} "
                f"ref=(rd={r_event['rd']}, wen={r_event['wen']}, data=0x{r_event['data']:08x}) "
                f"rtl=(rd={t_event['rd']}, wen={t_event['wen']}, data=0x{t_event['data']:08x})"
            )
            return 1

    print(f"[PASS] {args.name}: {len(ref)} commits match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
