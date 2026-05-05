#!/usr/bin/env python3
"""将单发射 32-bit irom.coe 拆分为双发射 slot0/slot1 两个 coe 文件。

slot0 = inst[0], inst[2], inst[4], ...  (偶数地址，低 word)
slot1 = inst[1], inst[3], inst[5], ...  (奇数地址，高 word)

用法:
    python3 split_coe.py <input_irom.coe> <output_dir>
    python3 split_coe.py current/irom.coe dual_issue/current/
"""
import sys
import os

def split_coe(input_path, output_dir):
    os.makedirs(output_dir, exist_ok=True)

    with open(input_path, 'r') as f:
        lines = f.read().strip().split('\n')

    # Skip header lines
    data_lines = []
    for line in lines:
        line = line.strip()
        if line.startswith('memory_initialization_radix') or line.startswith('memory_initialization_vector'):
            continue
        if line:
            # Remove trailing comma or semicolon
            data_lines.append(line.rstrip(',;'))

    # Pad to even count
    if len(data_lines) % 2 != 0:
        data_lines.append('00000013')  # NOP

    slot0 = [data_lines[i] for i in range(0, len(data_lines), 2)]
    slot1 = [data_lines[i] for i in range(1, len(data_lines), 2)]

    def write_coe(path, words):
        with open(path, 'w') as f:
            f.write('memory_initialization_radix=16;\n')
            f.write('memory_initialization_vector=\n')
            for i, w in enumerate(words):
                sep = ';' if i == len(words) - 1 else ','
                f.write(f'{w}{sep}\n')

    write_coe(os.path.join(output_dir, 'irom_slot0.coe'), slot0)
    write_coe(os.path.join(output_dir, 'irom_slot1.coe'), slot1)
    print(f'{input_path}: {len(data_lines)} insts -> slot0={len(slot0)}, slot1={len(slot1)} -> {output_dir}')

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <input_irom.coe> <output_dir>')
        sys.exit(1)
    split_coe(sys.argv[1], sys.argv[2])
