# Frontend RAS Design Plan

## 1. Purpose

Add a small return-address stack (uRAS) to the current ABTB/PHT frontend so
that standard function returns can be predicted in Stage-1 instead of falling
through and redirecting from EX.

This document records the intended design direction. It does not authorize or
contain an RTL implementation.

## 2. Current Baseline

The existing frontend already provides most of the classification and recovery
infrastructure required by a RAS:

- `02_Design/rtl/core/id_stage_derive.sv` classifies:
  - `JAL/JALR` with `rd` equal to `x1` or `x5` as `CALL`;
  - `JALR x0, 0(x1/x5)` as `RET`.
- `02_Design/rtl/core/frontend/frontend_abtb.sv` defines `TYPE_RET` and accepts a
  per-bank return-valid and return-target input.
- `02_Design/rtl/core/cpu_top.sv` currently ties both ABTB return-valid inputs
  low and both return targets to zero.
- `02_Design/rtl/core/frontend/frontend_ftq.sv` currently includes only `JAL`, `CALL`,
  and conditional branches in canonical Stage-1 steering. A `RET` entry
  therefore falls through and is corrected by EX.
- A backend redirect clears the frontend queues and restarts prediction from
  the registered redirect target.

The 2026-06-29 COE reports show no selected-target mismatch, but this does not
mean return prediction is working. An unpredicted return is represented as
predicted-not-taken versus actual-taken and is therefore counted as a direction
error. In `new_without_Mext`, the difference between qualified PHT direction
errors and frontend redirects is about 10.5 million events and closely tracks
the confirmed JALR count. This makes return/JALR prediction the clearest
remaining target-side opportunity.

## 3. Recommended Final Architecture

Use an 8-entry, parameterized uRAS with two copies of predictor state:

1. **Speculative RAS**
   - Read by Stage-1.
   - Pushes when an accepted canonical prediction selects a `CALL`.
   - Pops when an accepted canonical prediction selects a valid `RET`.

2. **Confirmed RAS**
   - Updated only by the existing EX-confirmed CFI arbitration.
   - Uses the same fire, older-slot priority, and wrong-path suppression
     qualification as ABTB/PHT training.
   - Acts as the recovery source after a backend redirect.

On redirect, discard the speculative state and restore it from the confirmed
state after applying the redirecting CFI's confirmed RAS operation.

Conceptually:

```text
ABTB RET type + speculative RAS top
                  |
                  v
          canonical Stage-1 target

accepted CALL/RET prediction ---> speculative push/pop
confirmed CALL/RET in EX -------> confirmed push/pop
backend redirect ---------------> speculative := confirmed-next
```

The EX target comparison remains authoritative. A RAS error may reduce
performance but must never affect architectural correctness.

## 4. Why Two States

A confirmed-only RAS is simple but can be stale. The frontend may redirect into
a short leaf function and fetch its `RET` before the corresponding `CALL`
reaches EX, especially while the 8-entry fetch queue allows prediction to run
ahead.

Speculative push/pop makes the new state visible to the next target lookup. The
confirmed copy prevents wrong-path calls and returns from permanently
corrupting the predictor.

Because this core executes in order and fully flushes younger frontend work on
a redirect, a checkpoint per FQ entry is not required for the initial design.
When a CFI resolves in EX, every older CALL/RET has already passed the same
confirmed update point. The confirmed RAS is therefore a sufficient recovery
checkpoint.

## 5. Canonical Operation Rules

### 5.1 Prediction-time operations

A raw ABTB hit must never update the RAS. Update the speculative RAS only when
the CFI wins program-order arbitration and the BP0 request is accepted:

```text
spec_push = bp0_fire
         && stage1_steer_taken
         && stage1_steer_cfi_type == TYPE_CALL

spec_pop  = bp0_fire
         && stage1_steer_taken
         && stage1_steer_cfi_type == TYPE_RET
```

This prevents updates from:

- an unselected younger bank1 CFI;
- a blocked BP0 lookup;
- stale or merely matching ABTB metadata;
- a same-cycle backend redirect.

The CALL return address is the selected CFI PC plus four, not unconditionally
`current_pc + 4`. The selected bank determines the CFI PC.

### 5.2 Confirmed operations

At the existing EX-confirmed predictor update point:

- confirmed `CALL`: push `call_pc + 4`;
- confirmed `RET`: pop;
- other JALR: no RAS operation;
- trap, interrupt, and `MRET`: no RAS operation;
- an older flush suppresses every younger RAS operation.

The current single-CFI update arbitration also applies to the confirmed RAS.

### 5.3 Redirect priority

Backend redirect has priority over a new speculative operation. The recovery
state must include the confirmed operation of the redirecting CALL/RET:

```text
if redirect:
    speculative_state := confirmed_next_state
else if accepted canonical CALL/RET:
    speculative_state := speculative_next_state
```

The frontend must not restart from a stale pre-update RAS state.

## 6. Stack Organization

Initial recommendation:

- depth: 8 entries, parameterized;
- entry width: 32-bit return PC;
- `sp`: points to the next free entry;
- `count`: distinguishes empty, partially full, and full;
- top: `stack[sp - 1]`;
- push: write at `sp`, then increment `sp`;
- pop: decrement `sp`;
- empty pop: no state change and no RET prediction;
- full push: circularly overwrite the oldest entry, keep `count` saturated,
  and increment an overflow counter.

Two 8x32-bit copies consume about 512 state bits before pointers and counters.
This is small enough that a register or distributed-RAM implementation can be
selected using timing and utilization evidence.

