# Microarchitecture Decision Map

> This document is an optimization-oriented navigation map for the current CPU.
> It complements `00_AI_Rules/architecture.md`: that file describes what the RTL
> currently does; this file records why the important choices matter, what they
> protect, and what must be checked before changing them.

## Current Mental Model

The CPU is an RV32IM + minimal Zicsr/Trap, five-stage, in-order dual-issue
pipeline:

```text
IF -> ID -> EX -> MEM -> WB
          \-> S1 shadow pipe for selected slot1 instructions
```

Slot 0 is the full pipe. Slot 1 is deliberately narrower. The current design is
already shaped by a hard tradeoff:

```text
runtime ~= cycles * clock_period
```

Many decisions reduce critical-path pressure even when they add a cycle of
penalty. The current timing report shows the front-end is nearly at the timing
limit, especially around `PC -> IROM` address/data paths. That makes front-end
changes high risk unless they remove logic from that path or add a register
stage.

## 1. Front-End / Fetch

### Decisions

- IROM is split into two 32-bit BRAM banks, even and odd, so the CPU can fetch a
  64-bit window each cycle.
- Bank addresses are precomputed or carried in predictor/replay state instead of
  recomputing full 32-bit targets on the fast IROM path.
- Sequential fetch uses precomputed `pc_plus4`, `pc_plus8`, and `pc_plus12`
  state.
- Normal branch/JAL/JALR correction is registered and replayed one cycle later,
  rather than driving IROM immediately from EX branch resolution.
- `skip_inst0` logic is effectively disabled. The current front-end relies on
  aggressive `+8` fetch plus `inst_buf` handling instead.
- Stall recovery uses an instruction hold register because BRAM output is tied
  to the address sampled one cycle earlier.

### What This Protects

- **Fmax:** keeps `PC/predict/redirect -> IROM address` short enough for the
  target clock.
- **Correctness:** prevents stale BRAM data from being consumed after stalls.
- **IPC:** two-bank fetch keeps the pipeline supplied when the program is
  sequential and dual-issue eligible.

### Red Zones

- Do not add new decode-dependent logic into the same-cycle IROM address path.
- Do not re-enable or modify `skip_inst0` without checking both function and
  timing; it touches fetch-window selection and predictor snapshots.
- Do not make EX branch resolution directly feed IROM unless the expected cycle
  reduction is compared against Fmax loss.
- Be careful with CE/allowin feedback into PC or IROM address registers; timing
  reports already show these paths are tight.

### If You Change This Area

Run:

```bash
cd 02_Design/riscv_tests
bash run_all.sh
MAX_CYCLES=1500000 WATCHDOG_CYCLES=150000 bash run_coe_diff.sh current src0 src1 src2
```

Also run Vivado timing, because this area directly affects the current critical
paths:

```bash
vivado -mode tcl \
  -log 03_Analysis/vivado_work/vivado.log \
  -journal 03_Analysis/vivado_work/vivado.jou \
  -source 03_Analysis/run_vivado_flow.tcl \
  -tclargs "$PWD" current 18
```

## 2. Instruction Buffer / Fetch Window Alignment

### Decisions

- When the pair cannot issue together, the second fetched instruction can be
  stored in `inst_buf`.
- `inst_buf_before_window` handles the case where the buffered instruction is
  before the current IROM window due to aggressive `+8` fetch.
- Predictor snapshots for buffered instructions are saved with the buffer.

### What This Protects

- **IPC:** avoids discarding the second instruction after single-issue cycles.
- **Correctness:** keeps PC, instruction, and branch-prediction metadata aligned.
- **Fmax:** avoids rebuilding predictor state through longer live mux chains.

### Red Zones

- `inst_buf_valid`, `inst_buf_before_window`, and held-instruction selection are
  easy to break during front-end rewrites.
- Flush must clear buffered wrong-path instructions.
- Buffered predictor state must remain paired with the buffered instruction.

### Useful Tests

- `inst_buffer`
- `flush_instbuf`
- `instbuf_stall`
- `pc_align`
- `bp_dual`

## 3. Dual-Issue Policy

### Decisions

- Slot 0 is the universal slot.
- Slot 1 currently supports ALU-like instructions and conditional branches.
- Slot 1 does not support load/store, JAL/JALR, RV32M, CSR, ECALL, or MRET.
- Same-packet RAW from slot0 to slot1 blocks dual issue.
- WAW does not block dual issue; writeback priority makes slot1 override slot0.
- System instructions are serialized into slot0.

### What This Protects

