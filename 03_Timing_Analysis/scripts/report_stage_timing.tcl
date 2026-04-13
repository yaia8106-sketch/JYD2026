# ================================================================
# report_stage_timing.tcl
#
# 功能：报告五级流水线各级间寄存器之间的组合路径延迟
#       （包括 BRAM 作为时序端点的路径）
#
# 使用方法：
#   1. 在 Vivado 中打开已完成 Implementation 的工程
#   2. open_run impl_1    （或 synth_1，两者均可）
#   3. source <path>/report_stage_timing.tcl
#
# 输出：
#   - 控制台：逐组延迟详情 + 汇总矩阵表
#   - 文件：  $OUTPUT_DIR/stage_timing_report.txt
#
# 自定义：
#   - 修改 [配置区] 中的层级路径模式以适配你的工程
#   - 修改 MAX_PATHS 控制每组报告的最差路径数量
# ================================================================

# ────────────────────────────────────────────────────────────────
#  配置区
# ────────────────────────────────────────────────────────────────

# 输出目录（绝对路径，每次覆盖旧文件）
set OUTPUT_DIR "/home/anokyai/桌面/CPU_Workspace/03_Timing_Analysis/reports"

# 每组最多报告的路径条数
set MAX_PATHS 3

# 时钟端口名与周期（当设计中没有时钟约束时自动创建）
# cpu_clk 频率：180MHz → 5.556ns；50MHz → 20ns
set CLK_PORT   "w_cpu_clk"
set CLK_PERIOD 5.556

# 设计层级前缀
# - 若 student_top 是 Vivado 顶层模块，设为 ""（空字符串）
# - 若 top.sv 是顶层且例化名为 u_student_top，设为 "u_student_top"
# - 若 top.sv 例化名为 student_top_inst，设为 "student_top_inst"
set TOP_HIER ""

# ---- 流水线寄存器组 ----
# 格式: {显示名称  层级通配模式（相对于 TOP_HIER）}
# 脚本会在该层级下搜索所有 IS_SEQUENTIAL=1 的 cell
set PIPELINE_GROUPS [list \
    [list "Pre_IF(PC)"   "u_cpu/u_pc_reg"       ] \
    [list "IF/ID"        "u_cpu/u_if_id_reg"     ] \
    [list "ID/EX"        "u_cpu/u_id_ex_reg"     ] \
    [list "EX/MEM"       "u_cpu/u_ex_mem_reg"    ] \
    [list "MEM/WB"       "u_cpu/u_mem_wb_reg"    ] \
    [list "RegFile"      "u_cpu/u_regfile"        ] \
]

# ---- BRAM 组（特殊时序端点）----
# BRAM 不是普通 FF，需要用 PRIMITIVE_TYPE 过滤
set BRAM_GROUPS [list \
    [list "IROM(BRAM)"   "u_irom"                ] \
    [list "DRAM(BRAM)"   "u_bridge"              ] \
]

# ────────────────────────────────────────────────────────────────
#  辅助函数
# ────────────────────────────────────────────────────────────────

proc join_hier {prefix suffix} {
    # 拼接层级路径，正确处理空前缀
    if {$prefix eq ""} { return $suffix }
    return "${prefix}/${suffix}"
}

proc find_seq_cells {hier_prefix} {
    # 查找指定层级下的所有时序单元（FF / LUTRAM 等）
    set pattern "${hier_prefix}/*"
    set cells [get_cells -quiet -hierarchical \
        -filter "IS_SEQUENTIAL == 1 && NAME =~ $pattern"]
    return $cells
}

proc find_bram_cells {hier_prefix} {
    # 查找指定层级下的 BRAM 原语
    set pattern "${hier_prefix}/*"
    set cells [get_cells -quiet -hierarchical \
        -filter "PRIMITIVE_TYPE =~ BMEM.bram.* && NAME =~ $pattern"]
    if {[llength $cells] == 0} {
        # 有些 IP 会将 BRAM 例化在更深层级
        set cells [get_cells -quiet -hierarchical \
            -filter "PRIMITIVE_TYPE =~ BMEM.*.* && NAME =~ $pattern"]
    }
    return $cells
}

