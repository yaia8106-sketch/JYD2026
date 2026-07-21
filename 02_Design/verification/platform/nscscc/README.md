# NSCSCC platform verification

`functional/run_axi_bridge.sh` checks the platform bridge independently of the
ISA pipeline.  It covers the two-beat 64-bit IROM fetch, DCache-priority
arbitration, a four-beat DCache refill, read backpressure, independent AXI AW/W
handshakes, and write-response routing.

`functional/run_variable_irom.sh` verifies that the shared frontend retains
request metadata across arbitrary response latency and drops a stale AXI
response after redirect.

`functional/run_dcache_uncached.sh` checks that peripheral loads/stores use
single-beat AXI transactions, preserve byte strobes, wait for the response,
and never allocate a cache line or enter the cacheable store buffer.

`functional/run_core_compile.sh` elaborates the complete `core_top` using the
LoongArch-only NSCSCC file list.  It is a structural gate for the exact chiplab
top-level port contract in both the default and `CPU_2CMT` configurations.
