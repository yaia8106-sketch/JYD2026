#!/usr/bin/env python3
"""Build once and attribute NSCSCC perf cycles with the current RTL."""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime
from pathlib import Path


BENCHMARKS = [
    "bitcount",
    "bubble_sort",
    "coremark",
    "crc32",
    "dhrystone",
    "quick_sort",
    "select_sort",
    "sha",
    "stream_copy",
    "stringsearch",
    "fireye_A0",
    "fireye_B2",
    "fireye_C0",
    "fireye_D1",
    "fireye_I2",
    "inner_product",
    "lookup_table",
    "loop_induction",
    "my_memcmp",
    "minmax_sequence",
]

RESULT_PREFIX = "NSCSCC_PERF_RESULT,"
DONE_PREFIX = "NSCSCC_PERF_DONE,"
ROOT_CAUSES = (
    ("root_redirect", "redirect 恢复"),
    ("root_icache_refill", "I$ miss/refill"),
    ("root_fetch_response", "I$ 查询/取指响应等待"),
    ("root_frontend_empty", "前端无排队或在途取指"),
    ("root_frontend_blocked", "前端队列无有效头项"),
    ("root_id_load_raw", "ID load RAW 等待"),
    ("root_id_repair_raw", "ID 修复结果 RAW 等待"),
    ("root_id_muldiv_raw", "ID MulDiv RAW 等待"),
    ("root_id_muldiv_structure", "ID MulDiv 单元/owner 冲突"),
    ("root_id_serial_drain", "串行化指令等待旧后端排空"),
    ("root_id_serial_barrier", "年轻指令等待串行化提交"),
    ("root_id_timer_irq", "定时器中断等待流水线排空"),
    ("root_id_other", "ID 未细分 ready 条件"),
    ("root_ex_muldiv", "EX MulDiv 完成等待"),
    ("root_ex_mmio_order", "EX 非缓存 store/load 顺序等待"),
    ("root_ex_priv_drain", "EX 特权操作等待旧 token"),
    ("root_ex_other", "EX 未细分 ready 条件"),
    ("root_mem_dcache_lookup", "D$ 查询/miss 识别"),
    ("root_mem_dcache_refill", "D$ refill/读回"),
    ("root_mem_dcache_writeback", "D$ 脏行写回阻塞"),
    ("root_mem_uncached", "非缓存/MMIO 访存"),
    ("root_mem_other", "MEM 未细分 cache-ready 条件"),
    ("root_exception", "异常 token（不计提交）"),
    ("root_pipe_fill", "复位/流水线初始填充"),
    ("root_unclassified", "原因标签未分类"),
)
ROOT_CAUSE_LABELS = dict(ROOT_CAUSES)
TOPDOWN_CLASSES = (
    ("topdown_retiring_slots", "Retiring（有效提交）"),
    ("topdown_bad_speculation_slots", "Bad Speculation（错误推测）"),
    ("topdown_frontend_bound_slots", "Frontend Bound（前端受限）"),
    ("topdown_backend_bound_slots", "Backend Bound（后端受限）"),
)
SECOND_LEVEL_CLASSES = (
    ("l2_retiring_slots", "Retiring", "topdown_retiring_slots"),
    (
        "l2_branch_mispredict_slots",
        "Branch Mispredict（分支错误恢复）",
        "topdown_bad_speculation_slots",
    ),
    (
        "l2_machine_clear_slots",
        "Machine Clear（机器清空）",
        "topdown_bad_speculation_slots",
    ),
    (
        "l2_fetch_latency_slots",
        "Fetch Latency（取指延迟）",
        "topdown_frontend_bound_slots",
    ),
    (
        "l2_fetch_bandwidth_slots",
        "Fetch Bandwidth（取指带宽）",
        "topdown_frontend_bound_slots",
    ),
    (
        "l2_core_bound_slots",
        "Core Bound（核心执行受限）",
        "topdown_backend_bound_slots",
    ),
    (
        "l2_memory_bound_slots",
        "Memory Bound（数据访存受限）",
        "topdown_backend_bound_slots",
    ),
)
THIRD_LEVEL_CORE_CLASSES = (
    (
        "l3_load_repair_dependency_slots",
        "Load/repair 数据依赖",
    ),
    (
        "l3_same_pair_dependency_slots",
        "同组 RAW（唯一阻塞）",
    ),
    (
        "l3_pairing_policy_slots",
        "配对策略/指令类型限制",
    ),
    ("l3_muldiv_slots", "MulDiv"),
    ("l3_serialization_slots", "串行化"),
    ("l3_other_core_slots", "其他核心执行阻塞"),
)
FOURTH_LEVEL_FETCH_LATENCY_CLASSES = (
    ("l4_fetch_pipe_fill_slots", "流水线初始填充"),
    ("l4_fetch_icache_refill_slots", "I$ refill"),
    ("l4_fetch_response_slots", "取指查询/响应等待"),
    ("l4_fetch_empty_slots", "前端无排队或在途请求"),
)
FOURTH_LEVEL_FETCH_BANDWIDTH_CLASSES = (
    ("l4_fetch_blocked_slots", "前端队首阻塞"),
    ("l4_fetch_single_taken_slots", "Slot 0 已预测跳转"),
    ("l4_fetch_single_no_second_slots", "没有第二条排队指令"),
    ("l4_fetch_single_noncontiguous_slots", "第二条指令地址不连续"),
)
FOURTH_LEVEL_LOAD_CLASSES = (
    ("l4_load_raw_slots", "Load RAW"),
    ("l4_repair_raw_slots", "repair 结果 RAW"),
)
FOURTH_LEVEL_PAIR_RAW_CLASSES = (
    ("l4_pair_raw_alu_to_alu_slots", "ALU → ALU"),
    ("l4_pair_raw_alu_to_lsu_slots", "ALU → LSU"),
    ("l4_pair_raw_alu_to_cfi_slots", "ALU → CFI"),
    ("l4_pair_raw_lsu_producer_slots", "LSU 生产者"),
    ("l4_pair_raw_muldiv_producer_slots", "MulDiv 生产者"),
    ("l4_pair_raw_cfi_producer_slots", "CFI 生产者"),
    ("l4_pair_raw_other_slots", "其他"),
)
FOURTH_LEVEL_PAIR_POLICY_CLASSES = (
    ("l4_pair_policy_force_single_slots", "force_single"),
    ("l4_pair_policy_dual_lsu_slots", "双 LSU"),
    ("l4_pair_policy_dual_cfi_slots", "双 CFI"),
    ("l4_pair_policy_slot0_unsupported_slots", "Slot 0 类型不支持"),
    ("l4_pair_policy_slot1_unsupported_slots", "Slot 1 类型不支持"),
    ("l4_pair_policy_other_slots", "其他配对策略"),
)
ICACHE_3C_MISS_CLASSES = (
    ("icache_compulsory_misses", "Compulsory"),
    ("icache_conflict_misses", "Conflict"),
    ("icache_capacity_misses", "Capacity"),
    ("icache_outside_misses", "窗口外/不可缓存"),
)
ICACHE_3C_REFILL_SLOT_CLASSES = (
    ("icache_compulsory_refill_slots", "Compulsory"),
    ("icache_conflict_refill_slots", "Conflict"),
    ("icache_capacity_refill_slots", "Capacity"),
    ("icache_outside_refill_slots", "窗口外/不可缓存"),
)
ICACHE_3C_REFILL_REQUEST_CLASSES = (
    ("icache_compulsory_refill_requests", "Compulsory"),
    ("icache_conflict_refill_requests", "Conflict"),
    ("icache_capacity_refill_requests", "Capacity"),
    ("icache_outside_refill_requests", "窗口外/不可缓存"),
)
UART_BASE_INITIALIZER = (0xBFE001E0).to_bytes(4, "little")
SIM_UART_SCRATCH_BASE = 0x1C07F000
SOURCE_SUFFIXES = {
    ".v",
    ".sv",
    ".vh",
    ".f",
    ".c",
    ".cc",
    ".cpp",
    ".h",
    ".py",
    ".mak",
}


def parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    workspace = here.parents[5]
    parser = argparse.ArgumentParser(
        description=(
            "Profile the current NSCSCC RTL on the 20 competition perf "
            "programs using one shared Verilator build"
        )
    )
    parser.add_argument("--workspace", type=Path, default=workspace)
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=Path("/tmp/nscscc-rtl-perf-results"),
    )
    parser.add_argument(
        "--benchmark",
        action="append",
        choices=BENCHMARKS,
        help="run only this benchmark (may be repeated)",
    )
    parser.add_argument(
        "--delay-mode",
        choices=("fixed", "random", "none"),
        default="random",
        help=(
            "fixed delays the first R beat from each accepted AR by a fixed "
            "number of CPU cycles; random uses Chiplab's deterministic AXI "
            "delay injector; none is functional-only"
        ),
    )
    parser.add_argument(
        "--read-latency",
        type=int,
        default=170,
        help="fixed-mode cycles from AR acceptance to first eligible R beat",
    )
    parser.add_argument(
        "--write-latency",
        type=int,
        default=60,
        help="fixed-mode cycles from AW acceptance to eligible B response",
    )
    parser.add_argument(
        "--icache-bytes",
        type=int,
        choices=(8192, 16384, 32768),
        default=16384,
        help="compile-time ICache capacity for this profile",
    )
    parser.add_argument(
        "--icache-ways",
        type=int,
        choices=(1, 2),
        default=1,
        help="compile-time ICache associativity for this profile",
    )
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=5570815)
    parser.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1))
    parser.add_argument("--build-jobs", type=int, default=min(16, os.cpu_count() or 1))
    parser.add_argument(
        "--model-threads",
        type=int,
        default=1,
        help=(
            "worker threads inside each Verilated model (default: 1); "
            "this is independent of benchmark-level --jobs"
        ),
    )
    parser.add_argument("--timeout-seconds", type=int, default=7200)
    parser.add_argument("--max-sim-cycles", type=int, default=100_000_000)
    parser.add_argument("--force-rebuild", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument(
        "--dump-icache-trace",
        action="store_true",
        help="write compact lookup-line traces for the software cache model",
    )
    parser.add_argument(
        "--dump-dcache-trace",
        action="store_true",
        help="write compact cached load/store traces for the software model",
    )
    parser.add_argument(
        "--dump-bpu-trace",
        action="store_true",
        help="write confirmed CFI events for the software BPU model",
    )
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_fingerprint(paths: list[Path]) -> str:
    files: list[Path] = []
    for path in paths:
        if path.is_file():
            files.append(path)
            continue
        for candidate in path.rglob("*"):
            if not candidate.is_file() or candidate.suffix not in SOURCE_SUFFIXES:
                continue
            if any(part in {"obj_dir", "log", "results", "work"}
                   for part in candidate.parts):
                continue
            files.append(candidate)
    digest = hashlib.sha256()
    for path in sorted(set(files)):
        digest.update(str(path.resolve()).encode())
        digest.update(b"\0")
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()


def git_provenance(path: Path) -> dict:
    def run(*arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(path), *arguments],
            check=True,
            text=True,
            capture_output=True,
        )
        return result.stdout.strip()

    return {
        "path": str(path.resolve()),
        "commit": run("rev-parse", "HEAD"),
        "branch": run("branch", "--show-current"),
        "dirty_paths": run("status", "--short").splitlines(),
    }


