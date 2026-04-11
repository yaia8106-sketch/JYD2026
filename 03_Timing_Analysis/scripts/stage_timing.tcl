# ============================================================
# Vivado TCL 脚本：各流水线阶段时序分析
# 用法：在 Vivado 综合后的 TCL Console 中执行：
#   source /path/to/stage_timing.tcl
# 输出：reports/ 目录下各阶段的时序报告
#
# 架构：五级流水线 RV32I (cpu_top.sv)
#   u_pc_reg → [IF/IROM] → u_if_id_reg → [ID] → u_id_ex_reg → [EX] → u_ex_mem_reg → [MEM] → u_mem_wb_reg → [WB]
#   分支在 EX 级判断 (u_branch_unit)，前递 MUX 在 ID 级 (u_forwarding)
#   IROM: IROM4Test u_irom，DRAM: DRAM4Test u_dram（均为 BRAM + 输出寄存器）
#
# 实例清单：
#   u_pc_reg, u_next_pc_mux, u_irom, u_if_id_reg,
#   u_decoder, u_imm_gen, u_regfile, u_forwarding, u_alu_src_mux,
#   u_id_ex_reg, u_alu, u_branch_unit, u_mem_interface, u_dram,
#   u_ex_mem_reg, u_mem_wb_reg, u_wb_mux
# ============================================================

# 输出目录
set outdir "/home/anokyai/桌面/CPU_Workspace/03_Timing_Analysis/reports"
file mkdir $outdir

# 辅助函数：安全执行分段时序报告
# 参数: from_pat to_pat outfile description
proc safe_stage_timing {from_pat to_pat outfile desc} {
    set from_cells [get_cells -hier -filter "NAME =~ $from_pat" -quiet]
    set to_cells   [get_cells -hier -filter "NAME =~ $to_pat"   -quiet]
    if {[llength $from_cells] == 0 || [llength $to_cells] == 0} {
        puts "    \[SKIP\] $desc — 源或目标 cell 未找到"
        return
    }
    if {[catch {
        report_timing -from $from_cells -to $to_cells \
                      -delay_type max -max_paths 5 -sort_by slack \
                      -file $outfile
    } err]} {
        puts "    \[SKIP\] $desc — $err"
    } else {
        puts "    -> $outfile"
    }
}

puts "======================================"
puts "  流水线各阶段时序分析"
puts "  输出目录: $outdir/"
puts "======================================"

# ---- 0. 全局 Top 20 ----
puts "\n>>> 0/12 全局 Top 20 路径 ..."
report_timing -delay_type max -max_paths 20 -sort_by slack \
              -file $outdir/00_global_top20.txt
puts "    -> $outdir/00_global_top20.txt"

# ---- 1. IF 阶段: u_pc_reg → u_irom (BRAM 地址建立) ----
puts "\n>>> 1/12  IF: u_pc_reg → u_irom ..."
safe_stage_timing "*u_pc_reg*" "*u_irom*" \
    $outdir/01_IF_pc_to_irom.txt "u_pc_reg → u_irom"

# ---- 2. IF 阶段: u_pc_reg → u_if_id_reg ----
puts "\n>>> 2/12  IF: u_pc_reg → u_if_id_reg ..."
safe_stage_timing "*u_pc_reg*" "*u_if_id_reg*" \
    $outdir/02_IF_pc_to_ifid.txt "u_pc_reg → u_if_id_reg"

# ---- 3. ID 阶段: u_if_id_reg → u_id_ex_reg ----
puts "\n>>> 3/12  ID: u_if_id_reg → u_id_ex_reg ..."
safe_stage_timing "*u_if_id_reg*" "*u_id_ex_reg*" \
    $outdir/03_ID_ifid_to_idex.txt "u_if_id_reg → u_id_ex_reg"

# ---- 4. ID 阶段 (regfile): regfile → u_id_ex_reg ----
#   regfile 可能被拍平，尝试 *u_regfile* 和 *regs_reg*
puts "\n>>> 4/12  ID: regfile → u_id_ex_reg ..."
safe_stage_timing "*u_regfile*" "*u_id_ex_reg*" \
    $outdir/04_ID_regfile_to_idex.txt "u_regfile → u_id_ex_reg"

# ---- 5. EX 阶段: u_id_ex_reg → u_ex_mem_reg ----
puts "\n>>> 5/12  EX: u_id_ex_reg → u_ex_mem_reg ..."
safe_stage_timing "*u_id_ex_reg*" "*u_ex_mem_reg*" \
    $outdir/05_EX_idex_to_exmem.txt "u_id_ex_reg → u_ex_mem_reg"

