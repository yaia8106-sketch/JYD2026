# 02_Design directory ownership

The design tree is split by dependency boundary:

- `rtl/`: platform-independent CPU, memory, and ISA RTL.
- `platform/nscscc/`: NSCSCC/chiplab integration RTL.
- `verification/common/`: ISA-independent directed RTL tests.
- `verification/loongarch/`: LoongArch decode, execution, and privileged tests.
- `verification/platform/`: board-wrapper smoke tests and behavioral IP models.
- `model/`: architectural exploration models.
- `docs/`: design notes.

The common pipeline consumes semantic structures from
`rtl/common/cpu_defs.sv`. LoongArch is the processor's sole ISA. Its instruction
encoding, immediate extraction, frontend predecode, and privileged state live
under `rtl/isa/loongarch/`; the common pipeline does not contain an ISA selector.

`rtl/filelists/cpu.f` is the single CPU manifest. The NSCSCC platform filelist
adds the cache, AXI, and competition wrapper around that LoongArch core.
