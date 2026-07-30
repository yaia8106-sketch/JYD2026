# NSCSCC platform verification

`functional/run_axi_bridge.sh` checks the platform bridge independently of the
ISA pipeline.  It covers four-beat critical-first WRAP refills, simultaneous
ICache-ID-0 and DCache-ID-1 reads, interleaved RID response routing,
DCache-priority arbitration, per-client read backpressure, read/write
serialization, independent AXI AW/W handshakes, four-beat writeback, and ID-2
write-response routing.
It also checks that two completed-line ICache hits respond on consecutive
cycles, with the second request accepted on the first response edge.

`functional/run_variable_irom.sh` verifies that the shared frontend retains
request metadata across arbitrary response latency and drops a stale AXI
response after redirect.  It also covers simultaneous F0 response and next-BP
request acceptance.

`functional/run_dcache_uncached.sh` checks that peripheral loads/stores use
single-beat AXI transactions, preserve byte strobes, wait for the response,
and never allocate a cache line.

`functional/run_dcache_writeback.sh` checks the NSCSCC write-back/write-allocate
policy.  It covers store hits remaining local, byte-store merge on allocation,
invalid-way preference, critical-word-first WRAP refill, ordered four-beat
dirty eviction, write-data backpressure, a following held request, and
preservation of an already acknowledged store across a pipeline flush.  A
directed same-word store-hit/load-hit pair checks the registered BRAM RAW
collision bypass and requires zero load stall.

`functional/run_core_compile.sh` elaborates the complete `core_top` using the
LoongArch-only NSCSCC file list.  It is a structural gate for the exact chiplab
top-level port contract in both the default and `CPU_2CMT` configurations.
