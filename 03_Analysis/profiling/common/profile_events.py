#!/usr/bin/env python3
"""
Simulator log parsing helpers.

Responsible for:
- parsing stable result lines such as [PASS], [FAIL], [TIMEOUT], [DONE];
- parsing existing [PERF] human-readable counters into a small key/value map;
- keeping regular expressions out of runner and reporter code.

Not responsible for:
- running the simulator;
- deciding whether a test should have stopped;
- computing high-level optimization conclusions.

Inputs:
- simulator stdout text or log file content.

Outputs:
- dictionaries consumed by collectors.

Dependencies:
- Python standard library only.

Common extension point:
- add parsing for future structured [PROFILE] lines here, then let collectors
  consume those structured events instead of reading raw text directly.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Iterable, Optional


RESULT_RE = re.compile(r"^\[(PASS|FAIL|TIMEOUT|DONE)\]\s+(.*?)\s+\(>?\s*(\d+) cycles\)")
STOP_PC_RE = re.compile(
    r"reached stop_pc=0x([0-9a-fA-F]+)\s+commits=(\d+)\s+"
    r"first_led=0x([0-9a-fA-F]+)\s+last_led=0x([0-9a-fA-F]+)\s+led_writes=(\d+)"
)
LED_SUMMARY_RE = re.compile(
    r"first_led=0x([0-9a-fA-F]+)\s+last_led=0x([0-9a-fA-F]+)\s+led_writes=(\d+)"
)
COMMITS_RE = re.compile(r"reached\s+(\d+)\s+commits")
COMMIT_COUNT_RE = re.compile(r"commits=(\d+)")
PC_SUMMARY_RE = re.compile(
    r"pc=0x([0-9a-fA-F]+)\s+last_wb0_pc=0x([0-9a-fA-F]+)\s+last_wb1_pc=0x([0-9a-fA-F]+)"
)
PERF_INT_RE = re.compile(r"^\[PERF\]\s+([^:]+):\s+(-?\d+)")
PERF_FLOAT_RE = re.compile(r"^\[PERF\]\s+([^:]+):\s+(-?\d+(?:\.\d+)?)")


PERF_KEY_MAP = {
    "Cycles": "cycles",
    "S0 commits": "s0_commits",
    "S1 commits": "s1_commits",
    "Total insts": "total_commits",
    "CPI": "cpi",
    "Dual-issue %": "dual_issue_percent",
    "IF accepts": "if_accepts",
    "S1 accepted": "s1_accepted",
    "S1 committed": "s1_committed",
    "S1 blocked": "s1_blocked_total",
    "Load-use": "load_use_stall_cycles",
    "DCache miss": "dcache_stall_cycles",
    "MUL/DIV wait": "muldiv_wait_cycles",
    "ID RAW stall cycles": "id_raw_stall_cycles",
    "Same-pair RAW lost slots": "same_pair_raw_lost_slots",
    "Total branch": "branch_total",
    "Mispredicts": "branch_mispredicts",
    "NLP redirects": "nlp_redirects",
}


def parse_result_line(lines: Iterable[str]) -> Dict[str, Any]:
    """Return simulator stop status from the first stable result line."""
    result: Dict[str, Any] = {
        "status": "UNKNOWN",
        "stop_reason": "UNKNOWN",
        "cycles": None,
    }

    for line in lines:
        match = RESULT_RE.match(line.strip())
        if not match:
            continue

        status, rest, cycles = match.groups()
        result["status"] = status
        result["cycles"] = int(cycles) if cycles is not None else None

        if status == "PASS":
            result["stop_reason"] = "LED_PASS"
        elif status == "DONE":
            if "stop_pc" in rest:
                result["stop_reason"] = "DONE_PC"
            elif "commits" in rest:
                result["stop_reason"] = "COMMIT_LIMIT"
            else:
                result["stop_reason"] = "DONE"
        elif status == "TIMEOUT":
            result["stop_reason"] = "WATCHDOG" if "no pipeline progress" in rest else "TIMEOUT"
        elif status == "FAIL":
            result["stop_reason"] = "PC_GUARD" if "PC_OUT_OF_RANGE" in rest else "FAIL"

        stop_match = STOP_PC_RE.search(rest)
        if stop_match:
            stop_pc, commits, first_led, last_led, led_writes = stop_match.groups()
            result.update(
                {
                    "stop_pc": f"0x{int(stop_pc, 16):08x}",
                    "total_commits": int(commits),
                    "first_led": f"0x{int(first_led, 16):08x}",
                    "last_led": f"0x{int(last_led, 16):08x}",
                    "led_writes": int(led_writes),
                }
            )
        else:
            led_match = LED_SUMMARY_RE.search(rest)
            if led_match:
                first_led, last_led, led_writes = led_match.groups()
                result.update(
                    {
                        "first_led": f"0x{int(first_led, 16):08x}",
                        "last_led": f"0x{int(last_led, 16):08x}",
                        "led_writes": int(led_writes),
                    }
                )

        commits_match = COMMITS_RE.search(rest)
        if commits_match and "total_commits" not in result:
            result["total_commits"] = int(commits_match.group(1))
        commit_count_match = COMMIT_COUNT_RE.search(rest)
        if commit_count_match and "total_commits" not in result:
            result["total_commits"] = int(commit_count_match.group(1))

        pc_match = PC_SUMMARY_RE.search(rest)
        if pc_match:
            pc, last_wb0_pc, last_wb1_pc = pc_match.groups()
            result.update(
                {
                    "pc": f"0x{int(pc, 16):08x}",
                    "last_wb0_pc": f"0x{int(last_wb0_pc, 16):08x}",
                    "last_wb1_pc": f"0x{int(last_wb1_pc, 16):08x}",
                }
            )

        return result

    return result


def _normalize_perf_key(raw_key: str) -> Optional[str]:
    key = " ".join(raw_key.strip().split())
    return PERF_KEY_MAP.get(key)


def parse_perf_lines(lines: Iterable[str]) -> Dict[str, Any]:
    """Parse the existing [PERF] report into stable summary fields."""
    perf: Dict[str, Any] = {}

    for line in lines:
        if not line.startswith("[PERF]"):
            continue

        key_match = PERF_FLOAT_RE.match(line.strip())
        if not key_match:
            continue

        raw_key, raw_value = key_match.groups()
        key = _normalize_perf_key(raw_key)
        if key is None:
            continue

        if "." in raw_value:
            value: Any = float(raw_value)
        else:
            value = int(raw_value)
        perf[key] = value

    return perf