proc format_ns {val} {
    # 保留 3 位小数
    if {$val eq "N/A"} { return "  N/A  " }
    return [format "%7.3f" $val]
}

proc center_str {str width} {
    set slen [string length $str]
    if {$slen >= $width} { return $str }
    set pad_left  [expr {($width - $slen) / 2}]
    set pad_right [expr {$width - $slen - $pad_left}]
    return "[string repeat " " $pad_left]${str}[string repeat " " $pad_right]"
}

# ────────────────────────────────────────────────────────────────
#  主流程
# ────────────────────────────────────────────────────────────────

puts "================================================================"
puts " report_stage_timing.tcl — 流水线级间组合路径延迟分析"
puts "================================================================"

# ---- 前置检查：时序分析是否可用 ----
if {[catch {report_timing -quiet -max_paths 1 -return_string} result]} {
    puts "\n✘ 错误：当前设计不支持时序分析。"
    puts "  可能原因：打开的是 Elaborated Design（RTL 展开），未经综合。"
    puts "  请先执行："
    puts "    close_design"
    puts "    open_run synth_1     ;# 或 open_run impl_1"
    puts "  然后重新 source 本脚本。"
    puts "\n  Vivado 返回: $result"
    return
}
puts "  时序引擎可用 ✔"

# 创建输出目录
file mkdir $OUTPUT_DIR
set report_file [open "${OUTPUT_DIR}/stage_timing_report.txt" w]

proc log_msg {msg} {
    upvar report_file fp
    puts $msg
    puts $fp $msg
}

# ---- Step 0: 确保时钟约束存在 ----
log_msg "\n\[Step 0\] 检查/创建时钟约束...\n"

set existing_clocks [get_clocks -quiet]
if {[llength $existing_clocks] == 0} {
    log_msg "  ⚠ 未检测到时钟约束"
    # 检查端口是否存在
    set clk_port [get_ports -quiet $CLK_PORT]
    if {[llength $clk_port] == 0} {
        log_msg "  ✘ 端口 $CLK_PORT 不存在！请检查 CLK_PORT 配置。"
        log_msg "    当前设计端口列表："
        foreach p [get_ports *] { log_msg "      $p" }
        close $report_file
        return
    }
    log_msg "  → 创建: create_clock -period $CLK_PERIOD -name cpu_clk \[get_ports $CLK_PORT\]"
    create_clock -period $CLK_PERIOD -name cpu_clk $clk_port
    log_msg "  ✔ 已创建 cpu_clk（周期 ${CLK_PERIOD}ns）"
} else {
    log_msg "  ✔ 检测到已有时钟约束: $existing_clocks"
}

# 强制更新时序引擎
log_msg "  → 执行 update_timing..."
update_timing -quiet
log_msg "  ✔ 时序引擎已更新"

# 验证：能否找到至少一条时序路径
set test_paths [get_timing_paths -quiet -max_paths 1]
if {[llength $test_paths] == 0} {
    log_msg "\n  ⚠ 验证失败：update_timing 后仍无时序路径"
    log_msg "    尝试使用 report_timing 诊断..."
    log_msg [report_timing -max_paths 1 -return_string]
} else {
    set test_slack [get_property SLACK [lindex $test_paths 0]]
    log_msg "  ✔ 验证通过：找到时序路径（worst slack = ${test_slack}ns）"
}

# ---- Step 1: 收集所有寄存器组 ----
log_msg "\n\[Step 1\] 收集寄存器组...\n"

set all_groups {}
set group_names {}