def build_signature(args: argparse.Namespace, monitor: Path) -> dict:
    workspace = args.workspace.resolve()
    chiplab = workspace / "chiplab"
    core = workspace / "core"
    delay_source = (
        monitor.parent / "soc_axi_delay_fixed.v"
        if args.delay_mode == "fixed"
        else chiplab / "IP/AXI_DELAY_RAND"
    )
    source_hash = source_fingerprint(
        [
            core / "02_Design/rtl",
            core / "02_Design/platform/nscscc",
            monitor,
            chiplab / "sims/verilator/testbench",
            chiplab / "chip/soc_demo/sim",
            delay_source,
            chiplab / "IP/AXI_SRAM_BRIDGE",
            chiplab / "IP/AMBA",
            chiplab / "IP/CONFREG",
            chiplab / "sims/verilator/run_prog/Makefile",
            chiplab / "chip/config-generator.mak",
        ]
    )
    return {
        "source_sha256": source_hash,
        "verilator": subprocess.run(
            ["verilator", "--version"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip(),
        "trace_comp": False,
        "simu_trace": False,
        "run_func": False,
        "run_c": False,
        "monitor": str(monitor.resolve()),
        "verilator_threads": args.model_threads,
        "delay_backend": args.delay_mode,
        "icache_bytes": args.icache_bytes,
        "icache_ways": args.icache_ways,
    }


def ensure_build(args: argparse.Namespace, monitor: Path) -> tuple[Path, dict, bool]:
    chiplab = args.workspace / "chiplab"
    run_dir = chiplab / "sims/verilator/run_prog"
    generated_output = run_dir / "output"
    # Chiplab always writes its Verilator executable to run_prog/output.
    # Other local tools (for example the Konata runner) use that same build
    # entry and can therefore overwrite it with a different bound monitor.
    # Keep a private copy plus manifest so an apparently matching performance
    # cache can never execute another tool's model.
    cache_dir = Path(
        "/tmp/"
        f"nscscc-rtl-perf-build-ic{args.icache_bytes}-w{args.icache_ways}"
        f"-{args.delay_mode}"
    )
    output = cache_dir / "output"
    manifest_path = cache_dir / "manifest.json"
    signature = build_signature(args, monitor)

    old_signature = None
    if manifest_path.is_file():
        try:
            old_signature = json.loads(manifest_path.read_text())
        except json.JSONDecodeError:
            pass
    rebuild = args.force_rebuild or not output.is_file() or old_signature != signature
    if not rebuild:
        print(f"Reusing matching Verilator build: {output}")
        return output, signature, False

    env = os.environ.copy()
    env["CHIPLAB_HOME"] = str(chiplab.resolve())
    # An environment-origin variable is intentionally used here: the Chiplab
    # Makefile appends its normal sources to it. A command-line make variable
    # would override those appends and silently drop the SoC sources.
    env["VERILATOR_SRC"] = str(monitor.resolve())
    env["VFLAGS"] = (
        f"-DNSCSCC_ICACHE_BYTES={args.icache_bytes} "
        f"-DNSCSCC_ICACHE_WAYS={args.icache_ways}"
    )
    make_options = [
        # The bundled NEMU rejects CPUCFG and compares uncached virtual
        # addresses as physical store addresses, so it cannot validate the
        # unmodified competition perf startup. Functional success comes from
        # the perf program's own result check plus RTL simulation assertions.
        "TRACE_COMP=n",
        "SIMU_TRACE=n",
        "MEM_TRACE=n",
        "RUN_FUNC=n",
        "RUN_C=n",
        "OUTPUT_PC_INFO=n",
        "OUTPUT_UART_INFO=n",
        "PRINT_CLK_TIME=n",
        "DUMP_VCD=n",
        # Chiplab's C++ testbench requires one trace backend type at compile
        # time. Runtime --dump-waveform=0 below keeps it unopened and writes
        # no waveform files.
        "DUMP_FST=y",
        "DEAD_CLOCK_EN=y",
        # Model-level and benchmark-level parallelism are independent.  One
        # model thread is the measured-fast default for this small SoC, but
        # larger hosts/workloads can select more with --model-threads.
        f"THREAD={args.model_threads}",
    ]
    if args.delay_mode == "fixed":
        make_options.append(f"AXI_RAND_SRC={monitor.parent.resolve()}")
    print("Building one current-RTL Verilator executable ...", flush=True)
    # Do not use the Makefile's recursive `compile` target here. Because the
    # monitor is supplied through an environment-origin VERILATOR_SRC, a
    # recursive make would export the already-appended normal sources and then
    # append them a second time. Direct targets keep every RTL source unique.
    build_log = cache_dir / "build.log"
    build_log.parent.mkdir(parents=True, exist_ok=True)
    commands = [
        ["make", "link", *make_options],
        ["make", f"-j{args.build_jobs}", "-B", "verilator", *make_options],
        ["make", f"-j{args.build_jobs}", "-B", "testbench", *make_options],
    ]
    with build_log.open("w") as stream:
        for command in commands:
            completed = subprocess.run(
                command,
                cwd=run_dir,
                env=env,
                text=True,
                stdout=stream,
                stderr=subprocess.STDOUT,
            )
            log_lines = build_log.read_text(errors="replace").splitlines()
            verilator_error = any(
                line.lstrip().startswith("%Error") for line in log_lines
            )
            if completed.returncode != 0 or verilator_error:
                tail = log_lines[-60:]
                print("\n".join(tail), file=sys.stderr)
                raise RuntimeError(
                    f"build command failed ({completed.returncode}, "
                    f"verilator_error={verilator_error}); "
                    f"see {build_log}"
                )
    print(f"Build log: {build_log}")
    if not generated_output.is_file():
        raise RuntimeError(
            f"Verilator build did not create {generated_output}"
        )
    shutil.copy2(generated_output, output)
    output.chmod(output.stat().st_mode | 0o111)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(signature, indent=2) + "\n")
    return output, signature, True


def elf_symbol(elf: Path, symbol: str) -> int:
    result = subprocess.run(
        ["loongarch32r-linux-gnusf-nm", "-n", str(elf)],
        check=True,
        text=True,
        capture_output=True,
    )
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[-1] == symbol:
            return int(fields[0], 16)
    raise RuntimeError(f"{elf}: symbol {symbol!r} not found")


def write_ram_dat(binary: Path, destination: Path) -> tuple[int, str]:
    # objcopy lays the binary out from physical 0x1c000000; startup code copies
    # the packed data LMA into its 0x1c08xxxx VMA, just like the FPGA image.
    image = bytearray(binary.read_bytes())
    matches = [
        offset
        for offset in range(len(image) - len(UART_BASE_INITIALIZER) + 1)
        if image.startswith(UART_BASE_INITIALIZER, offset)
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"{binary}: expected exactly one UART_BASE initializer, "
            f"found {len(matches)}"
        )
    patch_offset = matches[0]
    original = bytes(image[patch_offset:patch_offset + 4])
    image[patch_offset:patch_offset + 4] = SIM_UART_SCRATCH_BASE.to_bytes(
        4, "little"
    )
    with destination.open("w") as output:
        output.write("@1c000000\n")
        output.writelines(f"{byte:02x}\n" for byte in image)
        output.write(f"@{SIM_UART_SCRATCH_BASE + 5:08x}\n20\n")
    return patch_offset, original.hex()


def parse_key_values(text: str) -> dict[str, int | str]:
    result: dict[str, int | str] = {}
    for item in text.split(","):
        if "=" not in item:
            continue
        key, value = item.split("=", 1)
        try:
            result[key] = int(value, 0)
        except ValueError:
            result[key] = value
    return result


def parse_monitor_output(stdout: str) -> dict:
    # The C++ testbench prints its wall-time "Terminated at ..." message from
    # another output path while Verilog is flushing the final result.  Under
    # high benchmark parallelism that line can bisect one $display record.
    # Remove only that fixed testbench message and rejoin the two fragments
    # before parsing; all RTL diagnostics and result text remain untouched.
    stdout = re.sub(r"\n?Terminated at [0-9]+ ns\.\n?", "", stdout)
    metrics: dict[str, int | str] = {}
    categories: list[str] = []
    done: dict[str, int | str] | None = None
    for line in stdout.splitlines():
        if line.startswith(RESULT_PREFIX):
            payload = line[len(RESULT_PREFIX):]
            category, _, values = payload.partition(",")
            categories.append(category)
            metrics.update(parse_key_values(values))
        elif line.startswith(DONE_PREFIX):
            done = parse_key_values(line[len(DONE_PREFIX):])
    if done is None:
        raise RuntimeError("simulation did not emit NSCSCC_PERF_DONE")
    metrics.update(done)
    metrics["monitor_categories"] = "+".join(categories)
    return metrics


def run_benchmark(
    name: str,
    args: argparse.Namespace,
    output: Path,
    result_root: Path,
) -> dict:
    perf_obj = args.workspace / "chiplab/software/examples/nscscc_perf/obj" / name
    elf = perf_obj / "main.elf"
    binary = perf_obj / "inst_data.bin"
    if not elf.is_file() or not binary.is_file():
        raise RuntimeError(f"{name}: missing main.elf or inst_data.bin")

    run_dir = result_root / "work" / name
    if run_dir.exists():
        shutil.rmtree(run_dir)
    run_dir.mkdir(parents=True)
    stop_pc = elf_symbol(elf, "test_finish")
    uart_putchar_pc = elf_symbol(elf, "uart_putchar")
    uart_patch_offset, uart_original_hex = write_ram_dat(
        binary, run_dir / "ram.dat"
    )
    log_path = result_root / "logs" / f"{name}.log"

    command = [
        str(output.resolve()),
        "--simu-bus-delay",
        "1" if args.delay_mode in {"fixed", "random"} else "0",
        "--simu-bus-delay-random-seed",
        str(args.seed),
        "--time-limit",
        "0",
        "--dump-waveform",
        "0",
        f"+perf_stop_pc={stop_pc:08x}",
        f"+perf_uart_putchar_pc={uart_putchar_pc:08x}",
        f"+perf_max_cycles={args.max_sim_cycles}",
    ]
    if args.delay_mode == "fixed":
        command.extend(
            [
                f"+perf_read_latency={args.read_latency}",
                f"+perf_write_latency={args.write_latency}",
            ]
        )
    if args.dump_icache_trace:
        command.append(f"+perf_icache_trace={run_dir / 'icache.trace'}")
    if args.dump_dcache_trace:
        command.append(f"+perf_dcache_trace={run_dir / 'dcache.trace'}")
    if args.dump_bpu_trace:
        command.append(f"+perf_bpu_trace={run_dir / 'bpu.trace'}")
    env = os.environ.copy()
    env["CHIPLAB_HOME"] = str((args.workspace / "chiplab").resolve())
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=run_dir,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=args.timeout_seconds,
        )
    except subprocess.TimeoutExpired as error:
        output_text = error.stdout or ""
        if isinstance(output_text, bytes):
            output_text = output_text.decode(errors="replace")
        log_path.write_text(output_text)
        raise RuntimeError(
            f"{name}: wall-clock timeout after {args.timeout_seconds}s"
        ) from error
    elapsed = time.monotonic() - started
    log_path.write_text(completed.stdout)
    if completed.returncode != 0:
        raise RuntimeError(
            f"{name}: simulator exited {completed.returncode}; see {log_path}"
        )
    metrics = parse_monitor_output(completed.stdout)
    if metrics.get("pass") != 1:
        raise RuntimeError(f"{name}: benchmark LED result is not PASS; see {log_path}")
    if metrics.get("measurement_active") != 0:
        raise RuntimeError(f"{name}: stopped inside an incomplete timing interval")
    if int(metrics.get("intervals", 0)) <= 0:
        raise RuntimeError(f"{name}: monitor saw no complete timing interval")
    if "different at pc" in completed.stdout or "Assertion failed" in completed.stdout:
        raise RuntimeError(f"{name}: difftest/assertion failure; see {log_path}")

    missing_roots = [key for key, _ in ROOT_CAUSES if key not in metrics]
    if missing_roots:
        raise RuntimeError(
            f"{name}: monitor omitted causal counters: {', '.join(missing_roots)}"
        )
    root_sum = sum(int(metrics[key]) for key, _ in ROOT_CAUSES)
    zero_commit_cycles = int(metrics.get("zero_commit_cycles", 0))
    if root_sum != zero_commit_cycles:
        raise RuntimeError(
            f"{name}: causal zero-commit counters sum to {root_sum}, "
            f"expected {zero_commit_cycles}; see {log_path}"
        )

    required_topdown = tuple(key for key, _ in TOPDOWN_CLASSES) + (
        "topdown_unclassified_slots",
    )
    missing_topdown = [key for key in required_topdown if key not in metrics]
    if missing_topdown:
        raise RuntimeError(
            f"{name}: monitor omitted top-down counters: "
            f"{', '.join(missing_topdown)}"
        )
    total_slots = 2 * int(metrics.get("cycles", 0))
    classified_slots = sum(int(metrics[key]) for key in required_topdown)
    if classified_slots != total_slots:
        raise RuntimeError(
            f"{name}: top-down counters sum to {classified_slots}, "
            f"expected {total_slots}; see {log_path}"
        )
    if int(metrics["topdown_retiring_slots"]) != int(
        metrics.get("instructions", 0)
    ):
        raise RuntimeError(
            f"{name}: top-down retiring slots do not match committed "
            f"instructions; see {log_path}"
        )
    if int(metrics["topdown_unclassified_slots"]) != 0:
        raise RuntimeError(
            f"{name}: top-down classification left "
            f"{metrics['topdown_unclassified_slots']} slots unresolved; "
            f"see {log_path}"
        )

    required_l2 = tuple(key for key, _, _ in SECOND_LEVEL_CLASSES) + (
        "l2_unclassified_slots",
    )
    missing_l2 = [key for key in required_l2 if key not in metrics]
    if missing_l2:
        raise RuntimeError(
            f"{name}: monitor omitted second-level counters: "
            f"{', '.join(missing_l2)}"
        )
    l2_total = sum(int(metrics[key]) for key in required_l2)
    if l2_total != total_slots:
        raise RuntimeError(
            f"{name}: second-level counters sum to {l2_total}, "
            f"expected {total_slots}; see {log_path}"
        )
    l2_parent_invariants = (
        (
            int(metrics["topdown_retiring_slots"]),
            int(metrics["l2_retiring_slots"]),
            "Retiring",
        ),
        (
            int(metrics["topdown_bad_speculation_slots"]),
            int(metrics["l2_branch_mispredict_slots"])
            + int(metrics["l2_machine_clear_slots"]),
            "Bad Speculation",
        ),
        (
            int(metrics["topdown_frontend_bound_slots"]),
            int(metrics["l2_fetch_latency_slots"])
            + int(metrics["l2_fetch_bandwidth_slots"]),
            "Frontend Bound",
        ),
        (
            int(metrics["topdown_backend_bound_slots"]),
            int(metrics["l2_core_bound_slots"])
            + int(metrics["l2_memory_bound_slots"]),
            "Backend Bound",
        ),
    )
    for parent_slots, child_slots, label in l2_parent_invariants:
        if parent_slots != child_slots:
            raise RuntimeError(
                f"{name}: second-level {label} children sum to "
                f"{child_slots}, expected {parent_slots}; see {log_path}"
            )
    if int(metrics["l2_unclassified_slots"]) != 0:
        raise RuntimeError(
            f"{name}: second-level classification left "
            f"{metrics['l2_unclassified_slots']} slots unresolved; "
            f"see {log_path}"
        )

    required_l3_core = tuple(
        key for key, _ in THIRD_LEVEL_CORE_CLASSES
    ) + ("l3_unclassified_core_slots",)
    missing_l3_core = [
        key for key in required_l3_core if key not in metrics
    ]
    if missing_l3_core:
        raise RuntimeError(
            f"{name}: monitor omitted third-level Core Bound counters: "
            f"{', '.join(missing_l3_core)}"
        )
    l3_core_total = sum(int(metrics[key]) for key in required_l3_core)
    l2_core_total = int(metrics["l2_core_bound_slots"])
    if l3_core_total != l2_core_total:
        raise RuntimeError(
            f"{name}: third-level Core Bound children sum to "
            f"{l3_core_total}, expected {l2_core_total}; see {log_path}"
        )
    if int(metrics["l3_unclassified_core_slots"]) != 0:
        raise RuntimeError(
            f"{name}: third-level Core Bound classification left "
            f"{metrics['l3_unclassified_core_slots']} slots unresolved; "
            f"see {log_path}"
        )

    def validate_l4_partition(
        classes: tuple,
        unclassified_key: str | None,
        parent_slots: int,
        label: str,
    ) -> None:
        keys = tuple(key for key, _ in classes)
        if unclassified_key is not None:
            keys += (unclassified_key,)
        missing = [key for key in keys if key not in metrics]
        if missing:
            raise RuntimeError(
                f"{name}: monitor omitted fourth-level {label} counters: "
                f"{', '.join(missing)}"
            )
        child_slots = sum(int(metrics[key]) for key in keys)
        if child_slots != parent_slots:
            raise RuntimeError(
                f"{name}: fourth-level {label} children sum to "
                f"{child_slots}, expected {parent_slots}; see {log_path}"
            )
        if unclassified_key is not None and int(metrics[unclassified_key]) != 0:
            raise RuntimeError(
                f"{name}: fourth-level {label} left "
                f"{metrics[unclassified_key]} slots unresolved; see {log_path}"
            )

    validate_l4_partition(
        FOURTH_LEVEL_FETCH_LATENCY_CLASSES,
        None,
        int(metrics["l2_fetch_latency_slots"]),
        "Fetch Latency",
    )
    icache_3c_miss_keys = tuple(
        key for key, _ in ICACHE_3C_MISS_CLASSES
    ) + ("icache_3c_unclassified_misses",)
    missing_icache_3c_misses = [
        key for key in icache_3c_miss_keys if key not in metrics
    ]
    if missing_icache_3c_misses:
        raise RuntimeError(
            f"{name}: monitor omitted ICache 3C miss counters: "
            f"{', '.join(missing_icache_3c_misses)}"
        )
    classified_icache_misses = sum(
        int(metrics[key]) for key in icache_3c_miss_keys
    )
    if classified_icache_misses != int(metrics["icache_misses"]):
        raise RuntimeError(
            f"{name}: ICache 3C misses sum to {classified_icache_misses}, "
            f"expected {metrics['icache_misses']}; see {log_path}"
        )
    if int(metrics["icache_3c_unclassified_misses"]) != 0:
        raise RuntimeError(
            f"{name}: ICache 3C model left misses unclassified; "
            f"see {log_path}"
        )

    icache_3c_refill_request_keys = tuple(
        key for key, _ in ICACHE_3C_REFILL_REQUEST_CLASSES
    ) + ("icache_3c_unclassified_refill_requests",)
    missing_icache_3c_refill_requests = [
        key for key in icache_3c_refill_request_keys if key not in metrics
    ]
    if missing_icache_3c_refill_requests:
        raise RuntimeError(
            f"{name}: monitor omitted ICache 3C refill-request counters: "
            f"{', '.join(missing_icache_3c_refill_requests)}"
        )
    classified_icache_refill_requests = sum(
        int(metrics[key]) for key in icache_3c_refill_request_keys
    )
    if classified_icache_refill_requests != int(
        metrics["icache_refill_requests"]
    ):
        raise RuntimeError(
            f"{name}: ICache 3C refill requests sum to "
            f"{classified_icache_refill_requests}, expected "
            f"{metrics['icache_refill_requests']}; see {log_path}"
        )
    if int(metrics["icache_3c_unclassified_refill_requests"]) != 0:
        raise RuntimeError(
            f"{name}: ICache 3C model left refill requests unclassified; "
            f"see {log_path}"
        )

    icache_3c_refill_keys = tuple(
        key for key, _ in ICACHE_3C_REFILL_SLOT_CLASSES
    ) + ("icache_3c_unclassified_refill_slots",)
    missing_icache_3c_refill = [
        key for key in icache_3c_refill_keys if key not in metrics
    ]
    if missing_icache_3c_refill:
        raise RuntimeError(
            f"{name}: monitor omitted ICache 3C refill-slot counters: "
            f"{', '.join(missing_icache_3c_refill)}"
        )
    classified_icache_refill_slots = sum(
        int(metrics[key]) for key in icache_3c_refill_keys
    )
    if classified_icache_refill_slots != int(
        metrics["l4_fetch_icache_refill_slots"]
    ):
        raise RuntimeError(
            f"{name}: ICache 3C refill slots sum to "
            f"{classified_icache_refill_slots}, expected "
            f"{metrics['l4_fetch_icache_refill_slots']}; see {log_path}"
        )
    if int(metrics["icache_3c_unclassified_refill_slots"]) != 0:
        raise RuntimeError(
            f"{name}: ICache 3C model left refill slots unclassified; "
            f"see {log_path}"
        )
    validate_l4_partition(
        FOURTH_LEVEL_FETCH_BANDWIDTH_CLASSES,
        "l4_fetch_single_unclassified_slots",
        int(metrics["l2_fetch_bandwidth_slots"]),
        "Fetch Bandwidth",
    )
    taken_target_keys = (
        "l5_fetch_taken_target_pairable_slots",
        "l5_fetch_taken_target_available_blocked_slots",
        "l5_fetch_taken_target_unavailable_slots",
    )
    missing_taken_target = [
        key for key in taken_target_keys if key not in metrics
    ]
    if missing_taken_target:
        raise RuntimeError(
            f"{name}: monitor omitted taken-target counters: "
            f"{', '.join(missing_taken_target)}"
        )
    taken_target_total = sum(int(metrics[key]) for key in taken_target_keys)
    if taken_target_total != int(metrics["l4_fetch_single_taken_slots"]):
        raise RuntimeError(
            f"{name}: taken-target children sum to {taken_target_total}, "
            f"expected {metrics['l4_fetch_single_taken_slots']}; "
            f"see {log_path}"
        )
    validate_l4_partition(
        FOURTH_LEVEL_LOAD_CLASSES,
        None,
        int(metrics["l3_load_repair_dependency_slots"]),
        "Load/repair dependency",
    )
    load_source_keys = (
        "l5_load_ex_only_slots",
        "l5_load_mem_ready_only_slots",
        "l5_load_mem_wait_only_slots",
        "l5_load_multi_source_slots",
        "l5_load_other_slots",
    )
    missing_load_sources = [
        key for key in load_source_keys if key not in metrics
    ]
    if missing_load_sources:
        raise RuntimeError(
            f"{name}: monitor omitted Load source counters: "
            f"{', '.join(missing_load_sources)}"
        )
    load_source_total = sum(int(metrics[key]) for key in load_source_keys)
    if load_source_total != int(metrics["l4_load_raw_slots"]):
        raise RuntimeError(
            f"{name}: Load source children sum to {load_source_total}, "
            f"expected {metrics['l4_load_raw_slots']}; see {log_path}"
        )
    validate_l4_partition(
        FOURTH_LEVEL_PAIR_RAW_CLASSES,
        "l4_pair_raw_unclassified_slots",
        int(metrics["l3_same_pair_dependency_slots"]),
        "same-pair RAW",
    )
    validate_l4_partition(
        FOURTH_LEVEL_PAIR_POLICY_CLASSES,
        "l4_pair_policy_unclassified_slots",
        int(metrics["l3_pairing_policy_slots"]),
        "pairing policy",
    )

    required_early = (
        "early_accepted_loads",
        "early_addr_safe_loads",
        "early_addr_aggressive_loads",
        "early_addr_repair_blocked_loads",
        "early_grant_safe_loads",
        "early_grant_aggressive_loads",
        "early_block_internal_safe",
        "early_block_internal_aggressive",
        "early_block_fallback_safe",
        "early_block_fallback_aggressive",
        "early_raw_hit_safe_all",
        "early_raw_hit_aggressive_all",
        "early_raw_hit_safe_all_no_store",
        "early_raw_hit_aggressive_all_no_store",
        "early_raw_hit_safe_v1",
        "early_raw_hit_aggressive_v1",
        "early_raw_hit_safe_v1_no_store",
        "early_raw_hit_aggressive_v1_no_store",
        "early_store_load_overlaps",
        "early_store_load_same_word",
        "early_store_load_diff_word",
    )
    missing_early = [key for key in required_early if key not in metrics]
    if missing_early:
        raise RuntimeError(
            f"{name}: monitor omitted early-DCache counters: "
            f"{', '.join(missing_early)}"
        )

    early_invariants = (
        (
            int(metrics["early_addr_safe_loads"]),
            int(metrics["early_grant_safe_loads"])
            + int(metrics["early_block_internal_safe"])
            + int(metrics["early_block_fallback_safe"]),
            "safe address candidates",
        ),
        (
            int(metrics["early_addr_aggressive_loads"]),
            int(metrics["early_grant_aggressive_loads"])
            + int(metrics["early_block_internal_aggressive"])
            + int(metrics["early_block_fallback_aggressive"]),
            "aggressive address candidates",
        ),
        (
            int(metrics["early_accepted_loads"]),
            int(metrics["early_addr_aggressive_loads"])
            + int(metrics["early_addr_repair_blocked_loads"]),
            "accepted load address classes",
        ),
        (
            int(metrics["early_store_load_overlaps"]),
            int(metrics["early_store_load_same_word"])
            + int(metrics["early_store_load_diff_word"]),
            "store/load overlap classes",
        ),
    )
    for expected, observed, label in early_invariants:
        if expected != observed:
            raise RuntimeError(
                f"{name}: early-DCache {label} sum to {observed}, "
                f"expected {expected}; see {log_path}"
            )
    if (
        int(metrics["early_raw_hit_safe_all_no_store"])
        > int(metrics["early_raw_hit_safe_all"])
        or int(metrics["early_raw_hit_aggressive_all_no_store"])
        > int(metrics["early_raw_hit_aggressive_all"])
        or int(metrics["early_raw_hit_safe_v1"])
        > int(metrics["early_raw_hit_safe_all"])
        or int(metrics["early_raw_hit_aggressive_v1"])
        > int(metrics["early_raw_hit_aggressive_all"])
        or int(metrics["early_raw_hit_safe_v1_no_store"])
        > int(metrics["early_raw_hit_safe_v1"])
        or int(metrics["early_raw_hit_aggressive_v1_no_store"])
        > int(metrics["early_raw_hit_aggressive_v1"])
    ):
        raise RuntimeError(
            f"{name}: collision-free early-DCache RAW count exceeds its "
            f"gross count; see {log_path}"
        )

    cycles = int(metrics["cycles"])
    instructions = int(metrics["instructions"])
    metrics.update(
        {
            "benchmark": name,
            "status": "PASS",
            "wall_seconds": round(elapsed, 6),
            "stop_pc": f"0x{stop_pc:08x}",
            "uart_putchar_pc": f"0x{uart_putchar_pc:08x}",
            "uart_patch_offset": uart_patch_offset,
            "uart_original_hex": uart_original_hex,
            "ipc": instructions / cycles if cycles else 0.0,
            "elf_sha256": sha256_file(elf),
            "bin_sha256": sha256_file(binary),
            "log": str(log_path.resolve()),
            "icache_trace": (
                str((run_dir / "icache.trace").resolve())
                if args.dump_icache_trace else ""
            ),
            "dcache_trace": (
                str((run_dir / "dcache.trace").resolve())
                if args.dump_dcache_trace else ""
            ),
        }
    )
    return metrics


