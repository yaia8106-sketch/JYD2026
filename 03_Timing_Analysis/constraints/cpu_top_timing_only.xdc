# ============================================================
# cpu_top 独立 Implementation 约束文件
# 仅包含时钟约束，用于评估布局布线后的真实时序
# ============================================================

# 时钟约束：目标 222MHz (4.5ns)
create_clock -period 4.500 -name sys_clk [get_ports clk]

# 防止 Vivado 优化掉无输出端口的内部逻辑
set_property DONT_TOUCH true [get_cells -hier -filter {IS_PRIMITIVE==0}]

# 允许 Implementation 在无管脚约束时继续运行
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
