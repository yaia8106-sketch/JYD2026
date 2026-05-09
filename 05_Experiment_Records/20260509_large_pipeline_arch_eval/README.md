# 20260509 Large Pipeline Architecture Evaluation

## Purpose

Evaluate whether a broad pipeline redesign could improve program runtime before
any RTL work begins.

This is deliberately larger than the previous narrow split estimate.  It asks:

- How many current timing path classes must be retimed to reach common target
  periods such as 4.8ns, 4.5ns, 4.25ns, or 4.0ns?
- What CPI/cycle penalty would common high-Fmax architecture moves introduce?
- What Fmax is needed for those moves to be runtime-positive?

The target metric is:

```text
runtime = cycles * clock_period
```

## Scope

- No RTL changes.
- Use the current routed timing path report from the baseline assessment.
- Use `src0/src1/src2` COE functional streams, 3,000,000 instructions each.
- Use official small benchmark cycles and branch miss counts from the baseline
  raw perf log.
- External FPGA CPU references are used as design-pattern guidance only.

## Baseline

- Branch: `perf/assess-before-rtl`
- Starting commit: `5d85b33`
- Timing source: `05_Experiment_Records/20260509_baseline_assessment/raw/stage_timing_report.txt`
- Perf source: `05_Experiment_Records/20260509_baseline_assessment/raw/run_perf_default.log`
- COE baseline adjusted CPI: `0.957`
- Official small perf total cycles: `3645`
- Current target period: `5.000ns`
- Current post-route WNS at 5ns: `+0.049ns`
- Script under test: `03_Timing_Analysis/large_pipeline_arch_estimator.py`
- Parallelism: 18 jobs where supported

## Commands

See `commands.sh`.

## Raw Logs

Raw outputs are kept locally under `raw/`:

- `large_pipeline_arch_estimator.log`

`raw/` is intentionally ignored by git.

## External Reference Takeaways

The external FPGA cores point to the same general lesson: high Fmax is achieved
by designing the whole pipeline around delayed/registered frontend and control
paths, not by inserting one register in a finished timing-critical loop.

- VexiiRiscv documents tuning knobs that relax BTB, branch side-effect, fetch
  fork, and LSU fork paths.
- VexRiscv exposes instruction-bus timing options such as
  `cmdForkOnSecondStage`, `busLatencyMin`, and `injectorStage`.
- NaxRiscv uses a broad high-Fmax architecture with separated frontend,
  execution, LSU, and automatic pipelining concepts.
- PicoRV32 shows that high FPGA Fmax alone is not enough; CPI can dominate
  runtime.
- Ibex documents explicit branch-target and writeback-stage tradeoffs.

Reference URLs:

- https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html
- https://github.com/SpinalHDL/VexRiscv
- https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html
- https://github.com/YosysHQ/picorv32
- https://ibex-core.readthedocs.io/en/latest/03_reference/pipeline_details.html

## Results Summary

Formal run completed at `2026-05-09T18:14:43+08:00`.

### Retiming Depth

Current routed timing says the amount of architecture-level retiming grows
quickly as the target period drops:

| target period | target Fmax | path classes over target |
|---------------|-------------|--------------------------|
| 5.000ns | 200.0 MHz | 0 |
| 4.900ns | 204.1 MHz | 1 |
| 4.800ns | 208.3 MHz | 6 |
| 4.600ns | 217.4 MHz | 16 |
| 4.500ns | 222.2 MHz | 23 |
| 4.250ns | 235.3 MHz | 33 |
| 4.000ns | 250.0 MHz | 36 |

The first six classes blocking 4.8ns are:

- `ID/EX->ID/EX`
- `Pre_IF(PC)->IROM(BRAM)`
- `IF/ID->ID/EX`
- `IROM(BRAM)->IF/ID`
- `RegFile->ID/EX`
- `MEM/WB->ID/EX`

This confirms that a large redesign must cover frontend, decode/control,
branch/bypass, and writeback-to-ID paths together.

### Branch Prediction Cost

COE branch stream, `src0/src1/src2`, 3,000,000 instructions each:

