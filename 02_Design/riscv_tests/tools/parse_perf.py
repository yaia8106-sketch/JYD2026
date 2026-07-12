#!/usr/bin/env python3
"""Parse performance logs into stable CSV/JSON summaries."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 5
FULL_RUN_REASONS = {"stop_pc", "tohost_pass"}
OK_FULL_STATUSES = {"PASS", "DONE"}

SUMMARY_COLUMNS = [
    "schema_version",
    "test",
    "status",
    "completion_reason",
    "is_full_run",
    "consistency_error_count",
    "log_has_error",
    "sim_exit",
    "status_cycles",
    "status_commits",
    "status_pc",
    "status_stop_pc",
    "status_cycle_limit",
    "cycles",
    "total_insts",
    "s0_commits",
    "s1_commits",
    "cpi",
    "ipc",
    "dual_issue_pct",
    "commit0_cycles",
    "commit1_cycles",
    "commit2_cycles",
    "commit_cycle_total",
    "ideal_slots",
    "retired_slots",
    "lost_slots",
    "lost_no_commit_slots",
    "lost_single_issue_slots",
    "cpi_stack_retire",
    "cpi_stack_redirect",
    "cpi_stack_dcache",
    "cpi_stack_muldiv",
    "cpi_stack_raw_not_ready",
    "cpi_stack_raw_ready_no_fwd",
    "cpi_stack_frontend_empty",
    "cpi_stack_other_no_commit",
    "cpi_stack_total",
    "other_id_not_ready",
    "other_id_downstream",
    "other_ex_not_ready",
    "other_ex_downstream",
    "other_mem_not_ready",
    "other_mem_downstream",
    "other_flush_recovery",
    "other_frontend_backpressure",
    "other_pipeline_fill_drain",
    "other_unknown",
    "other_breakdown_total",
    "other_original",
    "other_mismatch",
    "other_occ_0000",
    "other_occ_0001",
    "other_occ_0010",
    "other_occ_0011",
    "other_occ_0100",
    "other_occ_0101",
    "other_occ_0110",
    "other_occ_0111",
    "other_occ_1000",
    "other_occ_1001",
    "other_occ_1010",
    "other_occ_1011",
    "other_occ_1100",
    "other_occ_1101",
    "other_occ_1110",
    "other_occ_1111",
    "load_use",
    "repair_wait",
    "jalr_ex_wait",
    "s1_wb_wait",
    "dcache_miss_stall",
    "mmio_hazard",
    "muldiv_wait",
    "muldiv_issued_mul",
    "muldiv_issued_mulh",
    "muldiv_issued_mulhsu",
    "muldiv_issued_mulhu",
    "muldiv_issued_div",
    "muldiv_issued_divu",
    "muldiv_issued_rem",
    "muldiv_issued_remu",
    "muldiv_issued_total",
    "muldiv_wait_mul",
    "muldiv_wait_mulh",
    "muldiv_wait_mulhsu",
    "muldiv_wait_mulhu",
    "muldiv_wait_div",
    "muldiv_wait_divu",
    "muldiv_wait_rem",
    "muldiv_wait_remu",
    "muldiv_wait_total",
    "muldiv_wait_original",
    "muldiv_wait_mismatch",
    "muldiv_latency_complete",
    "muldiv_latency_abort",
    "muldiv_latency_lat1",
    "muldiv_latency_lat2",
    "muldiv_latency_lat3_4",
    "muldiv_latency_lat5_8",
    "muldiv_latency_lat9_16",
    "muldiv_latency_lat17plus",
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
    "dc_primary_refill_starts",
    "dc_primary_refill_completes",
    "dc_primary_refill_aborts",
    "dc_primary_refill_stall_cycles",
    "dc_primary_refill_avg",
    "dc_primary_refill_lat1",
    "dc_primary_refill_lat2",
    "dc_primary_refill_lat3",
    "dc_primary_refill_lat4plus",
    "dc_sb_enqueues",
    "dc_sb_drains",
    "dc_sb_block_cycles",
    "dc_sb_conflicts",
    "dc_store_forward_hits",
    "dc_miss_buffer_hits",
    "dc_drain_req_cycles",
    "dc_drain_resp_cycles",
    "dc_drain_req_stall",
    "dc_drain_resp_stall",
    "dc_drain_stall_total",
    "dc_drain_hidden",
    "dc_drain_stall_load",
    "dc_drain_stall_store",
    "dc_drain_stall_other",
    "dc_drain_stall_kind_total",
    "dc_drain_stall_mismatch",
    "dc_drain_probe_pending",
    "dc_drain_probe_read_overlap",
    "dc_drain_probe_same_word",
    "dc_drain_probe_push_overlap",
    "dc_stall_state_idle",
    "dc_stall_state_refill_req",
    "dc_stall_state_refill_data",
    "dc_stall_state_refill_drop",
    "dc_stall_state_done",
    "dc_stall_state_sb_req",
    "dc_stall_state_sb_resp",
    "dc_stall_state_other",
    "dc_stall_state_total",
    "dc_stall_state_original",
    "dc_stall_state_mismatch",
    "dc_stall_req_load",
    "dc_stall_req_store",
    "dc_stall_req_other",
    "dc_stall_req_tag_hit",
    "dc_stall_req_tag_miss",
    "dc_drain_req_stall",
    "dc_drain_resp_stall",
    "dc_drain_stall_total",
    "dc_drain_probe_same_word",
    "dc_drain_probe_push_overlap",
    "dc_stall_req_sb_occ0",
    "dc_stall_req_sb_occ1",
    "dc_stall_req_sb_occ2",
    "dc_stall_req_total",
    "dc_stall_req_original",
    "dc_stall_req_mismatch",
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
    "pair_block_no_candidate",
    "pair_block_noncontiguous",
    "pair_block_s0_pred_taken",
    "pair_block_s0_force_single",
    "pair_block_s1_force_single",
    "pair_block_raw",
    "pair_block_s0_unsupported",
    "pair_block_s1_unsupported",
    "pair_block_both_lsu",
    "pair_block_both_cfi",
    "pair_block_stored_other",
    "pair_block_total",
    "pair_block_original",
    "pair_block_mismatch",
    "pair_raw_prod_alu",
    "pair_raw_prod_load",
    "pair_raw_prod_cfi",
    "pair_raw_prod_other",
    "pair_raw_prod_total",
    "pair_raw_cons_alu",
    "pair_raw_cons_load",
    "pair_raw_cons_store",
    "pair_raw_cons_branch",
    "pair_raw_cons_jalr",
    "pair_raw_cons_other",
    "pair_raw_alu_alu",
    "pair_raw_alu_load",
    "pair_raw_alu_store",
    "pair_raw_alu_branch",
    "pair_raw_alu_jalr",
    "pair_raw_alu_other",
    "pair_raw_load_alu",
    "pair_raw_load_load",
    "pair_raw_load_store",
    "pair_raw_load_branch",
    "pair_raw_load_jalr",
    "pair_raw_load_other",
    "pair_raw_store_addr",
    "pair_raw_store_data",
    "pair_raw_store_alu_addr",
    "pair_raw_store_alu_data",
]

COMPARE_METRICS = [
    "cycles",
    "total_insts",
    "cpi",
    "ipc",
    "dual_issue_pct",
    "commit0_cycles",
    "commit1_cycles",
    "commit2_cycles",
    "ideal_slots",
    "retired_slots",
    "lost_slots",
    "lost_no_commit_slots",
    "lost_single_issue_slots",
    "cpi_stack_redirect",
    "cpi_stack_dcache",
    "cpi_stack_muldiv",
    "cpi_stack_raw_not_ready",
    "cpi_stack_raw_ready_no_fwd",
    "cpi_stack_frontend_empty",
    "cpi_stack_other_no_commit",
    "other_id_not_ready",
    "other_id_downstream",
    "other_ex_not_ready",
    "other_ex_downstream",
    "other_mem_not_ready",
    "other_mem_downstream",
    "other_flush_recovery",
    "other_frontend_backpressure",
    "other_pipeline_fill_drain",
    "other_unknown",
    "dcache_miss_stall",
    "dc_requests",
    "dc_hits",
    "dc_misses",
    "dc_hit_rate_pct",
    "dc_refill_cycles",
    "dc_primary_refill_starts",
    "dc_primary_refill_completes",
    "dc_primary_refill_aborts",
    "dc_primary_refill_stall_cycles",
    "dc_primary_refill_avg",
    "dc_primary_refill_lat1",
    "dc_primary_refill_lat2",
    "dc_primary_refill_lat3",
    "dc_primary_refill_lat4plus",
    "dc_sb_block_cycles",
    "dc_sb_conflicts",
    "dc_stall_state_refill_req",
    "dc_stall_state_refill_data",
    "dc_stall_state_sb_req",
    "dc_stall_state_sb_resp",
    "dc_stall_req_load",
    "dc_stall_req_store",
    "dc_stall_req_tag_hit",
    "dc_stall_req_tag_miss",
    "muldiv_issued_total",
    "muldiv_wait_total",
    "muldiv_latency_lat1",
    "muldiv_latency_lat2",
    "muldiv_latency_lat17plus",
    "pair_block_no_candidate",
    "pair_block_raw",
    "pair_block_both_lsu",
    "pair_block_both_cfi",
    "pair_raw_store_alu_data",
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
    for key, raw_value in re.findall(r"([A-Za-z0-9_()/-]+)=(-?[0-9]+)", text):
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
        metrics["completion_reason"] = "skip"
        return

    match = re.match(r"^\[(PASS|FAIL|TIMEOUT|DONE|SAMPLED)\]\s+(\S+)\s*(.*)$", line)
    if not match:
        return

    metrics["status"] = match.group(1)
    metrics["test"] = match.group(2)
    rest = match.group(3)

    if "reached stop_pc" in rest:
        metrics["completion_reason"] = "stop_pc"
    elif "reached cycle_limit=" in rest:
        metrics["completion_reason"] = "cycle_limit"
    elif re.search(r"reached\s+\d+\s+commits", rest):
        metrics["completion_reason"] = "commit_limit"
    elif "PC_OUT_OF_RANGE" in rest:
        metrics["completion_reason"] = "pc_guard"
    elif "no pipeline progress" in rest:
        metrics["completion_reason"] = "watchdog"
    elif metrics["status"] == "PASS":
        metrics["completion_reason"] = "tohost_pass"
    elif metrics["status"] == "SAMPLED":
        metrics["completion_reason"] = "cycle_limit"
    elif metrics["status"] == "TIMEOUT":
        metrics["completion_reason"] = "timeout"
    elif metrics["status"] == "FAIL":
        metrics["completion_reason"] = "fail"
    else:
        metrics.setdefault("completion_reason", "unknown")

    cycle_match = re.search(r"\((>?)(\d+) cycles\)", line)
    if cycle_match:
        metrics["status_cycles_over_limit"] = cycle_match.group(1) == ">"
        metrics["status_cycles"] = int(cycle_match.group(2))

    stop_pc_match = re.search(r"stop_pc=0x([0-9a-fA-F]+)", rest)
    if stop_pc_match:
        metrics["status_stop_pc"] = f"0x{stop_pc_match.group(1).lower()}"

    cycle_limit_match = re.search(r"cycle_limit=(\d+)", rest)
    if cycle_limit_match:
        metrics["status_cycle_limit"] = int(cycle_limit_match.group(1))

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

    if payload.startswith("Other no-commit:"):
        values = parse_value_pairs(payload)
        for key in [
            "id_not_ready",
            "id_downstream",
            "ex_not_ready",
            "ex_downstream",
            "mem_not_ready",
            "mem_downstream",
            "flush_recovery",
            "frontend_backpressure",
            "pipeline_fill_drain",
            "unknown",
        ]:
            metrics[f"other_{key}"] = values.get(key, 0)
        metrics["other_breakdown_total"] = values.get("total", 0)
        metrics["other_original"] = values.get("original", 0)
        metrics["other_mismatch"] = values.get("mismatch", 0)
        return

    if payload.startswith("Other occupancy:"):
        values = parse_value_pairs(payload)
        for key, value in values.items():
            metrics[f"other_occ_{key}"] = value
        return

    if payload.startswith("Commit cycles:"):
        values = parse_value_pairs(payload)
        metrics["commit0_cycles"] = values.get("commit0", 0)
        metrics["commit1_cycles"] = values.get("commit1", 0)
        metrics["commit2_cycles"] = values.get("commit2", 0)
        metrics["commit_cycle_total"] = values.get("total", 0)
        return

    if payload.startswith("Issue slots:"):
        values = parse_value_pairs(payload)
        metrics["ideal_slots"] = values.get("ideal", 0)
        metrics["retired_slots"] = values.get("retired", 0)
        metrics["lost_slots"] = values.get("lost", 0)
        metrics["lost_no_commit_slots"] = values.get("no_commit_lost", 0)
        metrics["lost_single_issue_slots"] = values.get("single_issue_lost", 0)
        return

    if payload.startswith("MULDIV issued:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"muldiv_issued_{key}"] = value
        return

    if payload.startswith("MULDIV wait ops:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"muldiv_wait_{key}"] = value
        return

    if payload.startswith("MULDIV latency:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"muldiv_latency_{key}"] = value
        return

    if payload.startswith("DCache stall state:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"dc_stall_state_{key}"] = value
        return

    if payload.startswith("DCache stall request:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"dc_stall_req_{key}"] = value
        return

    if payload.startswith("Pair block exact:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"pair_block_{key}"] = value
        return

    if payload.startswith("Pair RAW producer:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"pair_raw_prod_{key}"] = value
        return

    if payload.startswith("Pair RAW consumer:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"pair_raw_cons_{key}"] = value
        return

    if payload.startswith("Pair RAW ALU matrix:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"pair_raw_alu_{key}"] = value
        return

    if payload.startswith("Pair RAW load matrix:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"pair_raw_load_{key}"] = value
        return

    if payload.startswith("Pair RAW store roles:"):
        for key, value in parse_value_pairs(payload).items():
            metrics[f"pair_raw_store_{key}"] = value
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

    match = re.search(
        r"^Primary refill:\s+starts=(\d+)\s+completes=(\d+)\s+aborts=(\d+)"
        r"\s+stall=(\d+)\s+avg=([0-9.]+)\s+lat1=(\d+)\s+lat2=(\d+)"
        r"\s+lat3=(\d+)\s+lat4plus=(\d+)",
        payload,
    )
    if match:
        metrics["dc_primary_refill_starts"] = int(match.group(1))
        metrics["dc_primary_refill_completes"] = int(match.group(2))
        metrics["dc_primary_refill_aborts"] = int(match.group(3))
        metrics["dc_primary_refill_stall_cycles"] = int(match.group(4))
        metrics["dc_primary_refill_avg"] = float(match.group(5))
        metrics["dc_primary_refill_lat1"] = int(match.group(6))
        metrics["dc_primary_refill_lat2"] = int(match.group(7))
        metrics["dc_primary_refill_lat3"] = int(match.group(8))
        metrics["dc_primary_refill_lat4plus"] = int(match.group(9))
        return

    if payload.startswith("Store buffer:"):
        values = parse_value_pairs(payload)
        metrics["dc_sb_enqueues"] = values.get("enq", 0)
        metrics["dc_sb_drains"] = values.get("drain", 0)
        metrics["dc_sb_block_cycles"] = values.get("block", 0)
        metrics["dc_sb_conflicts"] = values.get("conflict", 0)
        metrics["dc_store_forward_hits"] = values.get("fwd", 0)
        metrics["dc_miss_buffer_hits"] = values.get("missbuf", 0)
        return

    if payload.startswith("Direct drain impact:"):
        values = parse_value_pairs(payload)
        metrics["dc_drain_req_cycles"] = values.get("req_cycles", 0)
        metrics["dc_drain_resp_cycles"] = values.get("resp_cycles", 0)
        metrics["dc_drain_req_stall"] = values.get("req_stall", 0)
        metrics["dc_drain_resp_stall"] = values.get("resp_stall", 0)
        metrics["dc_drain_stall_total"] = values.get("stall_total", 0)
        metrics["dc_drain_hidden"] = values.get("hidden", 0)
        metrics["dc_drain_stall_load"] = values.get("load", 0)
        metrics["dc_drain_stall_store"] = values.get("store", 0)
        metrics["dc_drain_stall_other"] = values.get("other", 0)
        metrics["dc_drain_stall_kind_total"] = values.get("kind_total", 0)
        metrics["dc_drain_stall_mismatch"] = values.get("mismatch", 0)
        return

    if payload.startswith("Direct drain probe:"):
        values = parse_value_pairs(payload)
        metrics["dc_drain_probe_pending"] = values.get("pending", 0)
        metrics["dc_drain_probe_read_overlap"] = values.get("read_overlap", 0)
        metrics["dc_drain_probe_same_word"] = values.get("same_word", 0)
        metrics["dc_drain_probe_push_overlap"] = values.get("push_overlap", 0)
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
    metrics["schema_version"] = SCHEMA_VERSION
    metrics.setdefault("test", fallback_test)
    metrics.setdefault("status", "UNKNOWN")
    metrics.setdefault("completion_reason", "unknown")

    if metrics.get("signal") and metrics["completion_reason"] == "unknown":
        metrics["completion_reason"] = f"signal_{str(metrics['signal']).lower()}"

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

    cycles = metrics.get("cycles")
    total_insts = metrics.get("total_insts")
    if cycles and total_insts:
        metrics["ipc"] = float(total_insts) / float(cycles)
        metrics["cpi"] = float(cycles) / float(total_insts)

    s0 = metrics.get("s0_commits")
    s1 = metrics.get("s1_commits")
    if s0 is not None and s1 is not None:
        if int(s0) > 0:
            metrics["dual_issue_pct"] = 100.0 * float(s1) / float(s0)
        if cycles is not None:
            metrics.setdefault("ideal_slots", int(cycles) * 2)
            metrics.setdefault("retired_slots", int(s0) + int(s1))

    if "ideal_slots" in metrics and "retired_slots" in metrics:
        metrics.setdefault(
            "lost_slots",
            int(metrics["ideal_slots"]) - int(metrics["retired_slots"]),
        )

    if "commit0_cycles" in metrics:
        metrics.setdefault("lost_no_commit_slots", int(metrics["commit0_cycles"]) * 2)
    if "commit1_cycles" in metrics:
        metrics.setdefault("lost_single_issue_slots", int(metrics["commit1_cycles"]))
    if all(key in metrics for key in ["commit0_cycles", "commit1_cycles", "commit2_cycles"]):
        metrics.setdefault(
            "commit_cycle_total",
            int(metrics["commit0_cycles"])
            + int(metrics["commit1_cycles"])
            + int(metrics["commit2_cycles"]),
        )

    metrics["is_full_run"] = (
        metrics.get("status") in OK_FULL_STATUSES
        and metrics.get("completion_reason") in FULL_RUN_REASONS
    )

    consistency_errors: list[str] = []
    if metrics.get("sim_exit") not in (None, 0):
        consistency_errors.append("sim_exit_nonzero")
    if cycles is not None and "commit_cycle_total" in metrics:
        if int(metrics["commit_cycle_total"]) != int(cycles):
            consistency_errors.append("commit_cycle_total_ne_cycles")
    if total_insts is not None and s0 is not None and s1 is not None:
        if int(total_insts) != int(s0) + int(s1):
            consistency_errors.append("total_insts_ne_s0_plus_s1")
    if cycles is not None and "cpi_stack_total" in metrics:
        if int(metrics["cpi_stack_total"]) != int(cycles):
            consistency_errors.append("cpi_stack_total_ne_cycles")
    if "other_breakdown_total" in metrics and "cpi_stack_other_no_commit" in metrics:
        if int(metrics["other_breakdown_total"]) != int(metrics["cpi_stack_other_no_commit"]):
            consistency_errors.append("other_breakdown_total_ne_other_no_commit")
    if "other_original" in metrics and "cpi_stack_other_no_commit" in metrics:
        if int(metrics["other_original"]) != int(metrics["cpi_stack_other_no_commit"]):
            consistency_errors.append("other_original_ne_other_no_commit")
    if "other_mismatch" in metrics:
        if int(metrics["other_mismatch"]) != 0:
            consistency_errors.append("other_breakdown_mismatch_nonzero")
    if "ideal_slots" in metrics and "retired_slots" in metrics and "lost_slots" in metrics:
        if int(metrics["ideal_slots"]) - int(metrics["retired_slots"]) != int(metrics["lost_slots"]):
            consistency_errors.append("lost_slots_mismatch")
    if "dc_stall_state_total" in metrics and "dcache_miss_stall" in metrics:
        if int(metrics["dc_stall_state_total"]) != int(metrics["dcache_miss_stall"]):
            consistency_errors.append("dc_stall_state_total_ne_dcache_stall")
    if "dc_stall_state_mismatch" in metrics:
        if int(metrics["dc_stall_state_mismatch"]) != 0:
            consistency_errors.append("dc_stall_state_mismatch_nonzero")
    if "dc_stall_req_total" in metrics and "dcache_miss_stall" in metrics:
        if int(metrics["dc_stall_req_total"]) != int(metrics["dcache_miss_stall"]):
            consistency_errors.append("dc_stall_req_total_ne_dcache_stall")
    if "dc_stall_req_mismatch" in metrics:
        if int(metrics["dc_stall_req_mismatch"]) != 0:
            consistency_errors.append("dc_stall_req_mismatch_nonzero")
    if "muldiv_wait_total" in metrics and "muldiv_wait" in metrics:
        if int(metrics["muldiv_wait_total"]) != int(metrics["muldiv_wait"]):
            consistency_errors.append("muldiv_wait_ops_total_ne_muldiv_wait")
    if "muldiv_wait_mismatch" in metrics:
        if int(metrics["muldiv_wait_mismatch"]) != 0:
            consistency_errors.append("muldiv_wait_ops_mismatch_nonzero")
    if "pair_block_original" in metrics and "s1_blocked" in metrics:
        if int(metrics["pair_block_original"]) != int(metrics["s1_blocked"]):
            consistency_errors.append("pair_block_original_ne_s1_blocked")
    if "pair_block_mismatch" in metrics:
        if int(metrics["pair_block_mismatch"]) != 0:
            consistency_errors.append("pair_block_exact_mismatch_nonzero")
    if "dc_drain_stall_mismatch" in metrics:
        if int(metrics["dc_drain_stall_mismatch"]) != 0:
            consistency_errors.append("dc_drain_stall_kind_mismatch_nonzero")
    if "dc_drain_stall_total" in metrics:
        drain_stall_parts = (
            int(metrics.get("dc_drain_req_stall", 0))
            + int(metrics.get("dc_drain_resp_stall", 0))
        )
        if int(metrics["dc_drain_stall_total"]) != drain_stall_parts:
            consistency_errors.append("dc_drain_stall_total_mismatch")

    metrics["consistency_errors"] = consistency_errors
    metrics["consistency_error_count"] = len(consistency_errors)
    metrics.setdefault("log_has_error", 0)

    return metrics


def parse_log(path: Path) -> dict[str, Any]:
    metrics: dict[str, Any] = {"log": str(path), "perf_lines": []}
    fallback_test = path.stem

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            signal_match = re.search(r"Received\s+(SIGHUP|SIGINT|SIGTERM|SIGQUIT)", line)
            if signal_match:
                metrics["signal"] = signal_match.group(1)
            if not line.startswith("[PERF]") and re.search(
                r"\b(fatal|assert|error)\b", line, flags=re.IGNORECASE
            ):
                metrics["log_has_error"] = 1
            parse_status_line(line, metrics)
            if line.startswith("[PERF]"):
                payload = line[len("[PERF]") :].strip()
                metrics["perf_lines"].append(payload)
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


def missing_log_row(test: str, log_dir: Path) -> dict[str, Any]:
    return finalize_metrics(
        {
            "test": test,
            "status": "MISSING",
            "completion_reason": "missing_log",
            "log": str(log_dir / f"{test}.log"),
            "perf_lines": [],
            "log_has_error": 1,
        },
        test,
    )


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


def load_expected_tests(path: Path | None) -> list[str]:
    if path is None:
        return []
    tests: list[str] = []
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line and not line.startswith("#"):
                tests.append(line)
    return tests


def row_complete(row: dict[str, Any]) -> bool:
    return bool(row.get("is_full_run")) and row.get("sim_exit") == 0 and not row.get(
        "log_has_error", 0
    ) and not row.get("unexpected_log", 0) and int(row.get("consistency_error_count", 0)) == 0


def write_manifest(
    path: Path,
    rows: list[dict[str, Any]],
    expected_tests: list[str],
    produced_logs: list[Path],
) -> None:
    row_status = {
        str(row.get("test", "")): {
            "status": row.get("status", "UNKNOWN"),
            "completion_reason": row.get("completion_reason", "unknown"),
            "is_full_run": bool(row.get("is_full_run")),
            "sim_exit": row.get("sim_exit"),
            "unexpected_log": bool(row.get("unexpected_log", 0)),
            "consistency_errors": row.get("consistency_errors", []),
            "log": row.get("log", ""),
        }
        for row in rows
    }
    complete = bool(expected_tests) and all(row_complete(row) for row in rows)
    if expected_tests:
        complete = complete and len(rows) == len(expected_tests)
    else:
        complete = bool(rows) and all(row_complete(row) for row in rows)

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "complete": complete,
        "expected_tests": expected_tests,
        "produced_logs": [str(path) for path in produced_logs],
        "summary_csv": str(path / "summary.csv"),
        "summary_json": str(path / "summary.json"),
        "tests": row_status,
    }
    with (path / "manifest.json").open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True, help="run_perf output directory")
    parser.add_argument(
        "--baseline",
        help="baseline run directory or summary.csv to compare against",
    )
    parser.add_argument(
        "--expected-tests-file",
        help="newline-separated expected test list; missing logs become MISSING rows",
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="return nonzero unless every expected log is a full, clean run",
    )
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    log_dir = run_dir / "logs"
    if not log_dir.is_dir():
        print(f"ERROR: log directory not found: {log_dir}", file=sys.stderr)
        return 1

    produced_logs = sorted(log_dir.glob("*.log"))
    log_by_stem = {path.stem: path for path in produced_logs}
    try:
        expected_tests = load_expected_tests(
            Path(args.expected_tests_file) if args.expected_tests_file else None
        )
    except FileNotFoundError as exc:
        print(f"ERROR: expected tests file not found: {exc.filename}", file=sys.stderr)
        return 1

    if expected_tests:
        rows = [
            parse_log(log_by_stem[test]) if test in log_by_stem else missing_log_row(test, log_dir)
            for test in expected_tests
        ]
        expected_set = set(expected_tests)
        for path in produced_logs:
            if path.stem not in expected_set:
                row = parse_log(path)
                row["unexpected_log"] = 1
                rows.append(row)
    else:
        rows = [parse_log(path) for path in produced_logs]
        rows.sort(key=lambda item: str(item.get("test", "")))

    write_csv(run_dir / "summary.csv", rows, SUMMARY_COLUMNS)
    with (run_dir / "summary.json").open("w", encoding="utf-8") as handle:
        json.dump(rows, handle, indent=2, sort_keys=True)
        handle.write("\n")
    write_manifest(run_dir, rows, expected_tests, produced_logs)

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

    if args.require_complete:
        incomplete = [row for row in rows if not row_complete(row)]
        if incomplete:
            for row in incomplete:
                print(
                    "ERROR: incomplete perf log: "
                    f"{row.get('test')} status={row.get('status')} "
                    f"reason={row.get('completion_reason')} "
                    f"sim_exit={row.get('sim_exit', '')} "
                    f"errors={row.get('consistency_errors', [])}",
                    file=sys.stderr,
                )
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
