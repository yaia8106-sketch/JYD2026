#!/usr/bin/env python3
"""Small RV32I reference runner for COE differential checks."""

from __future__ import annotations

import argparse
from pathlib import Path

from coe_to_hex import parse_coe


IROM_BASE = 0x8000_0000
DRAM_BASE = 0x8010_0000
DRAM_SIZE = 0x0004_0000
LED_ADDR = 0x8020_0040


def u32(value: int) -> int:
    return value & 0xFFFF_FFFF


def s32(value: int) -> int:
    value &= 0xFFFF_FFFF
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


def sext(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def bimm(inst: int) -> int:
    return sext(
        ((inst >> 31) & 0x1) << 12
        | ((inst >> 7) & 0x1) << 11
        | ((inst >> 25) & 0x3F) << 5
        | ((inst >> 8) & 0xF) << 1,
        13,
    )


def jimm(inst: int) -> int:
    return sext(
        ((inst >> 31) & 0x1) << 20
        | ((inst >> 12) & 0xFF) << 12
        | ((inst >> 20) & 0x1) << 11
        | ((inst >> 21) & 0x3FF) << 1,
        21,
    )


class Ref:
    def __init__(self, irom_words: list[str], dram_words: list[str]):
        self.irom = [int(w, 16) for w in irom_words]
        self.mem: dict[int, int] = {}
        self.regs = [0] * 32
        self.pc = IROM_BASE
        self.led_value: int | None = None

        for index, word_s in enumerate(dram_words):
            word = int(word_s, 16)
            addr = DRAM_BASE + index * 4
            for lane in range(4):
                self.mem[addr + lane] = (word >> (8 * lane)) & 0xFF

    def load_u8(self, addr: int) -> int:
        if DRAM_BASE <= addr < DRAM_BASE + DRAM_SIZE:
            return self.mem.get(addr, 0)
        return 0

    def load(self, addr: int, size: int, unsigned: bool) -> int:
        value = 0
        for lane in range(size):
            value |= self.load_u8(addr + lane) << (8 * lane)
        if unsigned:
            return value
        return u32(sext(value, size * 8))

    def store(self, addr: int, size: int, value: int) -> None:
        if addr == LED_ADDR:
            self.led_value = u32(value)
        if DRAM_BASE <= addr < DRAM_BASE + DRAM_SIZE:
            for lane in range(size):
                self.mem[addr + lane] = (value >> (8 * lane)) & 0xFF

    def fetch(self) -> int:
        index = (self.pc - IROM_BASE) >> 2
        if index < 0 or index >= len(self.irom):
            return 0x0000_0013
        return self.irom[index]

    def step(self) -> dict[str, int]:
        pc = self.pc
        inst = self.fetch()
        opcode = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        funct3 = (inst >> 12) & 0x7
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F
        funct7 = (inst >> 25) & 0x7F
        imm_i = sext(inst >> 20, 12)
        imm_s = sext(((inst >> 25) << 5) | rd, 12)

        next_pc = u32(pc + 4)
        wen = 0
        wdata = 0

        a = self.regs[rs1]
        b = self.regs[rs2]

        if opcode == 0x37:  # LUI
            wen, wdata = 1, inst & 0xFFFF_F000
        elif opcode == 0x17:  # AUIPC
            wen, wdata = 1, u32(pc + (inst & 0xFFFF_F000))
        elif opcode == 0x6F:  # JAL
            wen, wdata = 1, u32(pc + 4)
            next_pc = u32(pc + jimm(inst))
        elif opcode == 0x67:  # JALR
            wen, wdata = 1, u32(pc + 4)
            next_pc = u32(a + imm_i) & ~1
        elif opcode == 0x63:  # BRANCH
            taken = False
            if funct3 == 0x0:
                taken = a == b
            elif funct3 == 0x1:
                taken = a != b
            elif funct3 == 0x4:
                taken = s32(a) < s32(b)
            elif funct3 == 0x5:
                taken = s32(a) >= s32(b)
            elif funct3 == 0x6:
                taken = a < b
            elif funct3 == 0x7:
                taken = a >= b
            else:
                raise RuntimeError(f"bad branch funct3 {funct3} at {pc:08x}")
            if taken:
                next_pc = u32(pc + bimm(inst))
        elif opcode == 0x03:  # LOAD
            addr = u32(a + imm_i)
            if funct3 == 0x0:
                wdata = self.load(addr, 1, False)
            elif funct3 == 0x1:
                wdata = self.load(addr, 2, False)
            elif funct3 == 0x2:
                wdata = self.load(addr, 4, True)
            elif funct3 == 0x4:
                wdata = self.load(addr, 1, True)
            elif funct3 == 0x5:
                wdata = self.load(addr, 2, True)
            else:
                raise RuntimeError(f"bad load funct3 {funct3} at {pc:08x}")
            wen = 1
        elif opcode == 0x23:  # STORE
            addr = u32(a + imm_s)
            if funct3 == 0x0:
                self.store(addr, 1, b)
            elif funct3 == 0x1:
                self.store(addr, 2, b)
            elif funct3 == 0x2:
                self.store(addr, 4, b)
            else:
                raise RuntimeError(f"bad store funct3 {funct3} at {pc:08x}")
        elif opcode == 0x13:  # OP-IMM
            shamt = rs2
            if funct3 == 0x0:
                wdata = u32(a + imm_i)
            elif funct3 == 0x2:
                wdata = 1 if s32(a) < imm_i else 0
            elif funct3 == 0x3:
                wdata = 1 if a < u32(imm_i) else 0
            elif funct3 == 0x4:
                wdata = u32(a ^ u32(imm_i))
            elif funct3 == 0x6:
                wdata = u32(a | u32(imm_i))
            elif funct3 == 0x7:
                wdata = u32(a & u32(imm_i))
            elif funct3 == 0x1 and funct7 == 0x00:
                wdata = u32(a << shamt)
            elif funct3 == 0x5 and funct7 == 0x00:
                wdata = a >> shamt
            elif funct3 == 0x5 and funct7 == 0x20:
                wdata = u32(s32(a) >> shamt)
            else:
                raise RuntimeError(f"bad op-imm at {pc:08x}: {inst:08x}")
            wen = 1
        elif opcode == 0x33:  # OP
            shamt = b & 0x1F
            if funct3 == 0x0 and funct7 == 0x00:
                wdata = u32(a + b)
            elif funct3 == 0x0 and funct7 == 0x20:
                wdata = u32(a - b)
            elif funct3 == 0x1 and funct7 == 0x00:
                wdata = u32(a << shamt)
            elif funct3 == 0x2 and funct7 == 0x00:
                wdata = 1 if s32(a) < s32(b) else 0
            elif funct3 == 0x3 and funct7 == 0x00:
                wdata = 1 if a < b else 0
            elif funct3 == 0x4 and funct7 == 0x00:
                wdata = u32(a ^ b)
            elif funct3 == 0x5 and funct7 == 0x00:
                wdata = a >> shamt
            elif funct3 == 0x5 and funct7 == 0x20:
                wdata = u32(s32(a) >> shamt)
            elif funct3 == 0x6 and funct7 == 0x00:
                wdata = u32(a | b)
            elif funct3 == 0x7 and funct7 == 0x00:
                wdata = u32(a & b)
            else:
                raise RuntimeError(f"bad op at {pc:08x}: {inst:08x}")
            wen = 1
        elif opcode == 0x0F:  # FENCE
            pass
        elif opcode == 0x73:
            raise RuntimeError(f"system/unimp at {pc:08x}: {inst:08x}")
        else:
            raise RuntimeError(f"unknown instruction at {pc:08x}: {inst:08x}")

        if wen and rd != 0:
            self.regs[rd] = u32(wdata)
        self.regs[0] = 0
        self.pc = next_pc

        return {
            "pc": pc,
            "inst": inst,
            "rd": rd,
            "wen": wen,
            "data": u32(wdata),
            "next_pc": next_pc,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--irom-coe", type=Path, required=True)
    parser.add_argument("--dram-coe", type=Path, required=True)
    parser.add_argument("--commits", type=int, default=2000)
    parser.add_argument("--trace", type=Path, required=True)
    args = parser.parse_args()

    ref = Ref(parse_coe(args.irom_coe), parse_coe(args.dram_coe))
    args.trace.parent.mkdir(parents=True, exist_ok=True)

    with args.trace.open("w", encoding="ascii") as out:
        for _ in range(args.commits):
            event = ref.step()
            out.write(
                "REF pc={pc:08x} rd={rd:d} wen={wen:d} data={data:08x} inst={inst:08x}\n".format(
                    **event
                )
            )
            if ref.led_value is not None:
                break

    with args.trace.open(encoding="ascii") as count_in:
        commits_written = sum(1 for _ in count_in)
    led = "none" if ref.led_value is None else f"0x{ref.led_value:08x}"
    print(f"[REF] commits_written={commits_written} led={led} trace={args.trace}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