| program | insts | branches | taken | L0 misses | L1 misses | L0/L1 disagreements |
|---------|-------|----------|-------|-----------|-----------|---------------------|
| `src0` | 3000000 | 719969 | 406533 | 264742 | 240603 | 117157 |
| `src1` | 3000000 | 825171 | 414272 | 206730 | 196331 | 82378 |
| `src2` | 3000000 | 897581 | 563210 | 269081 | 228471 | 137471 |
| weighted | 9000000 | 2442721 | 1384015 | 740553 | 665405 | 337006 |

Current L1 effective branch miss density is `665405 / 9000000 = 0.0739`
misses per instruction.  Therefore, making EX redirect one cycle later costs
about `+0.0739 CPI` if L1/tournament prediction behavior is preserved.

If a frontend redesign degrades prediction to L0-only and resolves those misses
one cycle later, the estimated CPI penalty becomes `+0.0990`.  If the redesign
is worse and creates one bubble on every taken branch, the penalty becomes
`+0.1538 CPI`, which is effectively disqualifying unless Fmax improves
dramatically.

### COE Runtime Thresholds

Baseline for this table: `CPI=0.957`, `period=5.000ns`.

| scenario | dCPI | break-even period | break-even Fmax | speedup at 4.469ns | speedup at 4.250ns | speedup at 4.000ns |
|----------|------|-------------------|-----------------|--------------------|--------------------|--------------------|
| frontend preserves predicted flow | 0.0000 | 5.000ns | 200.0 MHz | +11.88% | +17.65% | +25.00% |
| registered redirect, keep L1 | 0.0739 | 4.641ns | 215.5 MHz | +3.86% | +9.21% | +16.04% |
| registered redirect, L0-only | 0.0990 | 4.531ns | 220.7 MHz | +1.39% | +6.62% | +13.28% |
| ID branch dependency wait | 0.1202 | 4.442ns | 225.1 MHz | -0.61% | +4.52% | +11.05% |
| taken-branch fetch bubble | 0.1538 | 4.308ns | 232.1 MHz | -3.61% | +1.36% | +7.69% |

Interpretation:

- A simple frontend split only matters if it reaches a lower period without
  adding bubbles.  The previous narrow estimate says it does not.
- A realistic broad redesign that keeps L1 prediction and adds one cycle to
  branch-miss redirect must reach at least `215.5 MHz` to break even on COE.
- Hitting about `223.8 MHz` (`4.469ns`, the optimistic "cut all slack <0.5ns"
  bound from the previous estimate) gives only `+3.86%` COE runtime improvement
  under the good case.
- Hitting about `235 MHz` (`4.250ns`) gives a more meaningful `+9.21%`, but the
  current report says that requires retiming `33` path classes.

### Official Small Tests

From the baseline perf log:

| metric | value |
|--------|-------|
| official cycles | 3645 |
| branch count | 994 |
| branch misses | 213 |

Redirect-latency break-even:

| extra model | extra cycles | break-even period | break-even Fmax |
|-------------|--------------|-------------------|-----------------|
| +1 per branch miss | 213 | 4.724ns | 211.7 MHz |
| +2 per branch miss | 426 | 4.477ns | 223.4 MHz |
| +1 per all branches | 994 | 3.929ns | 254.5 MHz |

## Decision

Large pipeline work is only worth considering if the design goal is explicit:

- preserve predicted fetch flow,
- preserve L1/tournament-quality prediction or replace it with something at
  least as good,
- accept at most one extra cycle on actual branch misses,
- target at least `225 MHz`, with `235 MHz` as the first target that has a
  compelling runtime margin.

Reject these as standalone RTL tasks:

- frontend split that does not address `ID/EX->ID/EX` and `IF/ID->ID/EX`,
- EX redirect relaxation without a broad retime,
- ALU-to-branch wait insertion,
- pipelined BTB design that creates one bubble for every taken branch.

The only plausible large direction is a planned `IF1/IF2 + EX branch compare +
registered redirect + ID/control retime + memory/control retime` redesign.  It
should not start as an open-ended RTL rewrite.  The next step must be a design
contract with:

- exact new stage boundaries,
- branch penalty target,
- predicted-fetch strategy,
- list of path classes intended to be cut,
- minimum Fmax gate (`>=225 MHz`, preferably `>=235 MHz`),
- rollback rule if early Vivado timing does not clear the gate.
