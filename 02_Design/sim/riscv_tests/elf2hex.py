#!/usr/bin/env python3
"""
elf2hex.py - Convert riscv-tests ELF to IROM/DRAM hex files for $readmemh.

Usage: python3 elf2hex.py <elf_file> <irom.hex> <dram.hex>

Memory map:
  IROM: 0x80000000 (code)  → irom.hex (word 0 = addr 0x80000000)
  DRAM: 0x80100000 (data)  → dram.hex (word 0 = addr 0x80100000)
"""

import subprocess
import struct
import sys
import os

OBJCOPY = 'riscv64-unknown-elf-objcopy'


def bin_to_memh(bin_path, hex_path):
    """Convert raw binary to Verilog $readmemh format (one 32-bit word per line)."""
    with open(bin_path, 'rb') as f:
        data = f.read()

    # Pad to 4-byte boundary
    pad = (4 - len(data) % 4) % 4
    data += b'\x00' * pad

    with open(hex_path, 'w') as f:
        for i in range(0, len(data), 4):
            word = struct.unpack('<I', data[i:i+4])[0]  # little-endian
            f.write(f'{word:08x}\n')

    return len(data) // 4  # number of words


def extract_sections(elf, bin_out, section_flags):
    """Use objcopy to extract specific sections to binary."""
    cmd = [OBJCOPY, '-O', 'binary']
    for s in section_flags:
        cmd += ['-j', s]
    cmd += [elf, bin_out]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        # Section might not exist, create empty file
        with open(bin_out, 'wb'):
            pass
    return os.path.exists(bin_out) and os.path.getsize(bin_out) > 0


def elf_to_hex(elf, irom_hex, dram_hex):
    """Convert ELF to separate IROM and DRAM hex files."""

    # --- Extract IROM (text sections → 0x80000000) ---
    irom_bin = elf + '.irom.tmp'
    try:
        has_text = extract_sections(elf, irom_bin, ['.text.init', '.text'])
        if has_text:
            n_words = bin_to_memh(irom_bin, irom_hex)
            print(f'  IROM: {n_words} words ({n_words * 4} bytes)')
        else:
            print('  WARNING: no text sections found')
            with open(irom_hex, 'w') as f:
                f.write('00000013\n')  # NOP
    finally:
        if os.path.exists(irom_bin):
            os.remove(irom_bin)

    # --- Extract DRAM (tohost + data sections → 0x80100000) ---
    dram_bin = elf + '.dram.tmp'
    try:
        has_data = extract_sections(elf, dram_bin, ['.tohost', '.data', '.bss'])
        if has_data:
            n_words = bin_to_memh(dram_bin, dram_hex)
            print(f'  DRAM: {n_words} words ({n_words * 4} bytes)')
        else:
            # No data section — create minimal file with tohost = 0
            with open(dram_hex, 'w') as f:
                f.write('00000000\n')
            print('  DRAM: 1 word (tohost only)')
    finally:
        if os.path.exists(dram_bin):
            os.remove(dram_bin)


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <elf> <irom.hex> <dram.hex>")
        sys.exit(1)

    elf_file = sys.argv[1]
    if not os.path.exists(elf_file):
        print(f"ERROR: ELF file not found: {elf_file}")
        sys.exit(1)

    print(f'Converting: {os.path.basename(elf_file)}')
    elf_to_hex(elf_file, sys.argv[2], sys.argv[3])
