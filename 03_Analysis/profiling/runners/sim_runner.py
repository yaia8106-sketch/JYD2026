#!/usr/bin/env python3
"""
Simulation runners.

Responsible for:
- compiling the existing RTL/testbench into a profiling simulator binary;
- running prepared tests with centralized stop conditions;
- writing raw simulator logs to profiling/output/logs.

Not responsible for:
- deciding which tests exist;
- parsing performance counters into final report fields;
- implementing collector-specific metric logic.

Inputs:
- PreparedTest objects from catalog/test_catalog.py;
- run configuration such as max cycles, watchdog cycles, and enabled plusargs.

Outputs:
- SimRunResult dictionaries consumed by collectors and reporting.

Dependencies:
- Python standard library;
- external simulator commands (`verilator` or `iverilog`/`vvp`);
- existing RTL and tb_riscv_tests.sv.

Common extension point:
- add new simulator backends here, keeping SimRunResult stable for collectors
  and reporters.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from catalog.test_catalog import PreparedTest
from common.profile_events import parse_result_line


RTL_FILE_NAMES = [
    "cpu_defs.sv",
    "pc_reg.sv",
    "next_pc_mux.sv",
    "if_id_reg.sv",
    "decoder.sv",
    "imm_gen.sv",
    "regfile.sv",
    "forwarding.sv",
    "alu_src_mux.sv",
    "id_ex_reg.sv",
    "id_ex_reg_s1.sv",
    "alu.sv",
    "branch_condition.sv",
    "id_stage_derive.sv",
    "ex_stage_ctrl.sv",
    "branch_unit.sv",
    "branch_predictor.sv",
    "mem_interface.sv",
    "redirect_ctrl.sv",
    "csr_trap_unit.sv",
    "memory_access_unit.sv",
    "muldiv_unit.sv",
    "dual_issue_counter.sv",
    "dual_issue_decider.sv",
    "if_stage_buffer.sv",
    "irom_addr_ctrl.sv",
    "ex_mem_reg.sv",
    "ex_mem_reg_s1.sv",
    "mem_wb_reg.sv",
    "mem_wb_reg_s1.sv",
    "wb_mux.sv",
    "dcache.sv",
    "cpu_top.sv",
]


def _irom_plusargs(prepared: PreparedTest) -> List[str]:
    """Return simulator plusargs for the prepared IROM layout."""
    if prepared.irom_slot0_hex is not None and prepared.irom_slot1_hex is not None:
        return [
            f"+irom_slot0={prepared.irom_slot0_hex}",
            f"+irom_slot1={prepared.irom_slot1_hex}",
        ]
    if prepared.irom_hex is not None:
        return [f"+irom={prepared.irom_hex}"]
    raise ValueError(f"{prepared.spec.name}: prepared test has no IROM image")


@dataclass(frozen=True)
class SimRunResult:
    test_name: str
    irom_mode: str
    expected_stop_reason: str
    command: List[str]
    returncode: int
    log_file: Path
    status: str
    stop_reason: str
    cycles: Optional[int]
    raw_result: Dict[str, object]


class IverilogRunner:
    def __init__(self, workspace: Path, output_dir: Path) -> None:
        self.workspace = workspace
        self.output_dir = output_dir
        self.rtl_dir = workspace / "02_Design" / "rtl"
        self.tests_dir = workspace / "02_Design" / "riscv_tests"
        self.sim_bin = output_dir / "profile_sim"

    def _rtl_files(self) -> List[Path]:
        files = [self.rtl_dir / name for name in RTL_FILE_NAMES]
        files.extend(
            [
                self.tests_dir / "work" / "dcache_data_ram.v",
                self.tests_dir / "tb" / "perf_monitor.sv",
                self.tests_dir / "tb" / "tb_riscv_tests.sv",
            ]
        )
        return files

    def compile(self) -> None:
        """Compile the simulator binary once for all profiling tests."""
        self.output_dir.mkdir(parents=True, exist_ok=True)
        missing = [str(path) for path in self._rtl_files() if not path.exists()]
        if missing:
            raise FileNotFoundError("missing RTL/TB files:\n" + "\n".join(missing))

        cmd = ["iverilog", "-g2012", "-o", str(self.sim_bin)]
        cmd.extend(str(path) for path in self._rtl_files())
        result = subprocess.run(
            cmd,
            cwd=self.workspace,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        compile_log = self.output_dir / "compile.log"
        compile_log.write_text(result.stdout)
        if result.returncode != 0:
            raise RuntimeError(f"iverilog compilation failed; see {compile_log}")

    def run_test(
        self,
        prepared: PreparedTest,
        *,
        max_cycles: Optional[int] = None,
        watchdog_cycles: Optional[int] = None,
        perf: bool = True,
        pc_guard: bool = True,
        led_trace: bool = False,
    ) -> SimRunResult:
        """Run one prepared test and write its raw log."""
        spec = prepared.spec
        cycles = max_cycles if max_cycles is not None else spec.max_cycles
        watchdog = watchdog_cycles if watchdog_cycles is not None else spec.watchdog_cycles

        cmd = [
            "vvp",
            "-N",
            str(self.sim_bin),
            f"+dram={prepared.dram_hex}",
            f"+test={spec.name}",
            f"+cycles={cycles}",
            f"+watchdog={watchdog}",
        ]
        cmd.extend(_irom_plusargs(prepared))
        if spec.stop_pc is not None:
            cmd.append(f"+stop_pc={spec.stop_pc:08x}")
        if perf:
            cmd.append("+perf")
        if pc_guard:
            cmd.append("+pc_guard")
        if led_trace:
            cmd.append("+led_trace")

        result = subprocess.run(
            cmd,
            cwd=self.workspace,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        prepared.log_file.parent.mkdir(parents=True, exist_ok=True)
        prepared.log_file.write_text(result.stdout)

        parsed = parse_result_line(result.stdout.splitlines())
        expected_stop_reason = "DONE_PC" if spec.stop_pc is not None else "LED_PASS"
        if spec.stop_pc is not None:
            parsed.setdefault("target_stop_pc", f"0x{spec.stop_pc:08x}")
        return SimRunResult(
            test_name=spec.name,
            irom_mode=prepared.irom_mode,
            expected_stop_reason=expected_stop_reason,
            command=cmd,
            returncode=result.returncode,
            log_file=prepared.log_file,
            status=str(parsed.get("status", "UNKNOWN")),
            stop_reason=str(parsed.get("stop_reason", "UNKNOWN")),
            cycles=parsed.get("cycles"),  # type: ignore[arg-type]
            raw_result=parsed,
        )


class VerilatorRunner(IverilogRunner):
    """Verilator --binary runner using the same plusargs as the Iverilog TB."""

    def __init__(self, workspace: Path, output_dir: Path, jobs: int = 1) -> None:
        super().__init__(workspace, output_dir)
        self.jobs = max(1, jobs)
        self.obj_dir = output_dir / "verilator_obj"
        self.sim_bin = self.obj_dir / "profile_vlt"

    def compile(self) -> None:
        """Compile the Verilator binary once for all profiling tests."""
        self.output_dir.mkdir(parents=True, exist_ok=True)
        missing = [str(path) for path in self._rtl_files() if not path.exists()]
        if missing:
            raise FileNotFoundError("missing RTL/TB files:\n" + "\n".join(missing))

        cmd = [
            "verilator",
            "--binary",
            "--timing",
            "-Wno-fatal",
            "-Wno-TIMESCALEMOD",
            "-Wno-WIDTHTRUNC",
            "--top-module",
            "tb_riscv_tests",
            "-Mdir",
            str(self.obj_dir),
            "-o",
            "profile_vlt",
            "-j",
            str(self.jobs),
        ]
        cmd.extend(str(path) for path in self._rtl_files())
        result = subprocess.run(
            cmd,
            cwd=self.workspace,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        compile_log = self.output_dir / "compile.log"
        compile_log.write_text(result.stdout)
        if result.returncode != 0:
            raise RuntimeError(f"verilator compilation failed; see {compile_log}")

    def run_test(
        self,
        prepared: PreparedTest,
        *,
        max_cycles: Optional[int] = None,
        watchdog_cycles: Optional[int] = None,
        perf: bool = True,
        pc_guard: bool = True,
        led_trace: bool = False,
    ) -> SimRunResult:
        """Run one prepared test with the compiled Verilator binary."""
        spec = prepared.spec
        cycles = max_cycles if max_cycles is not None else spec.max_cycles
        watchdog = watchdog_cycles if watchdog_cycles is not None else spec.watchdog_cycles

        cmd = [
            str(self.sim_bin),
            f"+dram={prepared.dram_hex}",
            f"+test={spec.name}",
            f"+cycles={cycles}",
            f"+watchdog={watchdog}",
        ]
        cmd.extend(_irom_plusargs(prepared))
        if spec.stop_pc is not None:
            cmd.append(f"+stop_pc={spec.stop_pc:08x}")
        if perf:
            cmd.append("+perf")
        if pc_guard:
            cmd.append("+pc_guard")
        if led_trace:
            cmd.append("+led_trace")

        result = subprocess.run(
            cmd,
            cwd=self.workspace,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        prepared.log_file.parent.mkdir(parents=True, exist_ok=True)
        prepared.log_file.write_text(result.stdout)

        parsed = parse_result_line(result.stdout.splitlines())
        expected_stop_reason = "DONE_PC" if spec.stop_pc is not None else "LED_PASS"
        if spec.stop_pc is not None:
            parsed.setdefault("target_stop_pc", f"0x{spec.stop_pc:08x}")
        return SimRunResult(
            test_name=spec.name,
            irom_mode=prepared.irom_mode,
            expected_stop_reason=expected_stop_reason,
            command=cmd,
            returncode=result.returncode,
            log_file=prepared.log_file,
            status=str(parsed.get("status", "UNKNOWN")),
            stop_reason=str(parsed.get("stop_reason", "UNKNOWN")),
            cycles=parsed.get("cycles"),  # type: ignore[arg-type]
            raw_result=parsed,
        )
