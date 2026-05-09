# 20260509 Pipeline Split Estimate

## Purpose

Estimate whether pipeline splitting can improve program runtime before any RTL
rewrite.

The metric is runtime, not CPI alone:

```text
runtime = cycles * clock_period
```

So a split is useful only if the shorter clock period can pay for any extra
cycles from branch, fetch, or bypass latency.

## Scope

- No RTL changes.
- Use the current routed 200 MHz timing report from the baseline assessment.
- Parse architecture-level timing path classes and remove path classes as
  optimistic upper bounds for candidate splits.
- Run a COE control-dependency estimate for adjacent ALU-to-branch/JALR cases.
- External FPGA CPU references are used as design-pattern guidance, not as
  proof that the same result will occur in this RTL.

## Baseline

- Branch: `perf/assess-before-rtl`
- Starting commit: `2f0f367`
- Timing source: `05_Experiment_Records/20260509_baseline_assessment/raw/stage_timing_report.txt`
- Official small perf total cycles: `3645`
- Current target period: `5.000ns`
- Current post-route WNS at 5ns: `+0.049ns`
- Script under test: `03_Timing_Analysis/pipeline_split_estimator.py`
- Parallelism: 18 jobs where supported

## Commands

See `commands.sh`.

## Raw Logs

Raw outputs are kept locally under `raw/`:

- `pipeline_split_estimator.log`

`raw/` is intentionally ignored by git.

## External References

Useful design patterns from FPGA-oriented cores:

- VexiiRiscv documents FPGA tuning knobs that deliberately relax BTB, branch
  side effects, fetch fork, and LSU fork paths by pushing work into later
  stages when those paths dominate Fmax.
- VexRiscv exposes similar instruction-bus timing options:
  `cmdForkOnSecondStage`, `busLatencyMin`, and `injectorStage`, explicitly
  trading extra frontend/branch latency for Fmax.
- NaxRiscv reaches for high Fmax with a much broader architecture: automatic
  pipelining, separated fetch/frontend/execution/LSU pipelines, non-blocking
  DCache, and BTB+GShare+RAS.  This is evidence that high Fmax is a system
  architecture problem, not a one-register patch.
- PicoRV32 shows the opposite extreme: very high Fmax is possible on 7-series
  FPGA, but average CPI is around 4, so high frequency alone is not equivalent
  to better runtime.
- Ibex max-performance configuration uses a Branch Target ALU and optional
  writeback stage; its pipeline docs also make the branch-target latency trade
  explicit.

Reference URLs:

- https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html
- https://github.com/SpinalHDL/VexRiscv
- https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html
- https://github.com/YosysHQ/picorv32
- https://github.com/lowRISC/ibex
- https://ibex-core.readthedocs.io/en/latest/03_reference/pipeline_details.html

## Results Summary

Formal run completed at `2026-05-09T18:08:57+08:00`.

Timing-cut upper bounds from the current routed report:

| scenario | cut paths | period bound | Fmax bound | clock gain vs 5ns | extra official cycles allowed | limiting remaining path |
|----------|-----------|--------------|------------|-------------------|-------------------------------|-------------------------|
| `baseline` | 0 | 4.951ns | 202.0 MHz | 0.99% | 36 | `ID/EX->ID/EX` |
| `frontend_if1_boundary` | 6 | 4.951ns | 202.0 MHz | 0.99% | 36 | `ID/EX->ID/EX` |
| `relax_ex_redirect` | 4 | 4.951ns | 202.0 MHz | 0.99% | 36 | `ID/EX->ID/EX` |
| `id_branch_dep_wait` | 4 | 4.891ns | 204.5 MHz | 2.23% | 81 | `Pre_IF(PC)->IROM(BRAM)` |
| `frontend_plus_id_branch` | 10 | 4.876ns | 205.1 MHz | 2.54% | 92 | `IF/ID->ID/EX` |
| `cut_top_5_paths` | 5 | 4.807ns | 208.0 MHz | 4.01% | 146 | `MEM/WB->ID/EX` |
| `cut_top_10_paths` | 10 | 4.724ns | 211.7 MHz | 5.84% | 212 | `DCache(FSM)->IROM(BRAM)` |
| `cut_all_slack_lt_0p5` | 23 | 4.469ns | 223.8 MHz | 11.88% | 433 | `BP(pred)->IF/ID` |

Important detail: `extra official cycles allowed` uses the current official
small perf total, `3645 cycles`.  For example, a 2.54% clock gain can only
afford about `92` extra cycles before runtime stops improving.

COE issue-pattern estimate for adjacent EX-result to ID control dependencies:

| program | insts | issues | branch S0-ALU dep | branch S1-ALU dep | JALR S0-ALU dep | JALR S1-ALU dep | S0 control dep |
|---------|-------|--------|-------------------|-------------------|-----------------|-----------------|----------------|
| `src0` | 3000000 | 2425530 | 378052 | 30746 | 1 | 2 | 378053 |
| `src1` | 3000000 | 2326657 | 155931 | 83346 | 1 | 2 | 155932 |
| `src2` | 3000000 | 2292090 | 548156 | 11692 | 1 | 2 | 548157 |
| weighted | 9000000 | 7044277 | 1082139 | 125784 | 3 | 6 | 1082142 |

If every S0 EX-ALU to branch/JALR case gained a one-cycle wait, the COE prefix
cost would be about `0.1202 CPI`.  That is far larger than the CPI penalty that
the plausible timing gains can afford:

| clock gain | affordable dCPI at baseline CPI 0.957 |
|------------|----------------------------------------|
| 2.23% | ~0.021 |
| 2.54% | ~0.024 |
| 5.84% | ~0.056 |
| 11.88% | ~0.114 |

The broad `cut_all_slack_lt_0p5` upper bound is also not a realistic small
change.  It means eliminating 23 tight architecture-level path classes,
including frontend, ID branch/bypass, DCache, and memory-address paths.

Cross-check against branch redirect latency:

- Official small tests have `213` branch mispredicts in `3645` cycles.
- Removing same-cycle EX redirect would likely add about one cycle per
  EX-corrected mispredict, already around `+213` cycles.
- The `relax_ex_redirect` timing upper bound only allows `36` extra cycles, so
  that trade is runtime-negative.
- On the COE branch stream, adding one cycle to every current branch miss would
  cost `665405 / 9000000 = 0.0739 CPI`, also above the plausible small-split
  budget.

## Decision

Do not start a narrow frontend split or simple EX-redirect relaxation.

Do not add an ALU-to-branch wait just to cut the current worst path; the
estimated CPI cost is too high.

The data says a worthwhile pipeline project must be a broad, deliberate
redesign, not a one-register patch:

- split the frontend request/response boundary,
- remove ID-stage branch precompute dependence on same-cycle EX forwarding,
- retime the IF/ID to ID/EX decode/control path,
- address DCache and memory-address control paths,
- then re-evaluate branch/load penalties as part of the design.

Given the current project state, the next step should be either:

1. Build a more detailed proposal for a broad `IF1/IF2 + ID/EX-control retime`
   design with expected cycle penalties per benchmark, or
2. Shift away from pipeline splitting and look for a performance lever with a
   clearer cycles win at the fixed 200 MHz clock.
