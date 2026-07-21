# NSCSCC / chiplab platform

The chiplab processor contract is implemented by `rtl/mycpu_top.v`:

- the required public module name is `core_top` (the reference file is also
  named `mycpu_top.v`);
- the wrapper itself uses Verilog-2001 syntax so Vivado can honor the required
  `.v` filename; implementation blocks remain SystemVerilog;
- reset PC is the LA32R boot address `0x1c00_0000`;
- the cacheable data-SRAM window is `0x1c08_0000`--`0x1c0f_ffff`;
- all instruction fetches, DCache refills/write-through stores, and uncached
  data accesses leave the core through the single 32-bit AXI master;
- the AXI port is the AXI3-style chiplab shape, including `arid`, `awid`, and
  `wid`.

`rtl/nscscc_axi_bridge.sv` is intentionally platform-owned.  It converts each
64-bit frontend request into a two-beat AXI read, arbitrates it against the
DCache backend (data has priority), and uses the shared single-outstanding AXI
transport.

ISA and platform selection stay separate:

- `platform/nscscc/filelist.f` includes `loongarch_cpu.f` and the AXI path;
- `platform/jyd/filelist.f` includes `riscv_cpu.f` and the direct-BRAM path;
- neither platform relies on a global `RISCV`/`LOONGARCH` preprocessor switch.

The inferred `rtl/dcache_data_ram.sv` replaces the JYD Vivado-project-specific
DCache RAM IP for chiplab builds.  Official SoC RTL, constraints, and board IP
remain external to this project-owned wrapper.

Integration must use the complete `platform/nscscc/filelist.f` source set, not
copy `mycpu_top.v` by itself.  The stock chiplab simulator Makefiles only glob
flat `IP/myCPU/*.v` sources, so point their source list at this manifest (or add
the manifest's `.sv` files to the chiplab/Vivado project) when replacing the
reference CPU.

This change completes the platform/transport layer only.  The current
LoongArch core still has the privileged/TLB/cache-maintenance exclusions listed
in `verification/loongarch/README.md`; the AXI wrapper does not hide or replace
that remaining architectural work.
