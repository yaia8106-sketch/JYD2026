# PhysicalTwin_XC7A35T

Board-only Vivado project wrapper for the JYD2025 digital twin CPU.

This directory owns only the physical-board adaptation:

- `board_top.sv`: XC7A35T board top.
- `mmio_bridge.sv`: physical-board MMIO display adapter with the same module name/interface used by `student_top`.
- inferred ROM/RAM replacements for the original Vivado memory IP.
- pin constraints and project Tcl.

The CPU implementation itself is referenced directly from `../02_Design/rtl`, so CPU changes are maintained in one place.

## Board Mapping

- Clock: `D4`, 50 MHz.
- Reset switch: `P10`, active high in this project. Switch high resets the CPU, switch low runs it.
- Seven-segment display: common-anode assumption, segment and digit-select outputs are active low.
- LEDs: active high.

With reset asserted, the board enters a simple I/O self-test: the six seven-segment digits show `123456`, and the LEDs show `01011010` from left to right.

The six seven-segment digits show the low 24 bits of the runtime counter value written by the program to `SEG_ADDR` (`0x8020_0020`), as six hex digits.

LEDs are mapped left to right as status flags:

- Reset asserted: `01011010`.
- Boot / pre-counter: `00000001`.
- Runtime counter enabled: `00000011`.
- PASS pattern observed on the original digital twin LED register: `10000000`.
- FAIL pattern observed on the original digital twin LED register: `01000000`.

## Build

From the workspace root:

```bash
./PhysicalTwin_XC7A35T/run_build.sh
```

The default COE set is `02_Design/coe/dual_issue/current`. To use another set:

```bash
./PhysicalTwin_XC7A35T/run_build.sh dual_issue/src0
```

Generated Vivado files go under `PhysicalTwin_XC7A35T/vivado/`. Generated memory files go under `PhysicalTwin_XC7A35T/generated/`.

After a successful build, `run_build.sh` also exports the bitstream to an English-only path for tools that cannot open the Chinese workspace path:

```text
/home/anokyai/CPU_Workspace_Artifacts/PhysicalTwin_XC7A35T/board_top.bit
/home/anokyai/CPU_Workspace_Artifacts/PhysicalTwin_XC7A35T/board_top_dual_issue_current.bit
```

## Notes

- The physical build runs the CPU at the board clock, 50 MHz. This is the conservative bring-up target; a PLL/MMCM can be added later if this board needs a faster local run.
- `DRAM4MyOwn` is inferred as 16K x 32, or 64 KiB. The current `dual_issue/current` and `dual_issue/src0/1/2` COE sets only contain 12 initialized DRAM words, so the cropped region contains no non-zero initialization data.
- Current Vivado DRC reports RAMB async-control warnings because the shared CPU/DCache RTL uses asynchronous reset registers that drive inferred BRAM address pins. This project leaves the CPU RTL unchanged to avoid changing behavior during the board port.