foreach grp $PIPELINE_GROUPS {
    set name [lindex $grp 0]
    set hier [join_hier $TOP_HIER [lindex $grp 1]]
    set filter "IS_SEQUENTIAL == 1 && NAME =~ ${hier}/*"
    set cnt [llength [get_cells -quiet -hierarchical -filter $filter]]
    log_msg [format "  %-14s : %4d cells  (pattern: %s/*)" $name $cnt $hier]
    if {$cnt > 0} {
        lappend all_groups [list $name $filter "seq"]
        lappend group_names $name
    } else {
        log_msg "    ⚠ 未找到时序单元，请检查层级路径是否正确"
    }
}

foreach grp $BRAM_GROUPS {
    set name [lindex $grp 0]
    set hier [join_hier $TOP_HIER [lindex $grp 1]]
    set filter "PRIMITIVE_TYPE =~ BMEM.*.* && NAME =~ ${hier}/*"
    set cnt [llength [get_cells -quiet -hierarchical -filter $filter]]
    log_msg [format "  %-14s : %4d cells  (pattern: %s/*)" $name $cnt $hier]
    if {$cnt > 0} {
        lappend all_groups [list $name $filter "bram"]
        lappend group_names $name
    } else {
        log_msg "    ⚠ 未找到 BRAM 单元，请检查层级路径是否正确"
    }
}

set num_groups [llength $group_names]
log_msg "\n  共 $num_groups 个有效组\n"

if {$num_groups == 0} {
    log_msg "\n✘ 未找到任何寄存器组，脚本退出。"
    log_msg "  请检查 TOP_HIER 和层级路径配置是否与综合后的设计匹配。"
    log_msg "  提示：使用 get_cells -hierarchical *pc_reg* 手动验证。"
    close $report_file
    return
}

# ---- Step 2: 逐对分析路径 ----
log_msg "\n\[Step 2\] 分析各组间时序路径 (每组最多 $MAX_PATHS 条)...\n"
log_msg [string repeat "=" 80]

# 存储汇总数据
array set delay_matrix {}
array set slack_matrix {}
array set levels_matrix {}

foreach from_grp $all_groups {
    set from_name   [lindex $from_grp 0]
    set from_filter [lindex $from_grp 1]

    foreach to_grp $all_groups {
        set to_name   [lindex $to_grp 0]
        set to_filter [lindex $to_grp 1]

        # 跳过自身
        if {$from_name eq $to_name} {
            set delay_matrix($from_name,$to_name) "  ---  "
            set slack_matrix($from_name,$to_name) "  ---  "
            continue
        }

        # 每次重新查询 Vivado cell 集合（避免字符串化问题）
        set from_cells [get_cells -quiet -hierarchical -filter $from_filter]
        set to_cells   [get_cells -quiet -hierarchical -filter $to_filter]

        # 尝试获取时序路径
        set paths [get_timing_paths -quiet \
            -from $from_cells \
            -to   $to_cells \
            -max_paths $MAX_PATHS \
            -nworst $MAX_PATHS]

        set path_count [llength $paths]

        if {$path_count == 0} {
            set delay_matrix($from_name,$to_name) "  N/P  "
            set slack_matrix($from_name,$to_name) "  N/P  "
            continue
        }

        # 取最差路径信息
        set worst_path [lindex $paths 0]
        set worst_slack      [get_property SLACK $worst_path]
        set worst_data_delay [get_property DATAPATH_DELAY $worst_path]
        set worst_levels     [get_property LOGIC_LEVELS $worst_path]

        set delay_matrix($from_name,$to_name) [format_ns $worst_data_delay]
        set slack_matrix($from_name,$to_name) [format_ns $worst_slack]
        set levels_matrix($from_name,$to_name) [format "%4d" $worst_levels]

        # 打印详细信息
        log_msg ""
        log_msg [format "  %s → %s  (找到 %d 条路径)" $from_name $to_name $path_count]
        log_msg [string repeat "-" 76]
        log_msg [format "    %-5s  %-10s  %-10s  %-8s  %s" \
            "#" "Slack(ns)" "DataPath" "Levels" "Endpoint"]
        log_msg [string repeat "-" 76]

        set idx 0
        foreach p $paths {
            incr idx
            set p_slack  [get_property SLACK $p]
            set p_data   [get_property DATAPATH_DELAY $p]
            set p_lvl    [get_property LOGIC_LEVELS $p]
            set p_end    [get_property ENDPOINT_PIN $p]

            # 截断 endpoint 显示名
            set end_short $p_end
            if {[string length $p_end] > 40} {
                set end_short "...[string range $p_end end-39 end]"
            }

            log_msg [format "    %-5d  %10.3f  %10.3f  %6d    %s" \
                $idx $p_slack $p_data $p_lvl $end_short]
        }
    }
}

