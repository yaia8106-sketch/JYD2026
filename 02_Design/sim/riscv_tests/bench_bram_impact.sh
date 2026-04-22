#!/bin/bash
# ============================================================
# bench_bram_impact.sh
# 测试 DCache data_mem 如果换 BRAM 会导致多少性能损失
#
# 原理：在 DCache FSM 中把 S_DONE 拆成 S_DONE_RD + S_DONE 两拍
#       模拟 BRAM 同步读的额外 1 cycle 延迟
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RTL_DIR="$(cd "../../rtl" && pwd)"
WORK_DIR="work"
HEX_DIR="work/hex"
DCACHE_ORIG="$RTL_DIR/dcache.sv"
DCACHE_BRAM="$WORK_DIR/dcache_bram_sim.sv"

TESTS="simple add addi sub and andi or ori xor xori \
       sll slli srl srli sra srai \
       slt slti sltiu sltu \
       beq bne blt bge bltu bgeu \
       jal jalr lui auipc \
       lb lbu lh lhu lw sb sh sw \
       ld_st st_ld bp_stress coprime dcache_test"

RTL_FILES="
    $RTL_DIR/cpu_defs.sv
    $RTL_DIR/pc_reg.sv $RTL_DIR/next_pc_mux.sv $RTL_DIR/if_id_reg.sv
    $RTL_DIR/decoder.sv $RTL_DIR/imm_gen.sv $RTL_DIR/regfile.sv
    $RTL_DIR/forwarding.sv $RTL_DIR/alu_src_mux.sv $RTL_DIR/id_ex_reg.sv
    $RTL_DIR/alu.sv $RTL_DIR/branch_unit.sv $RTL_DIR/branch_predictor.sv
    $RTL_DIR/mem_interface.sv $RTL_DIR/ex_mem_reg.sv $RTL_DIR/mem_wb_reg.sv
    $RTL_DIR/wb_mux.sv $RTL_DIR/cpu_top.sv
    $SCRIPT_DIR/tb_riscv_tests.sv"

mkdir -p "$WORK_DIR"

# ================================================================
#  Phase 1: 跑当前 FF 实现，收集 cycle 数
# ================================================================
echo "========================================"
echo "  Phase 1: 当前 FF 实现 (baseline)"
echo "========================================"

SIM_FF="$WORK_DIR/bench_ff_sim"
iverilog -g2012 -o "$SIM_FF" $RTL_FILES "$DCACHE_ORIG" 2>&1 | tail -3
echo ""

declare -A ff_cycles
for t in $TESTS; do
    irom="$HEX_DIR/rv32ui-p-${t}.irom.hex"
    dram="$HEX_DIR/rv32ui-p-${t}.dram.hex"
    [ -f "$irom" ] || continue
    line=$(vvp -N "$SIM_FF" "+irom=$irom" "+dram=$dram" "+test=$t" "+cycles=50000" 2>&1 \
           | grep -E "^\[(PASS|FAIL|TIMEOUT)\]" | head -1)
    cycles=$(echo "$line" | grep -oP '\(\K[0-9]+')
    status=$(echo "$line" | grep -oP '^\[\K\w+')
    ff_cycles[$t]="${cycles:-0}"
    printf "  %-16s %s  %6s cycles\n" "$t" "$status" "${cycles:-N/A}"
done

# ================================================================
#  Phase 2: 生成 BRAM 模拟版 DCache (S_DONE 多一拍)
# ================================================================
echo ""
echo "========================================"
echo "  Phase 2: BRAM 模拟 (S_DONE +1 cycle)"
echo "========================================"

# 用 sed 修改 DCache:
# 1. 添加 S_DONE_RD 状态
# 2. S_REFILL_WAIT 最后一拍 → S_DONE_RD (而不是 S_DONE)
# 3. S_DONE_RD → S_DONE
# 4. cpu_ready 在 S_DONE_RD 时为 0
cp "$DCACHE_ORIG" "$DCACHE_BRAM"

# 修改状态枚举：添加 S_DONE_RD
sed -i 's/S_SB_DRAIN$/S_DONE_RD,\n        S_SB_DRAIN/' "$DCACHE_BRAM"

# S_REFILL_WAIT 最后一拍 → S_DONE_RD
sed -i 's/state_nxt = S_DONE;/state_nxt = S_DONE_RD;/' "$DCACHE_BRAM"

# 添加 S_DONE_RD → S_DONE 转换 (在 S_DONE: 行之前)
sed -i '/S_DONE:/i\            S_DONE_RD:\n                state_nxt = S_DONE;' "$DCACHE_BRAM"

# flush 也要处理 S_DONE_RD
sed -i 's/state == S_REFILL || state == S_REFILL_WAIT || state == S_DONE/state == S_REFILL || state == S_REFILL_WAIT || state == S_DONE_RD || state == S_DONE/' "$DCACHE_BRAM"

echo "[INFO] Generated $DCACHE_BRAM"

SIM_BRAM="$WORK_DIR/bench_bram_sim"
iverilog -g2012 -o "$SIM_BRAM" $RTL_FILES "$DCACHE_BRAM" 2>&1 | tail -3
echo ""

declare -A bram_cycles
for t in $TESTS; do
    irom="$HEX_DIR/rv32ui-p-${t}.irom.hex"
    dram="$HEX_DIR/rv32ui-p-${t}.dram.hex"
    [ -f "$irom" ] || continue
    line=$(vvp -N "$SIM_BRAM" "+irom=$irom" "+dram=$dram" "+test=$t" "+cycles=50000" 2>&1 \
           | grep -E "^\[(PASS|FAIL|TIMEOUT)\]" | head -1)
    cycles=$(echo "$line" | grep -oP '\(\K[0-9]+')
    status=$(echo "$line" | grep -oP '^\[\K\w+')
    bram_cycles[$t]="${cycles:-0}"
    printf "  %-16s %s  %6s cycles\n" "$t" "$status" "${cycles:-N/A}"
done

# ================================================================
#  Phase 3: 对比结果
# ================================================================
echo ""
echo "========================================"
echo "  Performance Comparison: FF vs BRAM"
echo "========================================"
printf "  %-16s %8s %8s %8s %6s\n" "Test" "FF" "BRAM" "Δ" "%"
printf "  %-16s %8s %8s %8s %6s\n" "----" "------" "------" "------" "----"

total_ff=0
total_bram=0
for t in $TESTS; do
    ff=${ff_cycles[$t]:-0}
    bram=${bram_cycles[$t]:-0}
    [ "$ff" -eq 0 ] && continue
    [ "$bram" -eq 0 ] && continue
    delta=$((bram - ff))
    if [ "$ff" -gt 0 ]; then
        pct=$(awk "BEGIN{printf \"%.1f\", ($delta/$ff)*100}")
    else
        pct="N/A"
    fi
    printf "  %-16s %8d %8d %+8d %5s%%\n" "$t" "$ff" "$bram" "$delta" "$pct"
    total_ff=$((total_ff + ff))
    total_bram=$((total_bram + bram))
done
echo ""
if [ "$total_ff" -gt 0 ]; then
    total_delta=$((total_bram - total_ff))
    total_pct=$(awk "BEGIN{printf \"%.1f\", ($total_delta/$total_ff)*100}")
    printf "  %-16s %8d %8d %+8d %5s%%\n" "TOTAL" "$total_ff" "$total_bram" "$total_delta" "$total_pct"
fi
echo ""

# 清理
rm -f "$DCACHE_BRAM"
echo "Done."