Depth 16 is not justified until profiling shows an 8-entry overflow or nesting
limit problem.

## 7. Stage-1 Integration

For each ABTB bank:

- `TYPE_RET && ras_valid` becomes a taken candidate;
- the candidate target is the speculative RAS top;
- `TYPE_RET && !ras_valid` does not steer and falls through to EX correction.

The existing program-order rules remain unchanged:

- the first eligible instruction wins over a younger instruction;
- bank0 wins when it is the older selected taken CFI;
- when fetch starts at `PC[2] == 1`, bank1 is the first instruction;
- an owned bank0 branch predicted not-taken may still allow a younger bank1
  RET candidate to win.

Only one canonical CFI may perform a speculative RAS operation for one accepted
BP0 block.

## 8. Cycle and Edge Semantics

Normal predicted CALL:

```text
edge x:
    speculative RAS state is stable
cycle x:
    BP0 selects an ABTB CALL and computes return_pc = selected_call_pc + 4
edge x+1:
    if bp0_fire, push return_pc into the speculative RAS
cycle x+1:
    target-function prediction observes the new speculative top
```

Registered redirect recovery:

```text
edge x:
    the EX-confirmed CALL/RET updates the confirmed RAS
cycle x:
    the frontend observes the registered redirect and blocks normal BP0 update
edge x+1:
    clear frontend queues, install redirect PC, and restore speculative RAS
cycle x+1:
    redirected lookup observes the restored RAS
```

If implementation timing ever allows redirect lookup in the same cycle as the
confirmed update, use `confirmed_next` bypass rather than the old confirmed
top.

## 9. Initial Instruction Scope

The first implementation should preserve the current standard classification:

```text
JAL/JALR rd=x1/x5       -> CALL / push
JALR rd=x0, 0(x1/x5)   -> RET / pop
other JALR              -> no RAS operation
```

Full RISC-V coroutine hint behavior, including pop-then-push cases involving
different link registers, is a later extension. It should not complicate the
initial implementation unless a workload or compliance requirement needs it.

## 10. Required Observability

All counters must use accepted/confirmed events rather than held `valid`
levels.

Add at least:

- predicted CALL count;
- confirmed CALL count;
- RET ABTB lookup count;
- RET prediction count;
- RAS valid and underflow counts;
- correct RET target count;
- wrong RET target count;
- confirmed RET count;
- speculative recovery count;
- overflow count;
- maximum observed depth;
- redirects classified as conditional direction, ABTB miss, RET miss,
  ordinary indirect JALR, and wrong target.

After enabling RAS, `target_wrong` may become nonzero. Previously unpredicted
returns were counted as direction-to-taken errors; a wrong RAS top becomes a
target error. Success is measured by lower total frontend redirects and lower
cycles, not by keeping `target_wrong` at zero.

## 11. Verification Plan

Directed tests must cover:

1. one CALL followed by one RET;
2. nested calls and returns;
3. recursive depth up to and beyond the configured depth;
4. empty-stack RET;
5. full-stack overwrite behavior;
6. bank0 CALL/RET;
7. bank1 CALL/RET and `PC[2] == 1`;
8. bank0 not-taken branch followed by a bank1 RET;
9. wrong-path CALL restored after an older redirect;
10. wrong-path RET restored after an older redirect;
11. mispredicted CALL target with confirmed push;
12. mispredicted RET target with confirmed pop;
13. backend stall without duplicate speculative or confirmed operation;
14. redirect and confirmed RAS update in the same recovery sequence;
15. trap/interrupt/`MRET` preserving the interrupted call stack;
16. reset and invalid metadata producing no operation.

Existing EX correction must remain enabled in every test.

## 12. Implementation Phases

### Phase 1: Measurement and interface preparation

- Correct fire qualification in branch performance counters.
- Add per-CFI redirect classification.
- Add a `frontend_uras` interface without changing canonical steering.

### Phase 2: Confirmed RAS state

- Implement confirmed push/pop and underflow/overflow behavior.
- Connect existing decode classification through the EX update arbitration.
- Verify state correctness independently of prediction.

### Phase 3: Speculative prediction path

- Add the speculative state.
- Add canonical CALL push and RET pop.
- Make `TYPE_RET` a Stage-1 candidate using the speculative top.

### Phase 4: Recovery

- Restore speculative state from confirmed-next on every backend redirect.
- Verify wrong-path CALL/RET removal and same-sequence update ordering.

### Phase 5: Performance evaluation

- Run short directed branch/RAS benchmarks.
- Run representative COE workloads with and without M extension.
- Compare total cycles, frontend redirects, RET coverage, RAS target accuracy,
  overflow, utilization, and timing.

## 13. Acceptance Criteria

The RAS change is ready only when:

- all existing functional tests still pass;
- every RAS directed test passes;
- no wrong-path instruction changes confirmed RAS state;
- redirect recovery never exposes stale speculative state;
- a held BP0 or EX instruction cannot update a RAS twice;
- RET target errors are always corrected by EX;
- representative workloads show fewer frontend redirects;
- 8-entry overflow is either zero/negligible or explicitly justified;
- synthesis timing and resource impact are recorded.

## 14. Deferred Work

Do not combine the initial RAS change with:

- a general indirect-JALR target predictor;
- speculative GHR recovery;
- partial FQ/FTQ rollback;
- ABTB capacity or associativity changes;
- PHT size/history changes;
- complete coroutine hint support;
- further fetch-queue depth changes.

These are separate experiments with independent correctness and performance
questions.
