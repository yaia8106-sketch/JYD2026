# NSCSCC platform verification

Run the complete NSCSCC/LoongArch RTL boundary gate with:

```bash
bash functional/run_rtl_regression.sh
```

This gate is intentionally separate from the Chiplab official software
sign-off. The official 58-point `func` image and all 20 `perf` programs still
need to pass in the Chiplab simulation/CI environment; the RTL gate adds the
short, localized checks that those long programs do not diagnose precisely.

The aggregate gate includes:

- all 11 valid ALU operations over fixed edge operands and multiple random
  seeds, comparing the architectural and fast-forward copies against an
  independent semantic model;
- forwarding priority and load-repair matrices across both producer slots,
  both consumer slots and both operands, including repaired-EX interlocks,
  r0, same-destination WAW priority and multiple random seeds;
- CSR/SYSCALL/ERTN under artificial MEM backpressure, plus direct alignment,
  flush suppression and exactly-once commit checks;
- LoongArch decode, FTQ pairing, dual-issue `cpu_top`, BL, variable IROM,
  interrupts, MulDiv and redirect tests;
- all cache/AXI protocol tests described below and exact NSCSCC top-level
  elaboration in single- and dual-debug-commit configurations.

`functional/run_axi_bridge.sh` checks the platform bridge independently of the
ISA pipeline.  It covers four-beat critical-first WRAP refills, simultaneous
ICache-ID-0 and DCache-ID-1 reads, interleaved RID response routing,
DCache-priority arbitration, per-client read backpressure, read/write
serialization, independent AXI AW/W handshakes, eight-beat writeback, and ID-2
write-response routing.
It also checks that two completed-line ICache hits respond on consecutive
cycles, with the second request accepted on the first response edge.

`functional/run_icache_metadata.sh` isolates the ICache shortened-tag and
refill-predecode design. It covers all eight cached instruction classes,
lower- and upper-critical WRAP ordering, in-flight refill-buffer hits, pending
second-block requests, exact `{12-bit class, 8-bit tag}` LUTRAM layout,
same-index tag replacement, both edges of the `0x1c0xxxxx` allocation window,
outside-window nonallocation/preservation, and late refill errors suppressing
the atomic tag/class commit. It also resets a populated cache and proves that
valid-only reset safely contains intentionally unreset data/tag/class payload.

`functional/run_variable_irom.sh` verifies that the shared frontend retains
request metadata across arbitrary response latency and drops a stale AXI
response after redirect.  It also covers simultaneous F0 response and next-BP
request acceptance.

`functional/run_dcache_uncached.sh` checks that peripheral loads/stores use
single-beat AXI transactions, preserve byte strobes, wait for the response,
and never allocate a cache line.

`functional/run_dcache_writeback.sh` checks the NSCSCC write-back/write-allocate
policy.  It covers store hits remaining local, byte-store merge on allocation,
invalid-way preference, critical-word-first eight-beat WRAP refill, ordered
eight-beat dirty eviction, write-data backpressure, a following held request,
and preservation of an already acknowledged store across a pipeline flush.
It also checks that address bit 11 selects the upper half of the 8 KiB data
array
without aliasing the same-offset line in the lower half. A
directed same-word store-hit/load-hit pair checks the registered BRAM RAW
collision bypass and requires zero load stall.

`functional/run_core_compile.sh` elaborates the complete `core_top` using the
LoongArch-only NSCSCC file list.  It is a structural gate for the exact chiplab
top-level port contract in both the default and `CPU_2CMT` configurations.
