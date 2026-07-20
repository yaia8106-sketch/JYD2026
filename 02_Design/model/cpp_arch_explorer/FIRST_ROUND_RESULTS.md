# First-Round Predictor Results

Run configuration:

```text
Programs: current, src0, src1, src2, new_without_Mext, new_with_Mext
PHT: 256 x 2-bit, weakly not-taken initialization
GHR: 8-bit committed history
Path history: 8-bit where enabled
Update delays: 0, 2, 4, 6 dynamic instructions
Mispredict resolution barrier: enabled
```

## Functional-model validation

The C++ retired-instruction and conditional-branch counts exactly match the
existing complete RTL COE run for `current`, `src1`, and `src2`.

The three timer-sensitive images differ slightly because C++ advances `mtime`
per retired instruction while RTL advances it per clock cycle:

| Program | C++ retired | RTL retired | Difference |
| --- | ---: | ---: | ---: |
| `current` | 30,761,367 | 30,761,367 | 0 |
| `src0` | 1,417,756,421 | 1,417,795,152 | -38,731 |
| `src1` | 1,304,110,682 | 1,304,110,682 | 0 |
| `src2` | 1,849,101,614 | 1,849,101,614 | 0 |
| `new_without_Mext` | 783,164,727 | 783,192,037 | -27,310 |
| `new_with_Mext` | 380,344,553 | 380,347,284 | -2,731 |

The largest relative retired-instruction difference is below 0.004%.  These
differences must still be remembered when comparing timer-sensitive programs.

## Aggregate results

The best configurations by summed six-program direction mispredictions were:

| Delay | Best | Mispredictions | Accuracy | GSHARE mispredictions |
| ---: | --- | ---: | ---: | ---: |
| 0 | `LAST_TARGET_BRANCH` | 208,525,439 | 80.6798% | 215,085,704 |
| 2 | `LAST_TARGET_BRANCH` | 205,748,040 | 80.9371% | 210,553,123 |
| 4 | `GSHARE` | 209,619,713 | 80.5784% | 209,619,713 |
| 6 | `LAST_TARGET_ALL_CFI` | 222,050,458 | 79.4267% | 225,619,852 |

`LAST_TARGET` is the only first-round path family that remains competitive.
Its gain is not robust across programs or delays.  For example, at delay 6 the
all-CFI form improves `src0` and `new_without_Mext` by about 6% relative to
GSHARE, but regresses `src2` by about 3.4%.

All rolling 8-bit path signatures performed poorly with the 256-entry table.
Their aggregate accuracy was roughly 64-66%, consistent with excessive
context fragmentation and destructive aliasing.  They should not be moved to
RTL in their current form.

## Current conclusion

Do not change the RTL predictor from GSHARE based on this first sweep.

The only justified next experiment is a narrower, lower-fragmentation form of
last-target contribution, such as 2-4 target-history bits mixed into selected
index bits, followed by the same six-program/delay robustness check.  A 512-row
upper-bound comparison may show whether the failures are capacity-related, but
it carries a larger dual-read LUTRAM cost and is not automatically an RTL
candidate.

