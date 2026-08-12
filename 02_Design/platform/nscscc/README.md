# NSCSCC / chiplab platform

The chiplab processor contract is implemented by `rtl/mycpu_top.v`:

- the required public module name is `core_top` (the reference file is also
  named `mycpu_top.v`);
- the wrapper itself uses Verilog-2001 syntax so Vivado can honor the required
  `.v` filename; implementation blocks remain SystemVerilog;
- reset PC is the LA32R boot address `0x1c00_0000`;
- the cacheable data-SRAM window is `0x1c08_0000`--`0x1c0f_ffff`;
- all instruction fetches, DCache refills/writebacks, and uncached data
  accesses leave the core through the single 32-bit AXI master;
- the AXI port is the AXI3-style chiplab shape, including `arid`, `awid`, and
  `wid`.

The NSCSCC DCache is 64 KiB, direct mapped, with 2048 sets and 32-byte lines.
It uses write-back plus write-allocate: cacheable stores update
the local line and set its dirty bit.  A dirty victim is first copied into a
private eight-word buffer; after its write command is accepted, the new-line
refill may run in parallel with the eight W beats and B response.  The DCache
still has one miss slot, so it accepts no later data-memory request until both
transactions finish.  Consecutive
store-hit/load-hit accesses to the same word use a one-cycle BRAM
read-after-write collision bypass; there is no DCache store buffer.

The ICache is 8 KiB, direct mapped, and uses 16-byte lines.  Its 512 sets use
two RAMB36s for the 1024 64-bit instruction/predecode rows.  An ICache
miss emits one four-beat WRAP read starting at the requested 64-bit block; the
first two returned words release the frontend while the other half of the line
continues filling.  DCache line refills use one eight-beat WRAP read
starting at the missed 32-bit word.  ICache tag/valid/refill hit decisions are
made from the BP request address and registered with the synchronous BRAM data,
so a responding local hit may be replaced by the next BP request at the same
clock edge.

The frontend ABTB has two instruction-position banks, 32 sets per bank, and
two ways per set (128 entries total).  `PC[7:3]` selects the set and the
nine-bit `PC[16:8]` tag suppresses the short-tag aliases observed in the perf
instruction traces; each entry retains its CFI type and 32-bit target.

`rtl/nscscc_axi_bridge.sv` is intentionally platform-owned.  ICache reads use
AXI ID 0 and DCache reads use ID 1, so one request from each cache may remain
outstanding and their R beats are routed by RID.  A same-cycle command tie
still gives DCache priority.  DCache writes use ID 2 and remain
single-outstanding.  Dirty-line writebacks may overlap both read IDs; uncached
and MMIO writes are explicitly unmarked and remain serialized against reads.
Internal write commands and 32-bit write-data beats are separate, so a DCache
line writeback does not require a 256-bit datapath through the wrapper.

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