def ratio(numerator: float, denominator: float) -> float:
    return numerator / denominator if denominator else 0.0


def percent(value: float) -> str:
    return f"{100.0 * value:.3f}%"


def derived(row: dict) -> dict:
    cycles = int(row.get("cycles", 0))
    instructions = int(row.get("instructions", 0))
    total_slots = 2 * cycles
    icache_accesses = int(row.get("icache_hits", 0)) + int(
        row.get("icache_misses", 0)
    )
    icache_misses = int(row.get("icache_misses", 0))
    icache_conflict_misses = int(row.get("icache_conflict_misses", 0))
    icache_refill_slots = int(row.get("l4_fetch_icache_refill_slots", 0))
    icache_conflict_refill_slots = int(
        row.get("icache_conflict_refill_slots", 0)
    )
    # A blocking ICache refill normally removes both issue slots.  Dividing
    # causal lost slots by two is the same optimistic slot-compression model
    # used elsewhere in the report; it avoids pretending that miss count alone
    # captures variable AXI latency.
    icache_conflict_ideal_saved_cycles = icache_conflict_refill_slots / 2.0
    dcache_accesses = sum(
        int(row.get(key, 0))
        for key in (
            "dcache_load_hits",
            "dcache_load_misses",
            "dcache_store_hits",
            "dcache_store_misses",
        )
    )
    conditional = int(row.get("conditional_updates", 0))
    zero = int(row.get("zero_commit_cycles", 0))
    root_causes = {
        key: int(row.get(key, 0))
        for key, _ in ROOT_CAUSES
    }
    dominant = max(root_causes, key=root_causes.get) if root_causes else "none"
    early_accepted = int(row.get("early_accepted_loads", 0))
    early_raw_events = int(row.get("early_raw_ex_events", 0))
    early_safe_gross = int(row.get("early_raw_hit_safe_v1", 0))
    early_aggressive_gross = int(
        row.get("early_raw_hit_aggressive_v1", 0)
    )
    early_safe_collision = int(
        row.get("early_store_same_word_hit_safe", 0)
    )
    early_aggressive_collision = int(
        row.get("early_store_same_word_hit_aggressive", 0)
    )
    # One same-word replay cancels one otherwise-early cycle.  This is a
    # deliberately conservative event-model estimate, not a replacement for
    # an RTL A/B run: resource/timing changes and secondary queue effects are
    # outside the monitor.
    early_safe_net = early_safe_gross - early_safe_collision
    early_aggressive_net = (
        early_aggressive_gross - early_aggressive_collision
    )
    early_safe_all_gross = int(row.get("early_raw_hit_safe_all", 0))
    early_aggressive_all_gross = int(
        row.get("early_raw_hit_aggressive_all", 0)
    )
    early_safe_all_net = early_safe_all_gross - early_safe_collision
    early_aggressive_all_net = (
        early_aggressive_all_gross - early_aggressive_collision
    )

    def estimated_speedup(net_saved: int) -> float:
        projected_cycles = cycles - net_saved
        if not cycles or projected_cycles <= 0:
            return 0.0
        return cycles / projected_cycles - 1.0

    return {
        "ipc": ratio(instructions, cycles),
        "topdown_total_slots": total_slots,
        "topdown_retiring_rate": ratio(
            int(row.get("topdown_retiring_slots", 0)), total_slots
        ),
        "topdown_bad_speculation_rate": ratio(
            int(row.get("topdown_bad_speculation_slots", 0)), total_slots
        ),
        "topdown_frontend_bound_rate": ratio(
            int(row.get("topdown_frontend_bound_slots", 0)), total_slots
        ),
        "topdown_backend_bound_rate": ratio(
            int(row.get("topdown_backend_bound_slots", 0)), total_slots
        ),
        "l2_branch_mispredict_rate": ratio(
            int(row.get("l2_branch_mispredict_slots", 0)), total_slots
        ),
        "l2_machine_clear_rate": ratio(
            int(row.get("l2_machine_clear_slots", 0)), total_slots
        ),
        "l2_fetch_latency_rate": ratio(
            int(row.get("l2_fetch_latency_slots", 0)), total_slots
        ),
        "l2_fetch_bandwidth_rate": ratio(
            int(row.get("l2_fetch_bandwidth_slots", 0)), total_slots
        ),
        "l2_core_bound_rate": ratio(
            int(row.get("l2_core_bound_slots", 0)), total_slots
        ),
        "l2_memory_bound_rate": ratio(
            int(row.get("l2_memory_bound_slots", 0)), total_slots
        ),
        "zero_commit_rate": ratio(zero, cycles),
        "dual_commit_rate": ratio(int(row.get("dual_commit_cycles", 0)), cycles),
        "icache_miss_rate": ratio(int(row.get("icache_misses", 0)), icache_accesses),
        "icache_compulsory_miss_share": ratio(
            int(row.get("icache_compulsory_misses", 0)), icache_misses
        ),
        "icache_conflict_miss_share": ratio(
            icache_conflict_misses, icache_misses
        ),
        "icache_capacity_miss_share": ratio(
            int(row.get("icache_capacity_misses", 0)), icache_misses
        ),
        "icache_conflict_refill_slot_share": ratio(
            icache_conflict_refill_slots, icache_refill_slots
        ),
        "icache_conflict_ideal_saved_cycles":
            icache_conflict_ideal_saved_cycles,
        "icache_conflict_ideal_speedup": estimated_speedup(
            icache_conflict_ideal_saved_cycles
        ),
        "dcache_miss_rate": ratio(
            int(row.get("dcache_load_misses", 0))
            + int(row.get("dcache_store_misses", 0)),
            dcache_accesses,
        ),
        "conditional_accuracy": 1.0 - ratio(
            int(row.get("conditional_wrong", 0)), conditional
        ),
        "redirect_mpki": 1000.0 * ratio(
            int(row.get("redirects", 0)), instructions
        ),
        "i_first_latency_avg": ratio(
            int(row.get("axi_i_first_latency_sum", 0)),
            int(row.get("axi_i_first_latency_samples", 0)),
        ),
        "d_first_latency_avg": ratio(
            int(row.get("axi_d_first_latency_sum", 0)),
            int(row.get("axi_d_first_latency_samples", 0)),
        ),
        "dominant_zero_commit_reason": dominant.removeprefix("root_"),
        "dominant_zero_commit_label": ROOT_CAUSE_LABELS.get(dominant, dominant),
        "dominant_zero_commit_cycles": root_causes.get(dominant, 0),
        "dominant_zero_commit_share": ratio(root_causes.get(dominant, 0), zero),
        "early_addr_safe_rate": ratio(
            int(row.get("early_addr_safe_loads", 0)), early_accepted
        ),
        "early_addr_aggressive_rate": ratio(
            int(row.get("early_addr_aggressive_loads", 0)), early_accepted
        ),
        "early_grant_safe_rate": ratio(
            int(row.get("early_grant_safe_loads", 0)), early_accepted
        ),
        "early_grant_aggressive_rate": ratio(
            int(row.get("early_grant_aggressive_loads", 0)), early_accepted
        ),
        "early_raw_repairable_rate": ratio(
            int(row.get("early_raw_repairable_events", 0)), early_raw_events
        ),
        "early_raw_safe_coverage": ratio(
            early_safe_gross, early_raw_events
        ),
        "early_raw_aggressive_coverage": ratio(
            early_aggressive_gross, early_raw_events
        ),
        "early_safe_gross_saved_cycles": early_safe_gross,
        "early_aggressive_gross_saved_cycles": early_aggressive_gross,
        "early_safe_collision_cycles": early_safe_collision,
        "early_aggressive_collision_cycles": early_aggressive_collision,
        "early_safe_net_saved_cycles": early_safe_net,
        "early_aggressive_net_saved_cycles": early_aggressive_net,
        "early_safe_gross_speedup": estimated_speedup(early_safe_gross),
        "early_aggressive_gross_speedup": estimated_speedup(
            early_aggressive_gross
        ),
        "early_safe_est_speedup": estimated_speedup(early_safe_net),
        "early_aggressive_est_speedup": estimated_speedup(
            early_aggressive_net
        ),
        "early_safe_all_gross_saved_cycles": early_safe_all_gross,
        "early_aggressive_all_gross_saved_cycles":
            early_aggressive_all_gross,
        "early_safe_all_net_saved_cycles": early_safe_all_net,
        "early_aggressive_all_net_saved_cycles": early_aggressive_all_net,
        "early_safe_all_gross_speedup": estimated_speedup(
            early_safe_all_gross
        ),
        "early_aggressive_all_gross_speedup": estimated_speedup(
            early_aggressive_all_gross
        ),
        "early_safe_all_est_speedup": estimated_speedup(
            early_safe_all_net
        ),
        "early_aggressive_all_est_speedup": estimated_speedup(
            early_aggressive_all_net
        ),
    }


