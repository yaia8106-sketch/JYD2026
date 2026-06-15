#!/usr/bin/env python3
"""Parse run_perf.sh logs into stable CSV/JSON summaries."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from typing import Any


SUMMARY_COLUMNS = [
    "test",
    "status",
    "sim_exit",
    "cycles",
    "total_insts",
    "s0_commits",
    "s1_commits",
    "cpi",
    "ipc",
    "dual_issue_pct",
    "cpi_stack_retire",
    "cpi_stack_redirect",
    "cpi_stack_dcache",
    "cpi_stack_muldiv",
    "cpi_stack_raw_not_ready",
    "cpi_stack_raw_ready_no_fwd",
    "cpi_stack_frontend_empty",
    "cpi_stack_other_no_commit",
    "cpi_stack_total",
    "load_use",
    "repair_wait",
    "jalr_ex_wait",
    "s1_wb_wait",
    "dcache_miss_stall",
    "mmio_hazard",
    "muldiv_wait",
    "lsu_cache_load",
    "lsu_cache_store",
    "lsu_mmio_load",
    "lsu_mmio_store",
    "dc_requests",
    "dc_load_requests",
    "dc_store_requests",
    "dc_hits",
    "dc_load_hits",
    "dc_store_hits",
    "dc_hit_rate_pct",
    "dc_misses",
    "dc_load_misses",
    "dc_store_misses",
    "dc_miss_rate_pct",
    "dc_refill_cycles",
    "dc_refill_words",
    "dc_refill_aborts",
    "dc_sb_enqueues",
    "dc_sb_drains",
    "dc_sb_block_cycles",
    "dc_sb_conflicts",
    "dc_store_forward_hits",
    "id_raw_stall",
    "raw_not_ready",
    "raw_ready_no_fwd",
    "raw_unclassified",
    "total_branch",
    "mispredicts",
    "mispredict_rate_pct",
    "jcall_redirects",
    "abtb_direct_lookup",
    "abtb_direct_steer",
    "abtb_direct_bank0",
    "abtb_direct_bank1",
    "abtb_direct_correct",
    "abtb_direct_redirect",
    "abtb_direct_target_miss",
    "stage1_sequential",
    "stage1_abtb_owned",
    "stage1_branch_owned_nt",
    "stage1_pht_confirmed",
    "stage1_pht_abtb_branch_hit",
    "stage1_pht_pred_taken",
    "stage1_pht_pred_not_taken",
    "stage1_pht_correct",
    "stage1_pht_wrong",
    "stage1_pht_bank0",
    "stage1_pht_bank1",
    "pred_s0_resolved",
    "pred_s0_branch",
    "pred_s0_jal",
    "pred_s0_jalr",
    "pred_s1_resolved",
    "pred_s1_branch",
    "pred_s1_jal",
    "pred_s0_pred_taken",
    "pred_s0_actual_taken",
    "pred_s0_mispredict",
    "pred_s0_dir_to_taken",
    "pred_s0_dir_to_fallthrough",
    "pred_s0_target_wrong",
    "pred_s1_pred_taken",
    "pred_s1_actual_taken",
    "pred_s1_dir_wrong",
    "pred_s1_target_wrong",
    "pred_s1_redirect",
    "pred_train_total",
    "pred_train_s0",
    "pred_train_s1",
    "pred_train_branch",
    "pred_train_jal",
    "pred_train_jalr",
    "fe_bp0_fire",
    "fe_bp0_ftq_full",
    "fe_bp0_fq_credit_block",
    "fe_redirect_total",
    "fe_redirect_ex",
    "fe_f0_valid",
    "fe_f0_accept",
    "fe_f0_epoch_miss",
    "fe_f0_ex_kill",
    "fe_f0_enq0",
    "fe_f0_enq1",
    "fe_f0_enq_none",
    "fe_f0_kill_slot0",
    "fe_if_accept",
    "fe_if_accept_dual",
    "fe_if_accept_single",
    "fe_if_empty",
    "fe_fq_nonempty",
    "fe_fq_pair_ready",
    "fe_fq_avg",
    "fe_ftq_avg",
    "fe_fq_sum",
    "fe_ftq_sum",
    "fetch_valid",
    "raw_dep",
    "inst1_not_alu",
    "inst0_jump",
    "not_seq_fetch",
    "dual_issued",
    "if_accepts",
    "s1_accepted",
    "s1_committed_if_pct",
    "s1_blocked",
]

COMPARE_METRICS = [
    "cycles",
    "total_insts",
    "cpi",
    "ipc",
    "dual_issue_pct",
    "cpi_stack_redirect",
    "cpi_stack_dcache",
    "cpi_stack_muldiv",
    "cpi_stack_raw_not_ready",
    "cpi_stack_raw_ready_no_fwd",
    "cpi_stack_frontend_empty",
    "cpi_stack_other_no_commit",
    "dcache_miss_stall",
    "dc_requests",
    "dc_hits",
    "dc_misses",
    "dc_hit_rate_pct",
    "dc_refill_cycles",
    "dc_sb_block_cycles",
    "dc_sb_conflicts",
    "mispredicts",
    "mispredict_rate_pct",
    "jcall_redirects",
    "abtb_direct_lookup",
    "abtb_direct_steer",
    "abtb_direct_bank0",
    "abtb_direct_bank1",
    "abtb_direct_correct",
    "abtb_direct_redirect",
    "abtb_direct_target_miss",
    "stage1_sequential",
    "stage1_abtb_owned",
    "stage1_branch_owned_nt",
    "stage1_pht_confirmed",
    "stage1_pht_abtb_branch_hit",
    "stage1_pht_pred_taken",
    "stage1_pht_pred_not_taken",
    "stage1_pht_correct",
    "stage1_pht_wrong",
    "stage1_pht_bank0",
    "stage1_pht_bank1",
    "pred_s0_mispredict",
    "pred_s0_dir_to_taken",
    "pred_s0_dir_to_fallthrough",
    "pred_s0_target_wrong",
    "pred_s1_redirect",
    "fe_bp0_ftq_full",
    "fe_bp0_fq_credit_block",
    "fe_f0_ex_kill",
    "fe_if_empty",
    "fe_fq_pair_ready",
    "fe_fq_avg",
    "fe_ftq_avg",
]

INT_PATTERNS = [
    ("perf_cycles", r"^Cycles:\s+(\d+)"),
    ("s0_commits", r"^S0 commits:\s+(\d+)"),
    ("s1_commits", r"^S1 commits:\s+(\d+)"),
    ("total_insts", r"^Total insts:\s+(\d+)"),
    ("load_use", r"^Load-use:\s+(\d+)"),
    ("repair_wait", r"^Repair wait:\s+(\d+)"),
    ("jalr_ex_wait", r"^JALR EX wait:\s+(\d+)"),
    ("s1_wb_wait", r"^S1-WB wait:\s+(\d+)"),
    ("dcache_miss_stall", r"^DCache miss:\s+(\d+)"),
    ("mmio_hazard", r"^MMIO hazard:\s+(\d+)"),
    ("muldiv_wait", r"^MUL/DIV wait:\s+(\d+)"),
    ("id_raw_stall", r"^ID RAW stall cycles:\s+(\d+)"),
    ("raw_not_ready", r"^Not-ready RAW cycles:\s+(\d+)"),
    ("raw_ready_no_fwd", r"^Ready-no-forward RAW cycles:\s+(\d+)"),
    ("raw_unclassified", r"^Unclassified ID RAW stalls:\s+(\d+)"),
    ("same_pair_raw_lost_slots", r"^Same-pair RAW lost slots:\s+(\d+)"),
    ("total_branch", r"^Total branch:\s+(\d+)"),
    ("mispredicts", r"^Mispredicts:\s+(\d+)"),
    ("jcall_redirects", r"^J/CALL redirects:\s+(\d+)"),
    ("fetch_valid", r"^Fetch valid:\s+(\d+)"),
    ("pc2_fetch", r"^PC\[2\]=1 fetch:\s+(\d+)"),
    ("raw_dep", r"^RAW dep:\s+(\d+)"),
    ("inst1_not_alu", r"^inst1 not ALU:\s+(\d+)"),
    ("inst0_jump", r"^inst0 JAL/JR:\s+(\d+)"),
    ("not_seq_fetch", r"^Not seq fetch:\s+(\d+)"),
    ("dual_issued", r"^Dual issued:\s+(\d+)"),
    ("if_accepts", r"^IF accepts:\s+(\d+)"),
    ("s1_accepted", r"^S1 accepted:\s+(\d+)"),
    ("s1_blocked", r"^S1 blocked:\s+(\d+)"),
    ("if_block_not_seq", r"^not seq:\s+(\d+)"),
    ("if_block_raw", r"^RAW:\s+(\d+)"),
    ("if_block_s0_muldiv", r"^S0 MULDIV:\s+(\d+)"),
    ("if_block_s0_jump", r"^S0 jump/sys:\s+(\d+)"),
    ("if_block_s1_policy", r"^S1 LSU/branch/JAL blocked by S0 policy:\s+(\d+)"),
    ("if_block_s1_unsupported", r"^S1 unsupported:\s+(\d+)"),
    ("if_block_other", r"^other:\s+(\d+)"),
    ("skip_inst0", r"^skip_inst0=1:\s+(\d+)"),
    ("skip_and_pred_taken", r"^skip\+pred_taken:\s+(\d+)"),
    ("predict_dual_errors", r"^predict_dual errors:\s+(\d+)"),
]

FLOAT_PATTERNS = [
    ("cpi", r"^CPI:\s+([0-9.]+)"),
    ("dual_issue_pct", r"^Dual-issue %:\s+([0-9.]+)%"),
]


def parse_value_pairs(text: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for key, raw_value in re.findall(r"([A-Za-z0-9_()/-]+)=([0-9]+)", text):
        clean_key = (
            key.lower()
            .replace("(", "_")
            .replace(")", "")
            .replace("/", "_")
            .replace("-", "_")
        )
        values[clean_key] = int(raw_value)
    return values


def parse_status_line(line: str, metrics: dict[str, Any]) -> None:
    skip_match = re.match(r"^\[SKIP\]\s+(\S+)", line)
    if skip_match:
        metrics["test"] = skip_match.group(1)
        metrics["status"] = "SKIP"
        return

    match = re.match(r"^\[(PASS|FAIL|TIMEOUT|DONE)\]\s+(\S+)\s*(.*)$", line)
    if not match:
        return

    metrics["status"] = match.group(1)
    metrics["test"] = match.group(2)
    rest = match.group(3)

    cycle_match = re.search(r"\((>?)(\d+) cycles\)", line)
    if cycle_match:
        metrics["status_cycles_over_limit"] = cycle_match.group(1) == ">"
        metrics["status_cycles"] = int(cycle_match.group(2))

    for key in [
        "commits",
        "led_writes",
    ]:
        value_match = re.search(rf"{key}=(\d+)", rest)
        if value_match:
            metrics[f"status_{key}"] = int(value_match.group(1))

    for key in [
        "first_led",
        "last_led",
        "pc",
        "last_wb0_pc",
        "last_wb1_pc",
    ]:
        value_match = re.search(rf"{key}=0x([0-9a-fA-F]+)", rest)
        if value_match:
            metrics[f"status_{key}"] = f"0x{value_match.group(1).lower()}"


def parse_perf_payload(payload: str, metrics: dict[str, Any]) -> None:
    match = re.search(r"^Mispredicts:\s+(\d+)\s+\(([0-9.]+)%\)", payload)
    if match:
        metrics["mispredicts"] = int(match.group(1))
        metrics["mispredict_rate_pct"] = float(match.group(2))
        return

    match = re.search(r"^S1 committed:\s+\d+\s+\(([0-9.]+)% of S1 accepts\)", payload)
    if match:
        metrics["s1_committed_if_pct"] = float(match.group(1))
        return

    for key, pattern in INT_PATTERNS:
        match = re.search(pattern, payload)
        if match:
            metrics[key] = int(match.group(1))
            return

    for key, pattern in FLOAT_PATTERNS:
        match = re.search(pattern, payload)
        if match:
            metrics[key] = float(match.group(1))
            return

    if payload.startswith("CPI stack:"):
        values = parse_value_pairs(payload)
        metrics["cpi_stack_retire"] = values.get("retire", 0)
        metrics["cpi_stack_redirect"] = values.get("redirect", 0)
        metrics["cpi_stack_dcache"] = values.get("dcache", 0)
        metrics["cpi_stack_muldiv"] = values.get("muldiv", 0)
        metrics["cpi_stack_raw_not_ready"] = values.get("raw_not_ready", 0)
        metrics["cpi_stack_raw_ready_no_fwd"] = values.get("raw_ready_no_fwd", 0)
        metrics["cpi_stack_frontend_empty"] = values.get("frontend_empty", 0)
        metrics["cpi_stack_other_no_commit"] = values.get("other_no_commit", 0)
        metrics["cpi_stack_total"] = values.get("total", 0)
        return

    if payload.startswith("S1 accepted type:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"s1_accept_type_{key}"] = value
        return

    if payload.startswith("S0 IF-accept mix:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"s0_if_accept_mix_{key}"] = value
        return

    if payload.startswith("S1 valid cycles:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"s1_valid_cycles_{key}"] = value
        return

    match = re.search(r"^Requests:\s+(\d+)\s+loads=(\d+)\s+stores=(\d+)", payload)
    if match:
        metrics["dc_requests"] = int(match.group(1))
        metrics["dc_load_requests"] = int(match.group(2))
        metrics["dc_store_requests"] = int(match.group(3))
        return

    match = re.search(r"^Hits:\s+(\d+)\s+load=(\d+)\s+store=(\d+)\s+\(([0-9.]+)%\)", payload)
    if match:
        metrics["dc_hits"] = int(match.group(1))
        metrics["dc_load_hits"] = int(match.group(2))
        metrics["dc_store_hits"] = int(match.group(3))
        metrics["dc_hit_rate_pct"] = float(match.group(4))
        return

    match = re.search(r"^Misses:\s+(\d+)\s+load=(\d+)\s+store=(\d+)\s+\(([0-9.]+)%\)", payload)
    if match:
        metrics["dc_misses"] = int(match.group(1))
        metrics["dc_load_misses"] = int(match.group(2))
        metrics["dc_store_misses"] = int(match.group(3))
        metrics["dc_miss_rate_pct"] = float(match.group(4))
        return

    match = re.search(r"^Refill cycles:\s+(\d+)\s+words=(\d+)\s+aborts=(\d+)", payload)
    if match:
        metrics["dc_refill_cycles"] = int(match.group(1))
        metrics["dc_refill_words"] = int(match.group(2))
        metrics["dc_refill_aborts"] = int(match.group(3))
        return

    if payload.startswith("Store buffer:"):
        values = parse_value_pairs(payload)
        metrics["dc_sb_enqueues"] = values.get("enq", 0)
        metrics["dc_sb_drains"] = values.get("drain", 0)
        metrics["dc_sb_block_cycles"] = values.get("block", 0)
        metrics["dc_sb_conflicts"] = values.get("conflict", 0)
        metrics["dc_store_forward_hits"] = values.get("fwd", 0)
        return

    if payload.startswith("LSU complete:"):
        values = parse_value_pairs(payload)
        metrics["lsu_cache_load"] = values.get("cache_load", 0)
        metrics["lsu_cache_store"] = values.get("cache_store", 0)
        metrics["lsu_mmio_load"] = values.get("mmio_load", 0)
        metrics["lsu_mmio_store"] = values.get("mmio_store", 0)
        return

    if payload.startswith("Pred resolved:"):
        values = parse_value_pairs(payload)
        metrics["pred_s0_resolved"] = values.get("s0", 0)
        metrics["pred_s0_branch"] = values.get("branch", 0)
        metrics["pred_s0_jal"] = values.get("jal", 0)
        metrics["pred_s0_jalr"] = values.get("jalr", 0)
        metrics["pred_s1_resolved"] = values.get("s1", 0)
        metrics["pred_s1_branch"] = values.get("s1_branch", 0)
        metrics["pred_s1_jal"] = values.get("s1_jal", 0)
        return

    if payload.startswith("Pred s0 pred:"):
        values = parse_value_pairs(payload)
        metrics["pred_s0_pred_taken"] = values.get("pred_taken", 0)
        metrics["pred_s0_actual_taken"] = values.get("actual_taken", 0)
        return

    if payload.startswith("Pred s0 miss:"):
        values = parse_value_pairs(payload)
        metrics["pred_s0_mispredict"] = values.get("total", 0)
        metrics["pred_s0_dir_to_taken"] = values.get("dir_to_taken", 0)
        metrics["pred_s0_dir_to_fallthrough"] = values.get("dir_to_fallthrough", 0)
        metrics["pred_s0_target_wrong"] = values.get("target", 0)
        return

    if payload.startswith("Pred s1 pred:"):
        values = parse_value_pairs(payload)
        metrics["pred_s1_pred_taken"] = values.get("pred_taken", 0)
        metrics["pred_s1_actual_taken"] = values.get("actual_taken", 0)
        metrics["pred_s1_dir_wrong"] = values.get("dir_wrong", 0)
        metrics["pred_s1_target_wrong"] = values.get("target_wrong", 0)
        metrics["pred_s1_redirect"] = values.get("redirect", 0)
        return

    if payload.startswith("Pred training:"):
        values = parse_value_pairs(payload)
        metrics["pred_train_total"] = values.get("total", 0)
        metrics["pred_train_s0"] = values.get("s0", 0)
        metrics["pred_train_s1"] = values.get("s1", 0)
        metrics["pred_train_branch"] = values.get("branch", 0)
        metrics["pred_train_jal"] = values.get("jal", 0)
        metrics["pred_train_jalr"] = values.get("jalr", 0)
        return

    if payload.startswith("FE BP0:"):
        values = parse_value_pairs(payload)
        metrics["fe_bp0_fire"] = values.get("fire", 0)
        metrics["fe_bp0_ftq_full"] = values.get("ftq_full", 0)
        metrics["fe_bp0_fq_credit_block"] = values.get("fq_credit_block", 0)
        return

    if payload.startswith("FE redirect:"):
        values = parse_value_pairs(payload)
        metrics["fe_redirect_total"] = values.get("total", 0)
        metrics["fe_redirect_ex"] = values.get("ex", 0)
        return

    if payload.startswith("FE F0:"):
        values = parse_value_pairs(payload)
        metrics["fe_f0_valid"] = values.get("valid", 0)
        metrics["fe_f0_accept"] = values.get("accept", 0)
        metrics["fe_f0_epoch_miss"] = values.get("epoch_miss", 0)
        metrics["fe_f0_ex_kill"] = values.get("ex_kill", 0)
        metrics["fe_f0_enq0"] = values.get("enq0", 0)
        metrics["fe_f0_enq1"] = values.get("enq1", 0)
        metrics["fe_f0_enq_none"] = values.get("enq_none", 0)
        metrics["fe_f0_kill_slot0"] = values.get("kill_slot0", 0)
        return

    if payload.startswith("FE IF:"):
        values = parse_value_pairs(payload)
        metrics["fe_if_accept"] = values.get("accept", 0)
        metrics["fe_if_accept_dual"] = values.get("dual", 0)
        metrics["fe_if_accept_single"] = values.get("single", 0)
        metrics["fe_if_empty"] = values.get("empty", 0)
        metrics["fe_fq_nonempty"] = values.get("fq_nonempty", 0)
        metrics["fe_fq_pair_ready"] = values.get("fq_pair_ready", 0)
        return

    match = re.search(
        r"^FE occupancy:\s+fq_avg=([0-9.]+)\s+ftq_avg=([0-9.]+)\s+fq_sum=(\d+)\s+ftq_sum=(\d+)",
        payload,
    )
    if match:
        metrics["fe_fq_avg"] = float(match.group(1))
        metrics["fe_ftq_avg"] = float(match.group(2))
        metrics["fe_fq_sum"] = int(match.group(3))
        metrics["fe_ftq_sum"] = int(match.group(4))
        return

    if payload.startswith("ABTB direct:"):
        values = parse_value_pairs(payload)
        metrics["abtb_direct_lookup"] = values.get("lookup", 0)
        metrics["abtb_direct_steer"] = values.get("steer", 0)
        metrics["abtb_direct_bank0"] = values.get("bank0", 0)
        metrics["abtb_direct_bank1"] = values.get("bank1", 0)
        metrics["abtb_direct_correct"] = values.get("correct", 0)
        metrics["abtb_direct_redirect"] = values.get("redirect", 0)
        metrics["abtb_direct_target_miss"] = values.get("target_miss", 0)
        metrics["stage1_sequential"] = values.get("stage1_sequential", 0)
        metrics["stage1_abtb_owned"] = values.get("stage1_owned", 0)
        metrics["stage1_branch_owned_nt"] = values.get("owned_nt", 0)
        return

    if payload.startswith("Stage1 PHT:"):
        values = parse_value_pairs(payload)
        metrics["stage1_pht_confirmed"] = values.get("confirmed", 0)
        metrics["stage1_pht_abtb_branch_hit"] = values.get(
            "abtb_branch_hit", 0
        )
        metrics["stage1_pht_pred_taken"] = values.get("pred_taken", 0)
        metrics["stage1_pht_pred_not_taken"] = values.get("pred_nt", 0)
        metrics["stage1_pht_correct"] = values.get("correct", 0)
        metrics["stage1_pht_wrong"] = values.get("wrong", 0)
        metrics["stage1_pht_bank0"] = values.get("bank0", 0)
        metrics["stage1_pht_bank1"] = values.get("bank1", 0)
        return


def finalize_metrics(metrics: dict[str, Any], fallback_test: str) -> dict[str, Any]:
    metrics.setdefault("test", fallback_test)
    metrics.setdefault("status", "UNKNOWN")

    cycles = metrics.get("perf_cycles", metrics.get("status_cycles"))
    if cycles is not None:
        metrics["cycles"] = int(cycles)

    total_insts = metrics.get("total_insts")
    if total_insts is None:
        s0 = metrics.get("s0_commits")
        s1 = metrics.get("s1_commits")
        if s0 is not None or s1 is not None:
            total_insts = int(s0 or 0) + int(s1 or 0)
            metrics["total_insts"] = total_insts

    if cycles and total_insts:
        metrics["ipc"] = float(total_insts) / float(cycles)
        metrics.setdefault("cpi", float(cycles) / float(total_insts))

    return metrics


def parse_log(path: Path) -> dict[str, Any]:
    metrics: dict[str, Any] = {"log": str(path)}
    fallback_test = path.stem

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            parse_status_line(line, metrics)
            if line.startswith("[PERF]"):
                payload = line[len("[PERF]") :].strip()
                parse_perf_payload(payload, metrics)
            elif line.startswith("[INFO] sim_exit="):
                try:
                    metrics["sim_exit"] = int(line.rsplit("=", 1)[1])
                except ValueError:
                    pass
            elif line.startswith("[INFO] vvp_exit="):
                try:
                    metrics["sim_exit"] = int(line.rsplit("=", 1)[1])
                except ValueError:
                    pass

    return finalize_metrics(metrics, fallback_test)


def write_csv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in columns})


def load_summary(path: Path) -> dict[str, dict[str, Any]]:
    if path.is_dir():
        path = path / "summary.csv"
    if not path.exists():
        raise FileNotFoundError(f"baseline summary not found: {path}")

    rows: dict[str, dict[str, Any]] = {}
    with path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("test"):
                rows[row["test"]] = row
    return rows


def to_float(value: Any) -> float | None:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def compare_rows(
    baseline: dict[str, dict[str, Any]],
    current: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for row in current:
        test = row.get("test")
        if not test or test not in baseline:
            continue
        old = baseline[test]
        out: dict[str, Any] = {
            "test": test,
            "old_status": old.get("status", ""),
            "new_status": row.get("status", ""),
        }
        for metric in COMPARE_METRICS:
            old_value = to_float(old.get(metric))
            new_value = to_float(row.get(metric))
            out[f"old_{metric}"] = old.get(metric, "")
            out[f"new_{metric}"] = row.get(metric, "")
            if old_value is not None and new_value is not None:
                delta = new_value - old_value
                out[f"{metric}_delta"] = delta
                if old_value != 0:
                    out[f"{metric}_delta_pct"] = 100.0 * delta / old_value
        rows.append(out)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True, help="run_perf output directory")
    parser.add_argument(
        "--baseline",
        help="baseline run directory or summary.csv to compare against",
    )
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    log_dir = run_dir / "logs"
    if not log_dir.is_dir():
        print(f"ERROR: log directory not found: {log_dir}", file=sys.stderr)
        return 1

    rows = [parse_log(path) for path in sorted(log_dir.glob("*.log"))]
    rows.sort(key=lambda item: str(item.get("test", "")))

    write_csv(run_dir / "summary.csv", rows, SUMMARY_COLUMNS)
    with (run_dir / "summary.json").open("w", encoding="utf-8") as handle:
        json.dump(rows, handle, indent=2, sort_keys=True)
        handle.write("\n")

    if args.baseline:
        compare = compare_rows(load_summary(Path(args.baseline)), rows)
        compare_columns = ["test", "old_status", "new_status"]
        for metric in COMPARE_METRICS:
            compare_columns += [
                f"old_{metric}",
                f"new_{metric}",
                f"{metric}_delta",
                f"{metric}_delta_pct",
            ]
        write_csv(run_dir / "compare.csv", compare, compare_columns)

    status_counts: dict[str, int] = {}
    for row in rows:
        status = str(row.get("status", "UNKNOWN"))
        status_counts[status] = status_counts.get(status, 0) + 1
    print("[INFO] Parsed perf logs:", ", ".join(f"{k}={v}" for k, v in sorted(status_counts.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
