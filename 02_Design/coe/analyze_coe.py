#!/usr/bin/env python3
"""分析 COE 文件中的 RV32I 指令分布"""

import os, sys, glob

# RV32I opcode → 指令名映射
OPCODE_MAP = {
    0b0110111: 'LUI',
    0b0010111: 'AUIPC',
    0b1101111: 'JAL',
    0b1100111: 'JALR',
}

BRANCH_FUNCT3 = {0:'BEQ', 1:'BNE', 4:'BLT', 5:'BGE', 6:'BLTU', 7:'BGEU'}
LOAD_FUNCT3   = {0:'LB', 1:'LH', 2:'LW', 4:'LBU', 5:'LHU'}
STORE_FUNCT3  = {0:'SB', 1:'SH', 2:'SW'}
ALU_I_FUNCT3  = {0:'ADDI', 1:'SLLI', 2:'SLTI', 3:'SLTIU', 4:'XORI', 5:'SRLI/SRAI', 6:'ORI', 7:'ANDI'}
ALU_R_FUNCT3  = {0:'ADD/SUB', 1:'SLL', 2:'SLT', 3:'SLTU', 4:'XOR', 5:'SRL/SRA', 6:'OR', 7:'AND'}

# 指令类型分组
TYPE_MAP = {
    'LUI':'U-type', 'AUIPC':'U-type',
    'JAL':'J-type', 'JALR':'I-type',
    'BEQ':'B-type', 'BNE':'B-type', 'BLT':'B-type', 'BGE':'B-type', 'BLTU':'B-type', 'BGEU':'B-type',
    'LB':'Load', 'LH':'Load', 'LW':'Load', 'LBU':'Load', 'LHU':'Load',
    'SB':'Store', 'SH':'Store', 'SW':'Store',
    'ADDI':'ALU-I', 'SLLI':'ALU-I', 'SLTI':'ALU-I', 'SLTIU':'ALU-I',
    'XORI':'ALU-I', 'SRLI/SRAI':'ALU-I', 'ORI':'ALU-I', 'ANDI':'ALU-I',
    'ADD/SUB':'ALU-R', 'SLL':'ALU-R', 'SLT':'ALU-R', 'SLTU':'ALU-R',
    'XOR':'ALU-R', 'SRL/SRA':'ALU-R', 'OR':'ALU-R', 'AND':'ALU-R',
    'ECALL/EBREAK':'System', 'FENCE':'System', 'UNKNOWN':'UNKNOWN',
}

def decode_inst(hex_str):
    """解码一条 RV32I 指令"""
    try:
        val = int(hex_str.strip().rstrip(',;'), 16)
    except ValueError:
        return 'UNKNOWN'
    
    opcode = val & 0x7F
    funct3 = (val >> 12) & 0x7
    
    if opcode in OPCODE_MAP:
        return OPCODE_MAP[opcode]
    elif opcode == 0b1100011:  # Branch
        return BRANCH_FUNCT3.get(funct3, 'UNKNOWN')
    elif opcode == 0b0000011:  # Load
        return LOAD_FUNCT3.get(funct3, 'UNKNOWN')
    elif opcode == 0b0100011:  # Store
        return STORE_FUNCT3.get(funct3, 'UNKNOWN')
    elif opcode == 0b0010011:  # ALU immediate
        return ALU_I_FUNCT3.get(funct3, 'UNKNOWN')
    elif opcode == 0b0110011:  # ALU register
        return ALU_R_FUNCT3.get(funct3, 'UNKNOWN')
    elif opcode == 0b1110011:  # ECALL/EBREAK
        return 'ECALL/EBREAK'
    elif opcode == 0b0001111:  # FENCE
        return 'FENCE'
    elif val == 0:  # NOP (encoded as all zeros, not standard but common in padding)
        return 'ADDI'  # NOP = ADDI x0, x0, 0
    else:
        return 'UNKNOWN'

def analyze_coe(filepath):
    """分析单个 COE 文件"""
    counts = {}
    total = 0
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('memory') or line.startswith('//'):
                continue
            # 每行一条指令（hex）
            inst_name = decode_inst(line)
            counts[inst_name] = counts.get(inst_name, 0) + 1
            total += 1
    return counts, total

def print_report(name, counts, total):
    """打印单个文件的分析报告"""
    print(f"\n### {name}（共 {total} 条指令）\n")
    
    # 按类型汇总
    type_counts = {}
    for inst, cnt in counts.items():
        t = TYPE_MAP.get(inst, 'UNKNOWN')
        type_counts[t] = type_counts.get(t, 0) + cnt
    
    # 按指令名排序输出
    print("| 指令 | 类型 | 数量 | 占比 |")
    print("|------|------|-----:|-----:|")
    for inst in sorted(counts.keys(), key=lambda x: -counts[x]):
        cnt = counts[inst]
        pct = cnt / total * 100
        t = TYPE_MAP.get(inst, 'UNKNOWN')
        print(f"| {inst} | {t} | {cnt} | {pct:.1f}% |")
    
    # 类型汇总
    print(f"\n**类型汇总：**\n")
    print("| 类型 | 数量 | 占比 |")
    print("|------|-----:|-----:|")
    for t in sorted(type_counts.keys(), key=lambda x: -type_counts[x]):
        cnt = type_counts[t]
        pct = cnt / total * 100
        print(f"| {t} | {cnt} | {pct:.1f}% |")

# 分析所有目录
base = os.path.dirname(os.path.abspath(__file__))
dirs = ['current', 'src0', 'src1', 'src2']

for d in dirs:
    coe_path = os.path.join(base, d, 'irom.coe')
    if os.path.exists(coe_path):
        counts, total = analyze_coe(coe_path)
        print_report(d, counts, total)
    else:
        print(f"\n### {d} — 文件不存在\n")
