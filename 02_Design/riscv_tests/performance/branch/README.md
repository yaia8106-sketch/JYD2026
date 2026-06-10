# Branch Predictor Diagnosis

This directory contains a branch-predictor-focused wrapper around the existing
performance flow.  It is a diagnosis entry, not a correctness gate.

Typical use:

```bash
bash performance/branch/run_branch_diag.sh --build
bash performance/branch/run_branch_diag.sh --suite minimal --no-compile
bash performance/branch/run_branch_diag.sh --suite existing --baseline work/perf/old_branch_diag/rv32ui
bash performance/branch/run_branch_diag.sh --coe --coe-tests "current new_with_Mext"
```

Outputs are written under `work/perf/branch_diag_<timestamp>_<git>/`:

- `rv32ui/summary.csv,json`: raw `parse_perf.py` output.
- `coe/summary.csv,json`: optional COE raw output.
- `branch_summary.csv,json`: branch-only derived metrics.
- `branch_findings.md`: heuristic issue classes.
- `branch_compare.csv`: optional baseline comparison.

Default `standard` suite runs the minimal microbenchmarks first, then existing
branch-oriented tests.  Use `--suite minimal` for fast direction/BTB isolation
and `--suite existing` for interaction coverage.