- **Fmax:** slot1 remains lightweight.
- **Correctness:** avoids a second LSU/MMIO request, link-write/redirect
  ordering issues, and precise CSR/trap complications.
- **Verification scope:** each slot1 feature has local, bounded behavior.

### Current Performance Risk

The instruction mix has many load/store and jump instructions. Because slot1 is
narrow, many natural adjacent instruction pairs cannot dual issue. This likely
caps IPC before the front-end fetch width is fully used.

### Red Zones

- Adding slot1 LSU affects DCache/MMIO arbitration, load-use detection,
  forwarding, writeback, exceptions, and flush.
- Adding slot1 JAL/JALR affects link writeback, redirect priority, RAS/BTB
  update, and wrong-path squash.
- Adding slot1 M affects multi-cycle EX stall and writeback ordering.
- Adding slot1 CSR/trap is not a small feature; it affects precise side effects.

### Useful Tests

- `dual_alu`
- `raw_block`
- `waw`
- `waw_fwd`
- `loaduse_dual`
- `slot1_branch`
- Existing slot1 expansion tests if those features are enabled later:
  `slot1_load`, `slot1_store`, `slot1_jal`

## 4. Branch Prediction / Redirect

### Decisions

- L0 prediction happens in IF for fast target selection.
- L1 verification happens in ID for tournament direction checking.
- Slot0 control flow is predicted and verified; slot1 branch is resolved later
  in EX and redirects through registered replay when taken.
- BTB, BHT/GShare/selector, RAS, and JALR sidecar state are kept separate.
- System redirects are not predictor updates.
- Wrong-path instructions must not update predictor state.

### What This Protects

- **IPC:** reduces taken-branch and return penalties.
- **Fmax:** keeps complex correction off the IROM fast path when possible.
- **Correctness:** separates architectural redirects from prediction learning.

### Red Zones

- `id_bp_redirect_raw` is intentionally raw/ungated in the slot1 squash path; a
  gated redirect can deadlock with doomed load-use hazards.
- Slot1 branch prediction sounds attractive but touches two-instruction fetch
  semantics, branch metadata, replay priority, and predictor update ordering.
- RAS changes need call/return classification to stay consistent with x1/x5 link
  conventions.

### Useful Tests

- `bp_stress`
- `bp_dual`
- `branch_dual`
- `branch_dual_flush`
- `branch_fwd_matrix`
- `ras_overflow`
- COE prefix diff for long-run confidence

## 5. Forwarding / Hazards

### Decisions

- Forwarding uses explicit priority across S1/S0 EX, MEM, and WB sources.
- Slot1 writeback has priority over slot0 for same-cycle WAW.
- Same-cycle slot0-to-slot1 RAW is not forwarded; it is blocked at issue.
- Load-use normally stalls. A narrow repair path allows selected S0 ALU consumers
  to proceed when S0_MEM load data is ready.
- Branch/JALR/load/store/S1 consumers still wait for the needed value.

### What This Protects

- **Correctness:** avoids consuming unavailable load results or late repair
  values.
- **Fmax:** avoids routing late load/repair data into branch target, JALR target,
  LSU address, or slot1 operand paths.
- **IPC:** the repair path removes one common load-use bubble without making all
  consumers timing-critical.

### Red Zones

- Forwarding priority must preserve slot1-over-slot0 WAW semantics.
- Expanding load-use repair beyond S0 ALU needs timing evidence.
- Branch/JALR operand readiness is front-end related; shortening branch penalty
  can lengthen critical paths.

### Useful Tests

- `fwd_s1`
- `waw_fwd`
- `loaduse_cross`
- `branch_fwd_matrix`
- `csr_forwarding`

## 6. Execute / RV32M

### Decisions

- RV32M runs only in slot0.
- Multiply is DSP-oriented and pipelined internally.
- Divide/remainder use iterative radix-2 logic.
- EX stalls while M operations are not done.

### What This Protects

- **Area/Fmax:** avoids duplicating or widening expensive multiply/divide paths.
- **Correctness:** keeps multi-cycle result ordering simple.

### Performance Risk

If benchmark hot paths use division or dense multiplication, M wait cycles may
become a visible CPI component. This should be measured before optimizing.

### Useful Tests

- `m_ext`
- performance profiling counters for `MUL/DIV wait`

## 7. Memory / DCache / MMIO

### Decisions

- DCache is a 2KB, 2-way, write-through, write-allocate cache with a store
  buffer.
- Cacheable memory is the DRAM region only.
- MMIO is routed separately and treated conservatively.
- Slot1 currently avoids LSU, so there is only one architectural LSU request per
  cycle.

### What This Protects

