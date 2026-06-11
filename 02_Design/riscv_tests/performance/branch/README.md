# Branch Predictor Diagnosis

This directory contains a branch-predictor-focused diagnosis entry.  It is not a
correctness gate, and it does not call the short-perf or coe-perf scripts.
Instead, it compiles and runs `tb_riscv_tests` directly, then reuses the shared
perf parser/reporting tools.

Typical use:

```bash
bash performance/branch/run_branch_diag.sh --build
bash performance/branch/run_branch_diag.sh --suite minimal --no-compile
bash performance/branch/run_branch_diag.sh --suite existing --baseline work/perf/old_branch_diag/rv32ui
bash performance/branch/run_branch_diag.sh --coe-max-cycles 5000000
```

Outputs are written under `work/perf/branch_diag_<timestamp>_<git>/`:

- `rv32ui/summary.csv,json`: raw `parse_perf.py` output.
- `coe/summary.csv,json`: COE raw output for all contest programs.
- `branch_summary.csv,json`: branch-only derived metrics.
- `branch_findings.md`: heuristic issue classes.
- `branch_compare.csv`: optional baseline comparison.

Default `standard` suite runs the minimal microbenchmarks first, then existing
branch-oriented tests.  It always runs the full contest COE program set in
parallel as the final phase, one simv process per contest program.  Use
`--suite minimal` for fast direction/BTB isolation and `--suite existing` for
interaction coverage.

Relationship to the other performance scripts:

- `performance/short/run_perf.sh` (`short-perf`): short riscv-tests profiling.
- `performance/long/run_coe_perf.sh` (`run-perf` / `coe-perf`): full contest COE profiling.
- `performance/branch/run_branch_diag.sh` (`branch-diag`): branch-only
  diagnosis over selected riscv-tests plus the full contest COE set.

Both `coe-perf` and `branch-diag` run all contest programs every time.  Each
launches one simulation process per contest program, so the default contest COE
phase has six parallel jobs: `current`, `src0`, `src1`, `src2`,
`new_without_Mext`, and `new_with_Mext`.