# ---- 6. EX 分支: u_id_ex_reg → u_pc_reg (flush redirect) ----
puts "\n>>> 6/12  EX 分支: u_id_ex_reg → u_pc_reg ..."
safe_stage_timing "*u_id_ex_reg*" "*u_pc_reg*" \
    $outdir/06_EX_branch_to_pc.txt "u_id_ex_reg → u_pc_reg"

# ---- 7. EX → DRAM: u_id_ex_reg → u_dram (BRAM 地址建立) ----
puts "\n>>> 7/12  EX→DRAM: u_id_ex_reg → u_dram ..."
safe_stage_timing "*u_id_ex_reg*" "*u_dram*" \
    $outdir/07_EX_idex_to_dram.txt "u_id_ex_reg → u_dram"

# ---- 8. EX 前递跨级: u_id_ex_reg → u_id_ex_reg ----
puts "\n>>> 8/12  跨级: u_id_ex_reg → u_id_ex_reg (EX 前递) ..."
safe_stage_timing "*u_id_ex_reg*" "*u_id_ex_reg*" \
    $outdir/08_CROSS_ex_forward.txt "u_id_ex_reg → u_id_ex_reg"

# ---- 9. MEM 阶段: u_ex_mem_reg → u_mem_wb_reg ----
puts "\n>>> 9/14  MEM: u_ex_mem_reg → u_mem_wb_reg ..."
safe_stage_timing "*u_ex_mem_reg*" "*u_mem_wb_reg*" \
    $outdir/09_MEM_exmem_to_memwb.txt "u_ex_mem_reg → u_mem_wb_reg"

# ---- 9b. MEM 阶段: u_dram → u_mem_wb_reg (BRAM Clk-to-Q → MEM/WB) ----
# 关键路径：1-cycle BRAM 无 output register，douta → wb_dram_dout_reg
puts "\n>>> 9b/14 MEM: u_dram → u_mem_wb_reg (BRAM output → MEM/WB) ..."
safe_stage_timing "*u_dram*" "*u_mem_wb_reg*" \
    $outdir/09b_MEM_dram_to_memwb.txt "u_dram → u_mem_wb_reg"

# ---- 10. WB 阶段: u_mem_wb_reg → regfile ----
puts "\n>>> 10/14 WB: u_mem_wb_reg → regfile ..."
safe_stage_timing "*u_mem_wb_reg*" "*u_regfile*" \
    $outdir/10_WB_memwb_to_regfile.txt "u_mem_wb_reg → u_regfile"

# ---- 11. WB 前递跨级: u_mem_wb_reg → u_id_ex_reg ----
puts "\n>>> 11/14 跨级: u_mem_wb_reg → u_id_ex_reg (WB 前递) ..."
safe_stage_timing "*u_mem_wb_reg*" "*u_id_ex_reg*" \
    $outdir/11_CROSS_wb_forward.txt "u_mem_wb_reg → u_id_ex_reg"

# ---- 12. 全局时序 Summary ----
puts "\n>>> 12/14 全局时序 Summary ..."
report_timing_summary -delay_type min_max -max_paths 10 \
              -file $outdir/12_timing_summary.txt
puts "    -> $outdir/12_timing_summary.txt"

# ---- 汇总输出 ----
puts "\n======================================"
puts "  所有报告已生成到 $outdir/ 目录："
puts "    00_global_top20.txt             全局前20条最长路径"
puts "    01_IF_pc_to_irom.txt            IF: PC→IROM (BRAM 地址建立)"
puts "    02_IF_pc_to_ifid.txt            IF: PC→IF/ID"
puts "    03_ID_ifid_to_idex.txt          ID: IF/ID→ID/EX"
puts "    04_ID_regfile_to_idex.txt       ID: regfile→ID/EX"
puts "    05_EX_idex_to_exmem.txt         EX: ID/EX→EX/MEM"
puts "    06_EX_branch_to_pc.txt          EX 分支→PC"
puts "    07_EX_idex_to_dram.txt          EX→DRAM (BRAM 地址建立)"
puts "    08_CROSS_ex_forward.txt         跨级 EX 前递"
puts "    09_MEM_exmem_to_memwb.txt       MEM: EX/MEM→MEM/WB"
puts "    09b_MEM_dram_to_memwb.txt       MEM: DRAM→MEM/WB (BRAM Clk-to-Q)"
puts "    10_WB_memwb_to_regfile.txt      WB: MEM/WB→regfile"
puts "    11_CROSS_wb_forward.txt         跨级 WB 前递"
puts "    12_timing_summary.txt           全局 Summary (WNS/WHS)"
puts "  \[SKIP\] 表示该路径在当前网表中不存在（模块被拍平或无此路径）"
puts "======================================"