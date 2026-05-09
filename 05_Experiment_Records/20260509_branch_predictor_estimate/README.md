# 20260509 Branch Predictor Estimate

## Purpose

Estimate whether a narrow branch-predictor change is worth RTL work before
editing the design.

This experiment targets the branch-heavy helper loops found in the baseline
assessment.  It compares the current software-model tournament predictor
against larger global-history variants and local-history variants, using the
functional COE branch stream.

## Scope

- No RTL changes.
- No timing or placement modeling.
- Conditional branches only; other CPI terms are taken from the baseline
  assessment.
- The `pc_oracle_*` rows are offline upper bounds that choose the better result
  per static branch PC.  They are not directly implementable predictors.

## Baseline

- Branch: `perf/assess-before-rtl`
- Starting commit: `cf471cc`
- Script under test: `02_Design/sim/riscv_tests/branch_predictor_estimator.py`
- Parallelism: 18 jobs where supported
- Baseline adjusted CPI from previous record: `0.957`
- Baseline weighted branch flush dCPI from previous record: `0.149`

## Commands

See `commands.sh`.

## Raw Logs

Raw outputs are kept locally under `raw/`:

- `branch_predictor_estimator_src0_src1_src2.log`

`raw/` is intentionally ignored by git.

## Results Summary

Formal run completed at `2026-05-09T17:59:41+08:00`.

Weighted aggregate across `src0/src1/src2`, 3,000,000 instructions per program:

| predictor | misses | miss% | flush dCPI | dCPI gain vs base |
|-----------|--------|-------|------------|-------------------|
| `base_tourn_128_g8` | 665405 | 27.2% | 0.1479 | 0.0000 |
| `tourn_128_g10` | 646287 | 26.5% | 0.1436 | 0.0042 |
| `tourn_128_g12` | 634164 | 26.0% | 0.1409 | 0.0069 |
| `tourn_256_g10` | 646294 | 26.5% | 0.1436 | 0.0042 |
| `tourn_256_g12` | 634171 | 26.0% | 0.1409 | 0.0069 |
| `local_128_h2` | 759572 | 31.1% | 0.1688 | -0.0209 |
| `local_128_h3` | 738363 | 30.2% | 0.1641 | -0.0162 |
| `local_128_h4` | 733026 | 30.0% | 0.1629 | -0.0150 |
| `local_128_h6` | 719028 | 29.4% | 0.1598 | -0.0119 |
| `local_256_h4` | 733029 | 30.0% | 0.1629 | -0.0150 |
| `local_256_h6` | 719031 | 29.4% | 0.1598 | -0.0119 |
| `pc_oracle_local_128_h4` | 657392 | 26.9% | 0.1461 | 0.0018 |
| `pc_oracle_local_128_h6` | 626002 | 25.6% | 0.1391 | 0.0088 |
| `pc_oracle_local_256_h6` | 626003 | 25.6% | 0.1391 | 0.0088 |

Per-program behavior of the best practical candidate, `tourn_128_g12`:

| program | base flush dCPI | candidate flush dCPI | dCPI gain |
|---------|-----------------|----------------------|-----------|
| `src0` | 0.1604 | 0.1400 | +0.0204 |
| `src1` | 0.1309 | 0.1253 | +0.0056 |
| `src2` | 0.1523 | 0.1574 | -0.0051 |

Interpretation:

- The current branch flush estimate from this run is `0.1479`, matching the
  previous baseline record (`~0.149`).
- Increasing global history from 8 to 12 bits is the best directly plausible
  change in this estimate, but the weighted CPI gain is only `0.0069`.
- With the previous adjusted CPI baseline of `0.957`, `0.0069` dCPI is roughly
  `0.7%` runtime improvement if frequency is unchanged.
- The same change is uneven: it helps `src0`, slightly helps `src1`, and hurts
  `src2`.
- Doubling BTB entries from 128 to 256 does not materially change the result in
  this model.
- Local-history predictors are net worse on the weighted result.  Even the
  offline per-PC oracle upper bound only reaches `0.0088` dCPI, roughly `0.9%`
  runtime improvement if frequency is unchanged.

## Decision

Do not start local-history branch-predictor RTL from this data.

Do not treat `GHR=12` as a compelling performance project by itself.  Its
estimated best-case weighted gain is below 1% runtime before accounting for any
Fmax, area, or implementation risk.  It is only worth considering if it can be
implemented as a very small, timing-neutral table-size change.

The next useful step should target a larger runtime lever than this branch
predictor variant set, or first produce a stronger estimate that clears an
explicit threshold before RTL work begins.