# ---- Step 3: 汇总矩阵表 ----
log_msg "\n"
log_msg [string repeat "=" 80]
log_msg "\n\[Step 3\] 汇总矩阵：最差数据路径延迟 (ns)\n"
log_msg "  行 = 起点 (From)，列 = 终点 (To)"
log_msg "  N/P = 无路径存在\n"

# 列宽
set COL_W 12
set NAME_W 14

# 表头
set header [format "%-${NAME_W}s" "From \\ To"]
foreach name $group_names {
    append header [center_str $name $COL_W]
}
log_msg $header
log_msg [string repeat "-" [expr {$NAME_W + $num_groups * $COL_W}]]

# 每行
foreach from_name $group_names {
    set row [format "%-${NAME_W}s" $from_name]
    foreach to_name $group_names {
        if {[info exists delay_matrix($from_name,$to_name)]} {
            append row [center_str $delay_matrix($from_name,$to_name) $COL_W]
        } else {
            append row [center_str "  ???  " $COL_W]
        }
    }
    log_msg $row
}

# ---- Slack 矩阵 ----
log_msg ""
log_msg "\n  汇总矩阵：最差 Slack (ns)  （正 = 满足约束，负 = 违例）\n"

set header [format "%-${NAME_W}s" "From \\ To"]
foreach name $group_names {
    append header [center_str $name $COL_W]
}
log_msg $header
log_msg [string repeat "-" [expr {$NAME_W + $num_groups * $COL_W}]]

foreach from_name $group_names {
    set row [format "%-${NAME_W}s" $from_name]
    foreach to_name $group_names {
        if {[info exists slack_matrix($from_name,$to_name)]} {
            append row [center_str $slack_matrix($from_name,$to_name) $COL_W]
        } else {
            append row [center_str "  ???  " $COL_W]
        }
    }
    log_msg $row
}

# ---- 找出全局最差路径 ----
log_msg ""
log_msg [string repeat "=" 80]
log_msg "\n\[Step 4\] 全局最差路径 Top 10\n"

set global_paths [get_timing_paths -quiet \
    -max_paths 10 \
    -sort_by slack]

set gidx 0
log_msg [format "  %-4s  %-10s  %-10s  %-8s  %s" \
    "#" "Slack" "DataPath" "Levels" "StartPoint → EndPoint"]
log_msg [string repeat "-" 90]

foreach gp $global_paths {
    incr gidx
    set g_slack [get_property SLACK $gp]
    set g_data  [get_property DATAPATH_DELAY $gp]
    set g_lvl   [get_property LOGIC_LEVELS $gp]
    set g_start [get_property STARTPOINT_PIN $gp]
    set g_end   [get_property ENDPOINT_PIN $gp]

    # 截断长名
    if {[string length $g_start] > 30} { set g_start "...[string range $g_start end-29 end]" }
    if {[string length $g_end]   > 30} { set g_end   "...[string range $g_end end-29 end]"   }

    log_msg [format "  %-4d  %10.3f  %10.3f  %6d    %s → %s" \
        $gidx $g_slack $g_data $g_lvl $g_start $g_end]
}

# ---- 完成 ----
log_msg ""
log_msg [string repeat "=" 80]
log_msg " 报告已保存至: ${OUTPUT_DIR}/stage_timing_report.txt"
log_msg [string repeat "=" 80]

close $report_file

puts "\n✔ 完成！请查看 ${OUTPUT_DIR}/stage_timing_report.txt"
