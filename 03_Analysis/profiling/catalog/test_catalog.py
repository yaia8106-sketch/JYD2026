#!/usr/bin/env python3
"""
Profiling test catalog.

Responsible for:
- defining default profiling tests and their stop conditions;
- resolving COE input paths relative to the workspace;
- converting flat or banked COE files to readmemh-compatible hex files for
  the simulator.

Not responsible for:
- compiling or running the simulator;
- parsing simulator logs;
- deciding performance conclusions.

Inputs:
- requested test names;
- workspace path;
- profiling output directory.

Outputs:
- TestSpec and PreparedTest objects consumed by runners/sim_runner.py.

Dependencies:
- Python standard library only.

Common extension point:
- add new benchmark definitions here when a new stable profiling workload is
  needed. Do not hard-code test paths or stop PCs in collectors.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional


DEFAULT_MAX_CYCLES = 5_000_000_000
DEFAULT_WATCHDOG_CYCLES = 150_000


@dataclass(frozen=True)
class TestSpec:
    name: str
    kind: str
    dram_coe: Path
    stop_pc: Optional[int]
    irom_coe: Optional[Path] = None
    irom_slot0_coe: Optional[Path] = None
    irom_slot1_coe: Optional[Path] = None
    max_cycles: int = DEFAULT_MAX_CYCLES
    watchdog_cycles: int = DEFAULT_WATCHDOG_CYCLES


@dataclass(frozen=True)
class PreparedTest:
    spec: TestSpec
    dram_hex: Path
    log_file: Path
    irom_hex: Optional[Path] = None
    irom_slot0_hex: Optional[Path] = None
    irom_slot1_hex: Optional[Path] = None

    @property
    def irom_mode(self) -> str:
        if self.irom_slot0_hex is not None and self.irom_slot1_hex is not None:
            return "banked"
        return "flat"


def default_tests(workspace: Path) -> Dict[str, TestSpec]:
    """Return the daily profiling set: the two latest COE programs."""
    base = workspace / "02_Design" / "coe" / "dual_issue"
    return {
        "new_without_Mext": TestSpec(
            name="new_without_Mext",
            kind="coe",
            dram_coe=base / "new_without_Mext" / "dram.coe",
            stop_pc=0x80000010,
            irom_slot0_coe=base / "new_without_Mext" / "irom_slot0.coe",
            irom_slot1_coe=base / "new_without_Mext" / "irom_slot1.coe",
        ),
        "new_with_Mext": TestSpec(
            name="new_with_Mext",
            kind="coe",
            dram_coe=base / "new_with_Mext" / "dram.coe",
            stop_pc=0x80000014,
            irom_slot0_coe=base / "new_with_Mext" / "irom_slot0.coe",
            irom_slot1_coe=base / "new_with_Mext" / "irom_slot1.coe",
        ),
    }


def resolve_tests(workspace: Path, requested: Optional[Iterable[str]]) -> List[TestSpec]:
    """Resolve requested test names, defaulting to the two latest COE programs."""
    tests = default_tests(workspace)
    names = list(requested or tests.keys())
    resolved: List[TestSpec] = []

    for name in names:
        if name not in tests:
            valid = ", ".join(sorted(tests))
            raise ValueError(f"unknown profiling test '{name}'. Valid tests: {valid}")
        spec = tests[name]
        has_flat_irom = spec.irom_coe is not None
        has_banked_irom = spec.irom_slot0_coe is not None or spec.irom_slot1_coe is not None
        if has_flat_irom == has_banked_irom:
            raise ValueError(
                f"{spec.name}: specify either flat irom_coe or both banked IROM COEs"
            )
        if spec.irom_coe is not None and not spec.irom_coe.exists():
            raise FileNotFoundError(f"{spec.name}: missing IROM COE: {spec.irom_coe}")
        if has_banked_irom:
            if spec.irom_slot0_coe is None or spec.irom_slot1_coe is None:
                raise ValueError(f"{spec.name}: banked IROM requires both slot0 and slot1 COEs")
            if not spec.irom_slot0_coe.exists():
                raise FileNotFoundError(f"{spec.name}: missing IROM slot0 COE: {spec.irom_slot0_coe}")
            if not spec.irom_slot1_coe.exists():
                raise FileNotFoundError(f"{spec.name}: missing IROM slot1 COE: {spec.irom_slot1_coe}")
        if not spec.dram_coe.exists():
            raise FileNotFoundError(f"{spec.name}: missing DRAM COE: {spec.dram_coe}")
        resolved.append(spec)

    return resolved


def parse_coe_words(path: Path) -> List[str]:
    """Parse Vivado COE words and return uppercase 8-hex-digit strings."""
    words: List[str] = []
    in_vector = False

    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("//"):
            continue

        lower = line.lower()
        if "memory_initialization_vector" in lower:
            in_vector = True
            if "=" in line:
                line = line.split("=", 1)[1].strip()
            else:
                continue

        if not in_vector:
            continue

        line = line.replace(";", ",")
        for token in line.split(","):
            token = token.strip()
            if not token:
                continue
            if token.lower().startswith("0x"):
                token = token[2:]
            value = int(token, 16)
            words.append(f"{value & 0xFFFFFFFF:08X}")

    return words


def write_hex(words: List[str], path: Path, *, depth: int, pad_word: str) -> None:
    """Write one 32-bit word per line for $readmemh."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if len(words) > depth:
        raise ValueError(f"{path}: {len(words)} words exceeds depth {depth}")
    padded = words + [pad_word] * (depth - len(words))
    path.write_text("".join(f"{word}\n" for word in padded))


def prepare_test(spec: TestSpec, output_dir: Path) -> PreparedTest:
    """Convert COE inputs to hex files under the ignored profiling output dir."""
    hex_dir = output_dir / "hex"
    log_dir = output_dir / "logs"
    hex_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    dram_hex = hex_dir / f"{spec.name}.dram.hex"
    write_hex(parse_coe_words(spec.dram_coe), dram_hex, depth=65536, pad_word="00000000")

    irom_hex: Optional[Path] = None
    irom_slot0_hex: Optional[Path] = None
    irom_slot1_hex: Optional[Path] = None
    if spec.irom_coe is not None:
        irom_hex = hex_dir / f"{spec.name}.irom.hex"
        write_hex(parse_coe_words(spec.irom_coe), irom_hex, depth=4096, pad_word="00000013")
    else:
        if spec.irom_slot0_coe is None or spec.irom_slot1_coe is None:
            raise ValueError(f"{spec.name}: banked IROM requires both slot0 and slot1 COEs")
        irom_slot0_hex = hex_dir / f"{spec.name}.irom_slot0.hex"
        irom_slot1_hex = hex_dir / f"{spec.name}.irom_slot1.hex"
        write_hex(parse_coe_words(spec.irom_slot0_coe), irom_slot0_hex, depth=4096, pad_word="00000013")
        write_hex(parse_coe_words(spec.irom_slot1_coe), irom_slot1_hex, depth=4096, pad_word="00000013")

    return PreparedTest(
        spec=spec,
        dram_hex=dram_hex,
        log_file=log_dir / f"{spec.name}.log",
        irom_hex=irom_hex,
        irom_slot0_hex=irom_slot0_hex,
        irom_slot1_hex=irom_slot1_hex,
    )
