# ============================================================
# Vivado TCL 脚本：各流水线阶段时序分析
# 用法：在 Vivado 综合后的 TCL Console 中执行：
#   source /path/to/stage_timing.tcl
# 输出：reports/ 目录下各阶段的时序报告
#
# 架构：五级流水线 RV32I
#   Pre_IF_reg → [IF] → IF/ID → [ID] → ID/EX → [EX] → EX/MEM → [MEM] → MEM/WB → [WB]
#   分支在 EX 级判断，前递 MUX 在 ID 级，IROM/DRAM 为 Single Port BRAM（带输出寄存器）
# ============================================================

# 输出目录
set outdir "/home/anokyai/桌面/CPU_Workspace/03_Timing_Analysis/reports"
file mkdir $outdir

puts "======================================"
puts "  流水线各阶段时序分析"
puts "  输出目录: $outdir/"
puts "======================================"

# ---- 1. IF 阶段: Pre_IF_reg → IF/ID_reg ----
#   关键路径: next_pc MUX → IROM 地址建立时间
puts "\n>>> 1/10  IF 阶段: Pre_IF → IF/ID ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_pre_if_reg/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_if_id_reg/*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/01_IF_preif_to_ifid.txt
puts "    -> $outdir/01_IF_preif_to_ifid.txt"

# ---- 2. ID 阶段: IF/ID_reg → ID/EX_reg ----
#   包含: 译码器、立即数生成、前递 MUX 的组合逻辑
puts "\n>>> 2/10  ID 阶段: IF/ID → ID/EX ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_if_id_reg/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_id_ex_reg/*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/02_ID_ifid_to_idex.txt
puts "    -> $outdir/02_ID_ifid_to_idex.txt"

# ---- 3. ID 阶段 (regfile 路径): regfile → ID/EX_reg ----
#   regfile read → 前递 MUX → ID/EX_reg
puts "\n>>> 3/10  ID 阶段: regfile → ID/EX ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_regfile/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_id_ex_reg/*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/03_ID_regfile_to_idex.txt
puts "    -> $outdir/03_ID_regfile_to_idex.txt"

# ---- 4. EX 阶段: ID/EX_reg → EX/MEM_reg ----
#   包含: ALU 运算、分支比较、DRAM 地址建立
puts "\n>>> 4/10  EX 阶段: ID/EX → EX/MEM ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_id_ex_reg/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_ex_mem_reg/*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/04_EX_idex_to_exmem.txt
puts "    -> $outdir/04_EX_idex_to_exmem.txt"

# ---- 5. EX 阶段 (分支 flush): ID/EX_reg → Pre_IF_reg ----
#   关键路径: ALU 计算跳转目标 + 分支比较 → flush → correct_target → Pre_IF_reg
puts "\n>>> 5/10  EX 分支: ID/EX → Pre_IF (flush redirect) ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_id_ex_reg/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_pre_if_reg/*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/05_EX_branch_to_preif.txt
puts "    -> $outdir/05_EX_branch_to_preif.txt"

# ---- 6. EX 阶段 (DRAM 地址): ID/EX_reg → DRAM ----
#   关键路径: ALU 输出 → DRAM 地址端口建立时间
puts "\n>>> 6/10  EX→DRAM: ID/EX → DRAM addr ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_id_ex_reg/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_dram/* || NAME =~ *dram*bram*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/06_EX_idex_to_dram.txt
puts "    -> $outdir/06_EX_idex_to_dram.txt"

# ---- 7. MEM 阶段: EX/MEM_reg → MEM/WB_reg ----
puts "\n>>> 7/10  MEM 阶段: EX/MEM → MEM/WB ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_ex_mem_reg/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_mem_wb_reg/*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/07_MEM_exmem_to_memwb.txt
puts "    -> $outdir/07_MEM_exmem_to_memwb.txt"

# ---- 8. WB 阶段: MEM/WB_reg → regfile ----
#   包含: 写回 MUX（ALU 结果 / DRAM dout / PC+4）→ regfile 写端口
puts "\n>>> 8/10  WB 阶段: MEM/WB → regfile ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_mem_wb_reg/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_regfile/*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/08_WB_memwb_to_regfile.txt
puts "    -> $outdir/08_WB_memwb_to_regfile.txt"

# ---- 9. WB 前递跨级: MEM/WB_reg → ID/EX_reg ----
#   WB 前递数据 → ID 前递 MUX → ID/EX_reg
puts "\n>>> 9/10  跨级: MEM/WB → ID/EX (WB 前递) ..."
report_timing -from [get_cells -hier -filter {NAME =~ */u_mem_wb_reg/*}] \
              -to   [get_cells -hier -filter {NAME =~ */u_id_ex_reg/*}] \
              -delay_type max -max_paths 3 -sort_by slack \
              -file $outdir/09_CROSS_wb_forward_to_idex.txt
puts "    -> $outdir/09_CROSS_wb_forward_to_idex.txt"

# ---- 10. 全局总结: 前 20 条最长路径 ----
puts "\n>>> 10/10 全局 Top 20 路径 ..."
report_timing -delay_type max -max_paths 20 -sort_by slack \
              -file $outdir/00_global_top20.txt
puts "    -> $outdir/00_global_top20.txt"

# ---- 汇总输出 ----
puts "\n======================================"
puts "  所有报告已生成到 $outdir/ 目录："
puts "    00_global_top20.txt              全局前20条最长路径"
puts "    01_IF_preif_to_ifid.txt          IF 阶段"
puts "    02_ID_ifid_to_idex.txt           ID 阶段 (IF/ID→ID/EX)"
puts "    03_ID_regfile_to_idex.txt        ID 阶段 (regfile→ID/EX)"
puts "    04_EX_idex_to_exmem.txt          EX 阶段"
puts "    05_EX_branch_to_preif.txt        EX 分支→Pre_IF (flush)"
puts "    06_EX_idex_to_dram.txt           EX→DRAM 地址建立"
puts "    07_MEM_exmem_to_memwb.txt        MEM 阶段"
puts "    08_WB_memwb_to_regfile.txt       WB 阶段"
puts "    09_CROSS_wb_forward_to_idex.txt  跨级 WB 前递"
puts "======================================"