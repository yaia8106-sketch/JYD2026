# ==============================================================================
# import_all.tcl — 一键导入所有设计文件到 Vivado 工程
# ==============================================================================
#
# 使用方法：
#   1. 在 Vivado 中打开或新建工程
#   2. 在 Vivado Tcl Console 中运行：
#      source /path/to/CPU_Workspace/02_Design/scripts/import_all.tcl
#
#   或者用命令行：
#      vivado -mode tcl -source import_all.tcl
#
# 注意：
#   - 脚本会自动检测 02_Design 目录位置（基于脚本自身路径）
#   - IP 导入后会自动 Generate Output Products
#   - COE 文件需要在 IP 配置中手动关联（或通过 set_property 设置）
# ==============================================================================

# ---------- 路径设置 ----------
# 自动推导 02_Design 根目录（脚本在 02_Design/scripts/ 下）
set script_dir  [file dirname [file normalize [info script]]]
set design_root [file dirname $script_dir]

puts "=========================================="
puts " import_all.tcl"
puts " Design root: $design_root"
puts "=========================================="

# ---------- 子目录定义 ----------
set cpu_rtl_dir       "$design_root/rtl"
set platform_rtl_dir  "$design_root/rtl/platform"
set contest_rtl_dir   "$design_root/contest_readonly/rtl"
set contest_ip_dir    "$design_root/contest_readonly/ip"
set contest_xdc_dir   "$design_root/contest_readonly/constraints"
set contest_sim_dir   "$design_root/contest_readonly/sim"
set my_sim_dir        "$design_root/sim"
set coe_dir           "$design_root/coe/current"

# ---------- 1. 添加设计源文件（RTL）----------
puts "\n\[1/6\] 添加 RTL 源文件..."

# 自研 CPU 核心
set cpu_files [glob -nocomplain $cpu_rtl_dir/*.sv]
if {[llength $cpu_files] > 0} {
    add_files -norecurse $cpu_files
    puts "  + CPU RTL: [llength $cpu_files] 个文件"
} else {
    puts "  ! 警告: 未找到 CPU RTL 文件"
}

# 自研平台接口层
set platform_files [glob -nocomplain $platform_rtl_dir/*.sv]
if {[llength $platform_files] > 0} {
    add_files -norecurse $platform_files
    puts "  + Platform RTL: [llength $platform_files] 个文件"
}

# 赛方平台 RTL
set contest_rtl_files [glob -nocomplain $contest_rtl_dir/*.sv]
if {[llength $contest_rtl_files] > 0} {
    add_files -norecurse $contest_rtl_files
    puts "  + Contest RTL: [llength $contest_rtl_files] 个文件"
}

# ---------- 2. 添加 IP 核（.xci）----------
puts "\n\[2/6\] 添加 IP 配置文件..."

set ip_files [glob -nocomplain $contest_ip_dir/*.xci]
if {[llength $ip_files] > 0} {
    foreach xci $ip_files {
        set ip_name [file rootname [file tail $xci]]
        puts "  + IP: $ip_name"
        add_files -norecurse $xci
    }
} else {
    puts "  ! 警告: 未找到 .xci 文件"
}

# ---------- 3. 添加约束文件（.xdc）----------
puts "\n\[3/6\] 添加约束文件..."

set xdc_files [glob -nocomplain $contest_xdc_dir/*.xdc]
if {[llength $xdc_files] > 0} {
    add_files -fileset constrs_1 -norecurse $xdc_files
    puts "  + XDC: [llength $xdc_files] 个文件"
} else {
    puts "  ! 警告: 未找到 .xdc 文件"
}

# ---------- 4. 添加仿真源文件 ----------
puts "\n\[4/6\] 添加仿真源文件..."

# 赛方 testbench
set contest_sim_files [glob -nocomplain $contest_sim_dir/*.sv]
if {[llength $contest_sim_files] > 0} {
    add_files -fileset sim_1 -norecurse $contest_sim_files
    puts "  + Contest TB: [llength $contest_sim_files] 个文件"
}

# 自研 testbench
set my_sim_files [glob -nocomplain $my_sim_dir/*.sv]
if {[llength $my_sim_files] > 0} {
    add_files -fileset sim_1 -norecurse $my_sim_files
    puts "  + My TB: [llength $my_sim_files] 个文件"
}

# ---------- 5. 复制 COE 文件 ----------
puts "\n\[5/6\] 检查 COE 文件..."

set coe_files [glob -nocomplain $coe_dir/*.coe]
if {[llength $coe_files] > 0} {
    foreach coe $coe_files {
        puts "  + COE: [file tail $coe]"
    }
    puts "  提示: COE 文件路径 = $coe_dir"
    puts "  提示: 请在 IP 配置中手动设置 Loadable File 指向上述路径"
    puts "        或运行: set_property -dict \[list CONFIG.Load_Init_File {true} CONFIG.Coe_File {$coe_dir/irom.coe}\] \[get_ips IROM\]"
} else {
    puts "  ! 警告: 未找到 COE 文件"
}

# ---------- 6. 生成 IP Output Products ----------
puts "\n\[6/6\] 生成 IP Output Products..."

set all_ips [get_ips -quiet]
if {[llength $all_ips] > 0} {
    foreach ip $all_ips {
        puts "  生成: $ip"
    }
    generate_target all $all_ips
    puts "  IP Output Products 生成完成"
} else {
    puts "  没有需要生成的 IP"
}

# ---------- 设置顶层模块 ----------
puts "\n设置顶层模块为 top..."
set_property top top [current_fileset]

# ---------- 完成 ----------
puts "\n=========================================="
puts " 导入完成！"
puts "=========================================="
puts " 设计源文件:  [llength [get_files -filter {FILE_TYPE == SystemVerilog || FILE_TYPE == Verilog} -of_objects [get_filesets sources_1]]] 个"
puts " IP 核:       [llength [get_ips -quiet]] 个"
puts " 约束文件:    [llength [get_files -of_objects [get_filesets constrs_1]]] 个"
puts " 仿真文件:    [llength [get_files -of_objects [get_filesets sim_1]]] 个"
puts ""
puts " 下一步:"
puts "   1. 检查 IP 是否需要升级 (Report IP Status)"
puts "   2. 配置 IROM/DRAM 的 COE 初始化文件"
puts "   3. Run Synthesis → Implementation → Generate Bitstream"
puts "=========================================="