def aggregate_rows(rows: list[dict]) -> dict:
    ignored = {
        "benchmark",
        "status",
        "wall_seconds",
        "stop_pc",
        "uart_putchar_pc",
        "uart_patch_offset",
        "uart_original_hex",
        "ipc",
        "elf_sha256",
        "bin_sha256",
        "log",
        "monitor_categories",
    }
    totals: Counter = Counter()
    for row in rows:
        for key, value in row.items():
            if key in ignored or not isinstance(value, int):
                continue
            totals[key] += value
    result = {"benchmark": "TOTAL", "status": "PASS", **dict(totals)}
    result.update(derived(result))
    result["wall_seconds"] = sum(float(row["wall_seconds"]) for row in rows)
    return result


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    output = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    output.extend("| " + " | ".join(row) + " |" for row in rows)
    return "\n".join(output)


def write_outputs(
    args: argparse.Namespace,
    rows: list[dict],
    signature: dict,
    build_rebuilt: bool,
    suite_seconds: float,
) -> None:
    result_root = args.results_dir
    detailed = []
    for row in rows:
        item = dict(row)
        item.update(derived(row))
        detailed.append(item)
    aggregate = aggregate_rows(rows)

    fieldnames: list[str] = []
    for row in detailed:
        for key in row:
            if key not in fieldnames:
                fieldnames.append(key)
    with (result_root / "rtl_perf_profile.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(detailed)
    (result_root / "aggregate.json").write_text(
        json.dumps(aggregate, ensure_ascii=False, indent=2) + "\n"
    )

    table_rows = []
    topdown_program_rows = []
    second_level_program_rows = []
    third_level_core_program_rows = []
    icache_3c_program_rows = []
    for row in detailed:
        table_rows.append(
            [
                row["benchmark"],
                f"{int(row['cycles']):,}",
                f"{int(row['instructions']):,}",
                f"{row['ipc']:.4f}",
                percent(row["zero_commit_rate"]),
                percent(row["dual_commit_rate"]),
                percent(row["icache_miss_rate"]),
                percent(row["dcache_miss_rate"]),
                f"{row['redirect_mpki']:.3f}",
                f"{row['dominant_zero_commit_label']} "
                f"({percent(row['dominant_zero_commit_share'])})",
            ]
        )
        topdown_program_rows.append(
            [
                row["benchmark"],
                f"{row['ipc']:.4f}",
                percent(row["topdown_retiring_rate"]),
                percent(row["topdown_bad_speculation_rate"]),
                percent(row["topdown_frontend_bound_rate"]),
                percent(row["topdown_backend_bound_rate"]),
            ]
        )
        second_level_program_rows.append(
            [
                row["benchmark"],
                percent(row["l2_branch_mispredict_rate"]),
                percent(row["l2_machine_clear_rate"]),
                percent(row["l2_fetch_latency_rate"]),
                percent(row["l2_fetch_bandwidth_rate"]),
                percent(row["l2_core_bound_rate"]),
                percent(row["l2_memory_bound_rate"]),
            ]
        )
        third_level_core_program_rows.append(
            [row["benchmark"]]
            + [
                percent(
                    ratio(
                        int(row.get(key, 0)),
                        int(row["topdown_total_slots"]),
                    )
                )
                for key, _ in THIRD_LEVEL_CORE_CLASSES
            ]
        )
        icache_3c_program_rows.append(
            [
                row["benchmark"],
                f"{int(row.get('icache_misses', 0)):,}",
                percent(row["icache_compulsory_miss_share"]),
                percent(row["icache_conflict_miss_share"]),
                percent(row["icache_capacity_miss_share"]),
                f"{int(row.get('icache_conflict_refill_slots', 0)):,}",
                percent(row["icache_conflict_ideal_speedup"]),
            ]
        )

    topdown_total_slots = int(aggregate.get("topdown_total_slots", 0))
    topdown_rows = [
        [
            label,
            f"{int(aggregate.get(key, 0)):,}",
            percent(ratio(int(aggregate.get(key, 0)), topdown_total_slots)),
        ]
        for key, label in TOPDOWN_CLASSES
    ]
    topdown_classified_slots = sum(
        int(aggregate.get(key, 0)) for key, _ in TOPDOWN_CLASSES
    )
    topdown_unclassified_slots = int(
        aggregate.get("topdown_unclassified_slots", 0)
    )

    second_level_rows = []
    for key, label, parent_key in SECOND_LEVEL_CLASSES:
        value = int(aggregate.get(key, 0))
        parent_value = int(aggregate.get(parent_key, 0))
        second_level_rows.append(
            [
                label,
                f"{value:,}",
                percent(ratio(value, topdown_total_slots)),
                percent(ratio(value, parent_value)),
            ]
        )
    second_level_total = sum(
        int(aggregate.get(key, 0)) for key, _, _ in SECOND_LEVEL_CLASSES
    )
    second_level_unclassified = int(
        aggregate.get("l2_unclassified_slots", 0)
    )

    third_level_core_parent = int(aggregate.get("l2_core_bound_slots", 0))
    third_level_core_rows = []
    for key, label in THIRD_LEVEL_CORE_CLASSES:
        value = int(aggregate.get(key, 0))
        third_level_core_rows.append(
            [
                label,
                f"{value:,}",
                percent(ratio(value, topdown_total_slots)),
                percent(ratio(value, third_level_core_parent)),
            ]
        )
    third_level_core_total = sum(
        int(aggregate.get(key, 0))
        for key, _ in THIRD_LEVEL_CORE_CLASSES
    )
    third_level_core_unclassified = int(
        aggregate.get("l3_unclassified_core_slots", 0)
    )

    root_cause_rows = []
    zero_total = int(aggregate.get("zero_commit_cycles", 0))
    sorted_root_causes = sorted(
        ROOT_CAUSES,
        key=lambda item: int(aggregate.get(item[0], 0)),
        reverse=True,
    )
    for key, label in sorted_root_causes:
        value = int(aggregate.get(key, 0))
        root_cause_rows.append(
            [label, f"{value:,}", percent(ratio(value, zero_total))]
        )
    root_total = sum(int(aggregate.get(key, 0)) for key, _ in ROOT_CAUSES)
    unresolved_total = sum(
        int(aggregate.get(key, 0))
        for key in (
            "root_id_other",
            "root_ex_other",
            "root_mem_other",
            "root_unclassified",
        )
    )

    aggregate_icache_misses = int(aggregate.get("icache_misses", 0))
    aggregate_icache_refill_slots = int(
        aggregate.get("l4_fetch_icache_refill_slots", 0)
    )
    icache_3c_rows = [
        [
            label,
            f"{int(aggregate.get(key, 0)):,}",
            percent(
                ratio(int(aggregate.get(key, 0)), aggregate_icache_misses)
            ),
        ]
        for key, label in ICACHE_3C_MISS_CLASSES
    ]
    aggregate_icache_refill_requests = int(
        aggregate.get("icache_refill_requests", 0)
    )
    icache_3c_refill_request_rows = [
        [
            label,
            f"{int(aggregate.get(key, 0)):,}",
            percent(
                ratio(
                    int(aggregate.get(key, 0)),
                    aggregate_icache_refill_requests,
                )
            ),
        ]
        for key, label in ICACHE_3C_REFILL_REQUEST_CLASSES
    ]
    icache_3c_refill_rows = [
        [
            label,
            f"{int(aggregate.get(key, 0)):,}",
            percent(
                ratio(
                    int(aggregate.get(key, 0)),
                    aggregate_icache_refill_slots,
                )
            ),
        ]
        for key, label in ICACHE_3C_REFILL_SLOT_CLASSES
    ]
    icache_conflict_speedup_ratios = [
        1.0 + float(row["icache_conflict_ideal_speedup"])
        for row in detailed
    ]
    icache_conflict_geomean_speedup = (
        math.exp(
            sum(math.log(value) for value in icache_conflict_speedup_ratios)
            / len(icache_conflict_speedup_ratios)
        )
        - 1.0
        if icache_conflict_speedup_ratios
        else 0.0
    )

    early_rows = []
    for row in detailed:
        early_rows.append(
            [
                row["benchmark"],
                f"{int(row.get('early_accepted_loads', 0)):,}",
                percent(row["early_addr_safe_rate"]),
                percent(row["early_addr_aggressive_rate"]),
                f"{int(row.get('early_raw_ex_events', 0)):,}",
                f"{int(row['early_safe_gross_saved_cycles']):,}",
                f"{int(row['early_safe_net_saved_cycles']):,}",
                percent(row["early_safe_est_speedup"]),
                f"{int(row['early_aggressive_gross_saved_cycles']):,}",
                f"{int(row['early_aggressive_net_saved_cycles']):,}",
                percent(row["early_aggressive_est_speedup"]),
            ]
        )

    early_role_rows = [
        ["普通 ALU 操作数", f"{int(aggregate.get('early_raw_role_alu', 0)):,}"],
        ["下一条 Load 地址", f"{int(aggregate.get('early_raw_role_load_addr', 0)):,}"],
        ["Store 地址", f"{int(aggregate.get('early_raw_role_store_addr', 0)):,}"],
        ["Store 数据", f"{int(aggregate.get('early_raw_role_store_data', 0)):,}"],
        ["条件分支比较", f"{int(aggregate.get('early_raw_role_branch', 0)):,}"],
        ["JIRL 基址", f"{int(aggregate.get('early_raw_role_jirl', 0)):,}"],
        ["其他消费者", f"{int(aggregate.get('early_raw_role_other', 0)):,}"],
    ]

    delay_description = (
        f"首拍固定 {args.read_latency} cycle、B 固定 "
        f"{args.write_latency} cycle"
        if args.delay_mode == "fixed"
        else f"随机延迟种子 {args.seed}"
    )
    associativity = "direct-mapped" if args.icache_ways == 1 else "2-way"

    report = f"""# NSCSCC RTL 性能归因

生成时间：{datetime.now().astimezone().isoformat(timespec='seconds')}

- 模式：`{args.delay_mode}`（{delay_description}）。
- ICache：{args.icache_bytes // 1024} KiB、{associativity}、16 B line。
- 覆盖 {len(rows)} 个程序；benchmark 并行度 `{args.jobs}`，每个 Verilated
  模型 `{args.model_threads}` 个线程；仿真合计墙钟时间 {suite_seconds:.2f} s。
- Verilator 构建本次{'重新生成' if build_rebuilt else '通过源码指纹复用'}；检查赛方程序自身 PASS 结果和 RTL 仿真断言，关闭波形和逐指令文本 trace。
- 聚合 IPC：{aggregate['ipc']:.5f}；总 cycle {int(aggregate['cycles']):,}；总指令 {int(aggregate['instructions']):,}。

## 第一层：Top-Down 槽位归因

双发射处理器每个计时周期拥有两个槽位，因此本次共有
{topdown_total_slots:,} 个槽位。每个槽位沿真实流水线携带自己的有效位或空泡原因，
最终互斥归入 Retiring、Bad Speculation、Frontend Bound、Backend Bound。四类合计
{topdown_classified_slots:,}，与总槽位
{('一致' if topdown_classified_slots == topdown_total_slots else '不一致')}；未分类槽位
{topdown_unclassified_slots:,}。

- Retiring：该槽位最终提交了一条有效指令。
- Bad Speculation：redirect/机器清空杀死的年轻槽位及其恢复空泡。
- Frontend Bound：没有可供发射的 Slot 0，或没有连续、正确路径的第二条指令。
- Backend Bound：已有指令仍被依赖、配对规则、执行单元或访存后端阻塞。

{markdown_table(['顶层类别', 'slot', '全部槽位占比'], topdown_rows)}

### 每程序顶层归因

{markdown_table(
    ['程序', 'IPC', 'Retiring', 'Bad Speculation', 'Frontend Bound', 'Backend Bound'],
    topdown_program_rows,
)}

## 第二层：顶层瓶颈拆分

第二层继续使用同一批槽位，不产生重叠计数：Bad Speculation 拆为分支错误恢复和
机器清空，Frontend Bound 拆为取指延迟和取指带宽，Backend Bound 拆为核心执行
受限和数据访存受限。第二层合计 {second_level_total:,}，与总槽位
{('一致' if second_level_total == topdown_total_slots else '不一致')}；未分类槽位
{second_level_unclassified:,}。表中的“父类内部占比”用于判断每个顶层桶应继续向哪一支
钻取。

{markdown_table(
    ['第二层类别', 'slot', '全部槽位占比', '父类内部占比'],
    second_level_rows,
)}

### 每程序第二层归因

{markdown_table(
    ['程序', '分支错误', '机器清空', '取指延迟', '取指带宽', 'Core Bound', 'Memory Bound'],
    second_level_program_rows,
)}

## 第三层：Core Bound 拆分

第三层只继续钻取最大的 `Core Bound` 父类，并保持互斥。六个已分类子类合计
{third_level_core_total:,}，与第二层 Core Bound 的 {third_level_core_parent:,}
{('一致' if third_level_core_total == third_level_core_parent else '不一致')}；未分类槽位
{third_level_core_unclassified:,}。

“同组 RAW（唯一阻塞）”使用反事实口径：只有去掉 Slot 0 → Slot 1 RAW 后，这两条
现成、连续、正确路径指令会立即满足全部双发规则，才归入该桶。若 RAW 与不支持的
指令组合、`force_single` 等规则同时存在，则归入“配对策略/指令类型限制”；因此不能
把本来仍无法双发的槽位误算成增加同组前递即可恢复的性能。

{markdown_table(
    ['Core Bound 第三层类别', 'slot', '全部槽位占比', 'Core Bound 内部占比'],
    third_level_core_rows,
)}

### 每程序 Core Bound 第三层归因

下表各列是相对该程序全部槽位的占比，便于直接比较潜在 IPC 空间。

{markdown_table(
    ['程序'] + [label for _, label in THIRD_LEVEL_CORE_CLASSES],
    third_level_core_program_rows,
)}

## 每程序

{markdown_table(
    ['程序', 'cycle', '指令', 'IPC', '零提交', '双提交周期', 'I$ miss', 'D$ miss', 'redirect MPKI', '最大零提交来源'],
    table_rows,
)}

## 零提交周期互斥归因

监控器在空泡产生的流水级记录原因标签，并按真实 `valid/allowin/flush` 规则将标签
一路送到 WB；因此这里描述的是造成零提交的原始事件，而不是零提交发生当周期的
信号快照。各桶严格互斥，加总 {root_total:,}，与 `zero_commit_cycles`
{('一致' if root_total == zero_total else '不一致')}。仍未细分的 ID/EX/MEM/标签原因
合计 {unresolved_total:,}（{percent(ratio(unresolved_total, zero_total))}）。旧版瞬时
优先级计数仍保留在 CSV 中供观察条件重叠，但不再作为主归因；其中旧 `other` 为
{int(aggregate.get('no_commit_other', 0)):,}。

{markdown_table(['原始原因', 'cycle', '零提交占比'], root_cause_rows)}

## ID 提前地址 / EX DCache 数据影子模型

这个监控器没有改变处理器行为。它把每条已接受的 Load 影子标记为两种候选：

- **保守路径**：Load 基址不能来自当前 EX，也不能依赖下一拍才到达的 load-repair
  数据；这条路径更接近不会把 EX ALU/前递链串进 DCache 地址口的首版 RTL。
- **激进路径**：允许普通 EX ALU 前递参与地址计算，但仍禁止 load-repair 基址。

两种路径都按一个 DCache 读口建模，优先级为“victim/replay 内部读 > 当前 EX
回退查询 > 当前 ID 提前查询”。Store 使用独立写口，因此不同 word 不冲突；同一
word 按首版方案保守计作一次重读。只有 DCache 后续确认 hit、ID 当时除 EX-load
RAW 外已满足其他 issue 条件、且消费者属于 ALU/Load/Store 时，才计入可节省周期。
分支、JIRL 和其他消费者只统计，不进入首版收益。

- 已接受 Load：{int(aggregate.get('early_accepted_loads', 0)):,}；保守地址可用
  {percent(aggregate['early_addr_safe_rate'])}，激进地址可用
  {percent(aggregate['early_addr_aggressive_rate'])}。
- 考虑读口优先级后，保守实际提前查询
  {int(aggregate.get('early_grant_safe_loads', 0)):,}
  （{percent(aggregate['early_grant_safe_rate'])}），激进
  {int(aggregate.get('early_grant_aggressive_loads', 0)):,}
  （{percent(aggregate['early_grant_aggressive_rate'])}）。
- 单独由 EX Load RAW 造成、理论上可能消除的 issue 空泡：
  {int(aggregate.get('early_raw_ex_events', 0)):,}；其中首版消费者可修复
  {int(aggregate.get('early_raw_repairable_events', 0)):,}
  （{percent(aggregate['early_raw_repairable_rate'])}）。
- 保守路径 gross 可省 {int(aggregate['early_safe_gross_saved_cycles']):,}
  cycle；若保留/改造现有同 word bypass，对应同频加速
  {percent(aggregate['early_safe_gross_speedup'])}。若首版直接重读，同 word 代价
  {int(aggregate['early_safe_collision_cycles']):,} cycle，
  净省 {int(aggregate['early_safe_net_saved_cycles']):,} cycle，事件模型估算同频
  加速 {percent(aggregate['early_safe_est_speedup'])}。
- 激进路径 gross 可省 {int(aggregate['early_aggressive_gross_saved_cycles']):,}
  cycle；若保留/改造 bypass，对应同频加速
  {percent(aggregate['early_aggressive_gross_speedup'])}。若直接重读，同 word 代价
  {int(aggregate['early_aggressive_collision_cycles']):,}
  cycle，净省 {int(aggregate['early_aggressive_net_saved_cycles']):,} cycle，事件模型
  估算同频加速 {percent(aggregate['early_aggressive_est_speedup'])}。
- 如果未来也允许分支/JIRL/其他消费者接收这条快速数据，保守/激进两条路径的
  **全消费者上限**分别是 gross
  {int(aggregate['early_safe_all_gross_saved_cycles']):,}/
  {int(aggregate['early_aggressive_all_gross_saved_cycles']):,} cycle（保留 bypass 时
  {percent(aggregate['early_safe_all_gross_speedup'])}/
  {percent(aggregate['early_aggressive_all_gross_speedup'])}）；按同 word 重读扣除后为
  {int(aggregate['early_safe_all_net_saved_cycles']):,}/
  {int(aggregate['early_aggressive_all_net_saved_cycles']):,} cycle（
  {percent(aggregate['early_safe_all_est_speedup'])}/
  {percent(aggregate['early_aggressive_all_est_speedup'])}）。这是时序风险更高的上限，
  不属于首版方案。
- 观测到 MEM Store / EX Load 重叠
  {int(aggregate.get('early_store_load_overlaps', 0)):,} 次；其中同 word
  {int(aggregate.get('early_store_load_same_word', 0)):,} 次，不同 word
  {int(aggregate.get('early_store_load_diff_word', 0)):,} 次。

{markdown_table(
    ['程序', 'Load', '保守地址可用', '激进地址可用', 'EX-load RAW', '保守 gross', '保守净省', '保守估算', '激进 gross', '激进净省', '激进估算'],
    early_rows,
)}

消费者角色可能重叠，例如同一条 Store 的地址和数据同时依赖 Load，所以以下各行
不要求加总等于 EX-load RAW 总数：

{markdown_table(['消费者角色', '事件数'], early_role_rows)}

这里的“加速”只是 `原 cycle / (原 cycle - 净省 cycle) - 1`。它适合在写 RTL
前判断收益量级；最终数字仍必须由实现后的同种子 RTL A/B 给出，因为新数据路径的
时序、额外寄存器、回压传播以及二阶流水线效应都不在影子模型内。

## ICache 3C miss 与冲突消除直接收益

当前 ICache 是 {args.icache_bytes // 1024} KiB、{associativity}、16 B line，共
{args.icache_bytes // 16} 行。仿真监控器用同容量
全相连 LRU 影子 Cache 处理完全相同的取指 line 序列：第一次见到的 line 是
Compulsory；真实 Cache miss 但全相连影子命中的是 Conflict；两个 Cache 都 miss
且不是第一次访问的是 Capacity。影子状态从复位后持续预热，计数仍只覆盖正式
RDCNTVL 性能窗口。

{markdown_table(['miss 类别', 'miss', '总体 miss 占比'], icache_3c_rows)}

其中真正送上 AXI 的 refill 请求按相同类别分布如下；被 redirect 提前取消的 lookup
miss 不会进入这张表：

{markdown_table(
    ['refill 类别', 'AXI 请求', '全部 I$ refill 请求占比'],
    icache_3c_refill_request_rows,
)}

miss 数量不能体现随机 AXI 延迟差异，因此下表还让 3C 类别随真实前端空泡一路传播
到 WB，统计各类 refill 实际造成的损失槽位：

{markdown_table(['refill 类别', '损失 slot', 'I$ refill slot 占比'], icache_3c_refill_rows)}

若理想地消除全部 Conflict miss，同时假定命中延迟和 CPU 频率不变，可压缩约
{aggregate['icache_conflict_ideal_saved_cycles']:,.1f} cycle，当前延迟模型下的同频
聚合直接加速估算为 {percent(aggregate['icache_conflict_ideal_speedup'])}，逐程序
几何平均为 {percent(icache_conflict_geomean_speedup)}。这个数字按真实因果空泡加权，
但不包含减少 AXI 竞争的二阶收益；改成有限路组相连通常也只能消除其中一部分，并
可能带来额外命中路径和布线代价。

{markdown_table(
    ['程序', 'I$ miss', 'Compulsory', 'Conflict', 'Capacity', 'Conflict refill slot', '理想加速'],
    icache_3c_program_rows,
)}

## Cache / AXI 摘要

- I Cache：{int(aggregate.get('icache_misses', 0)):,} miss，
  {int(aggregate.get('icache_refill_requests', 0)):,} 次 refill；AR 到首拍平均
  {aggregate['i_first_latency_avg']:.2f} cycle，最大
  {int(aggregate.get('axi_i_first_latency_max', 0))} cycle。
- D Cache：{int(aggregate.get('dcache_load_misses', 0)) + int(aggregate.get('dcache_store_misses', 0)):,} miss，
  {int(aggregate.get('dcache_dirty_victims', 0)):,} 条脏 victim，
  {int(aggregate.get('dcache_writeback_requests', 0)):,} 次写回；AR 到首拍平均
  {aggregate['d_first_latency_avg']:.2f} cycle，最大
  {int(aggregate.get('axi_d_first_latency_max', 0))} cycle。
- I/D 两个读 ID 同时 outstanding 的计时周期：
  {int(aggregate.get('axi_both_read_outstanding_cycles', 0)):,}。
- DCache refill 与 dirty writeback 实际重叠周期：
  {int(aggregate.get('cycles_refill_wb_overlap', 0)):,}。
- 条件分支方向准确率：{percent(aggregate['conditional_accuracy'])}；
  redirect MPKI：{aggregate['redirect_mpki']:.3f}。

## 数据边界

- `fixed` 在每次 AR 握手后等待指定 CPU 周期才释放首个 R beat，Burst 剩余 beat
  连续传输，并允许已经接收的 I/D 请求并行等待；它用于复现赛方 perf 包装器的长
  首拍延迟量级。`random` 是 Chiplab 的确定性随机反压，`none` 只适合功能检查。
  三者都不是 MIG+DDR3 的电气/刷新级精确模型，最终总周期仍以 CI/板上计数为准。
- 计数窗口由赛方程序成对提交的 `RDCNTVL.W` 自动开关；多段计时程序会全部累计，
  启动、打印和结果上报不混入统计。
- 临时 RAM 镜像把 `UART_BASE` 数据初值指向仿真 scratch，并把其 LSR 字节置为
  THRE=1，以绕开 Verilator 环境中永不就绪的 16550 轮询；指令和原始 bin
  不变。监控器保证正式计时窗口内一旦调用
  `uart_putchar` 就立即判定本次数据无效，所以省掉的只有窗口外打印。
- 随 Chiplab 提供的 NEMU 不支持 perf 启动代码的 `CPUCFG`，且其 uncached store
  物理地址比较与当前 core 接口不兼容，因此本脚本不启用该 NEMU。软件镜像保持
  原样；功能判定依据程序自己的结果检查、LED PASS 状态和 RTL 仿真断言。
- `manifest.json` 记录源码指纹、两个仓库状态、二进制哈希、构建模式和命令环境；
  比较两份结果前应先确认该文件中的输入一致。
"""
    (result_root / "report.md").write_text(report)

    manifest = {
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "workspace": str(args.workspace.resolve()),
        "runner": {
            "path": str(Path(__file__).resolve()),
            "sha256": sha256_file(Path(__file__).resolve()),
        },
        "monitor": {
            "path": str(
                Path(__file__).resolve().with_name("nscscc_perf_monitor.sv")
            ),
            "sha256": sha256_file(
                Path(__file__).resolve().with_name("nscscc_perf_monitor.sv")
            ),
        },
        "delay_mode": args.delay_mode,
        "read_latency": args.read_latency,
        "write_latency": args.write_latency,
        "icache_bytes": args.icache_bytes,
        "icache_ways": args.icache_ways,
        "seed": args.seed,
        "jobs": args.jobs,
        "model_threads": args.model_threads,
        "suite_wall_seconds": suite_seconds,
        "build_rebuilt": build_rebuilt,
        "build_signature": signature,
        "repositories": {
            "core": git_provenance(args.workspace / "core"),
            "chiplab": git_provenance(args.workspace / "chiplab"),
        },
        "benchmarks": {
            row["benchmark"]: {
                "elf_sha256": row["elf_sha256"],
                "bin_sha256": row["bin_sha256"],
                "stop_pc": row["stop_pc"],
                "uart_putchar_pc": row["uart_putchar_pc"],
                "uart_patch_offset": row["uart_patch_offset"],
                "uart_original_hex": row["uart_original_hex"],
                "uart_replacement_hex": SIM_UART_SCRATCH_BASE.to_bytes(
                    4, "little"
                ).hex(),
                "uart_scratch_base": f"0x{SIM_UART_SCRATCH_BASE:08x}",
                "patch_allowed_inside_measured_interval": False,
                "log": row["log"],
            }
            for row in rows
        },
    }
    (result_root / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    )


def main() -> int:
    args = parse_args()
    args.workspace = args.workspace.resolve()
    if args.jobs <= 0 or args.build_jobs <= 0 or args.model_threads <= 0:
        raise RuntimeError(
            "--jobs, --build-jobs, and --model-threads must be positive"
        )
    monitor = Path(__file__).resolve().with_name("nscscc_perf_monitor.sv")
    if not monitor.is_file():
        raise RuntimeError(f"missing monitor: {monitor}")
    output, signature, rebuilt = ensure_build(args, monitor)
    if args.build_only:
        print(f"Build ready: {output}")
        return 0

    selected = args.benchmark or BENCHMARKS
    args.results_dir.mkdir(parents=True, exist_ok=True)
    (args.results_dir / "logs").mkdir(exist_ok=True)
    started = time.monotonic()
    rows: list[dict] = []
    errors: list[str] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = {
            executor.submit(
                run_benchmark, name, args, output, args.results_dir
            ): name
            for name in selected
        }
        for future in concurrent.futures.as_completed(futures):
            name = futures[future]
            try:
                row = future.result()
                rows.append(row)
                print(
                    f"[PASS] {name:16s} cycles={int(row['cycles']):>10,d} "
                    f"IPC={float(row['ipc']):.4f} wall={row['wall_seconds']:.2f}s",
                    flush=True,
                )
            except Exception as error:  # preserve all parallel failures
                message = f"{name}: {error}"
                errors.append(message)
                print(f"[FAIL] {message}", file=sys.stderr, flush=True)

    if errors:
        raise RuntimeError("; ".join(errors))
    rows.sort(key=lambda row: selected.index(row["benchmark"]))
    suite_seconds = time.monotonic() - started
    write_outputs(args, rows, signature, rebuilt, suite_seconds)
    print(f"CSV:      {args.results_dir / 'rtl_perf_profile.csv'}")
    print(f"Report:   {args.results_dir / 'report.md'}")
    print(f"Manifest: {args.results_dir / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"run_rtl_perf_profile.py: {error}", file=sys.stderr)
        raise SystemExit(1)