- **Correctness:** MMIO ordering and single LSU semantics stay simple.
- **Fmax:** DCache tag/data/refill logic is isolated from front-end issue width.
- **Area:** small cache footprint.

### Performance Risk

The program mix is load/store heavy. DCache miss behavior, store buffer stalls,
and load-use bubbles may dominate once front-end branch behavior is acceptable.

### Red Zones

- Slot1 LSU requires arbitration and precise ordering with slot0 LSU.
- MMIO store/load hazards must remain conservative unless the external protocol
  is fully understood.
- Cache refill and pipeline stall must stay synchronized; wrong-path memory
  requests need careful treatment.

### Useful Tests

- `dcache_stress`
- `dcache_dual`
- `sb_stress`
- `ld_st`
- `st_ld`
- COE suite/diff

## 8. CSR / Trap / MRET

### Decisions

- CSR/ECALL/MRET are slot0-only and serialized.
- Unsupported CSRs read zero and ignore writes.
- ECALL and MRET generate system redirects through the dedicated CSR/trap path.
- CSR side effects are gated by valid and correct-path execution.

### What This Protects

- **Precise architectural state:** traps and CSR writes are not allowed to happen
  from wrong-path or slot1-shadow instructions.
- **Verification scope:** minimal M-mode behavior is testable without full
  privilege complexity.

### Red Zones

- Do not dual-issue system instructions without a full precise side-effect
  design.
- Flush must win over stall for wrong-path CSR/trap side effects.
- DCache stalls before trap/CSR commit are correctness-sensitive.

### Useful Tests

- `zicsr_basic`
- `zicsr_edge`
- `csr_forwarding`
- `csr_trap_stall`
- `trap_mret`
- `trap_slot1`
- `trap_flush`
- `trap_nested`

## 9. Timing / Fmax

### Current Known Issue

The latest timing report shows very small slack at the target clock. The
front-end paths are especially tight:

- `Pre_IF(PC) -> IROM_Data`
- `Pre_IF(PC) -> IROM_Addr`
- `IF/ID -> IROM_Addr`
- PC/IF buffer CE and allowin related paths

This means an optimization that reduces CPI can still lose total runtime if it
lowers Fmax.

### Rules of Thumb

- If a change touches `pc_reg`, `irom_addr_ctrl`, `branch_predictor`,
  `if_stage_buffer`, redirect, or IF/ID allowin/flush, assume timing must be
  rerun.
- Prefer moving work across stage boundaries over adding mux levels to the
  current front-end fast path.
- Compare runtime, not just cycles:

```text
runtime ~= cycles * clock_period
```

## 10. Profiling / Baseline Gap

The current generated profile report is invalid because the profiled runs timed
out. Before making performance RTL changes, get a reliable baseline:

- cycles
- committed instructions
- CPI
- dual-issue rate
- slot1 blocked reasons
- branch mispredict rate
- DCache stall/miss behavior
- store-buffer stalls
- load-use stalls
- M-unit wait cycles

Without this, optimization choices are mostly guesses.

## 11. How To Use This Map

When considering an optimization, write down:

```text
Hypothesis:
  What benchmark or stall class should improve?

Expected gain:
  cycles, CPI, or Fmax impact

Likely cost:
  front-end timing, slot1 complexity, DCache ordering, verification scope

Touched areas:
  modules and tests from this document

Kill criteria:
  e.g. less than 1% runtime gain, WNS loss larger than expected, or new failures
```

Then choose the smallest experiment that tests the hypothesis.

## 12. Reference Core Lessons

### biRISC-V

Most relevant for this project. It is an FPGA-friendly RV32 in-order dual-issue
core with configurable bypassing, branch prediction, two integer ALUs, one LSU,
and one out-of-pipeline divider.

Useful ideas:

- explicit issue policy and FU routing
- configurable bypass knobs
- BTB/BHT/GShare/RAS front-end
- simple, readable Verilog structure

### RISu064

Useful for studying a more aggressive in-order-issue design:

- separate issue stage
- richer operand-ready and WAW checks
- dual integer pipes plus LSU/MULDIV pipes
- speculative branch history and RAS handling for two fetched instructions

### VexRiscv / VexiiRiscv

Useful mainly for timing tradeoffs:

- add front-end injector stages to improve Fmax
- register branch/PC calculation even if it costs a cycle
- decide where load, shift, and branch results are injected based on timing

### NaxRiscv / RSD / A2O

Useful for long-term architecture study, but too far from the current design for
near-term changes. They should not drive short-cycle contest optimization unless
the project intentionally pivots toward OoO or non-blocking memory.

