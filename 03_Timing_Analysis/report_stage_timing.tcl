# ================================================================
# report_stage_timing.tcl
#
# 功能：报告五级流水线各级间寄存器/RAM 原语之间的组合路径延迟。
#       手工分组之外的 sequential/RAM 单元会自动归入兜底组，
#       避免新增模块后关键路径只出现在全局 Top-N 中。
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

# 输出目录（默认写到本脚本所在目录，每次覆盖旧文件）
set OUTPUT_DIR [file normalize [file dirname [info script]]]

# 每组最多报告的路径条数
set MAX_PATHS 3

# 为路径去重预取更多候选；最终仍只输出 MAX_PATHS 条路径族
set PATH_CANDIDATE_MULTIPLIER 4

# 全局最差路径兜底条数
set GLOBAL_MAX_PATHS 25

# 全局候选通常会被少数宽总线占满，需要比组间查询更大的预取窗口
set GLOBAL_CANDIDATE_MULTIPLIER 20

# 时钟端口名与周期（当设计中没有时钟约束时自动创建）
# cpu_clk 频率：200MHz → 5.0ns；100MHz → 10.0ns；50MHz → 20ns
set CLK_PORT   "w_cpu_clk"
set CLK_PERIOD 5.0

# ---- 前置检查：必须已经 open_run synth_1/impl_1 或打开综合/实现设计 ----
if {[catch {current_design} _current_design_name] || $_current_design_name eq ""} {
    puts "================================================================"
    puts " report_stage_timing.tcl — 流水线级间组合路径延迟分析"
    puts "================================================================"
    puts "\n✘ 错误：当前没有 open design。"
    puts "  你现在可能只是 open_project 了工程，还没有打开 synth_1/impl_1。"
    puts "  请在 Vivado Tcl Console 中执行："
    puts "    open_project /home/anokyai/Desktop/CPU_Workspace/JYD2025_Contest-rv32i/digital_twin.xpr"
    puts "    open_run impl_1"
    puts "    source /home/anokyai/Desktop/CPU_Workspace/03_Timing_Analysis/report_stage_timing.tcl"
    puts "\n  如果实现结果还没生成，先运行："
    puts "    在 Vivado 工程中完成 synth_1/impl_1 后再运行本脚本。"
    return
}
puts "  当前设计: $_current_design_name"

# 设计层级前缀（自动检测）
# 支持 Core_cpu 包装前后的顶层配置。当前比赛集成层级为：
#   top/student_top_inst/Core_cpu/{u_cpu,u_dcache,u_irom,u_dram,...}
#
# 检测方法：查找当前前端 u_cpu/u_frontend_ftq 在哪个层次下
set TOP_HIER ""
set _probe_patterns [list \
    "student_top_inst/Core_cpu" \
    "Core_cpu"             \
    ""                    \
    "student_top_inst"    \
    "u_student_top"       \
]
foreach _pat $_probe_patterns {
    if {$_pat eq ""} {
        set _test_filter "IS_SEQUENTIAL == 1 && NAME =~ u_cpu/u_frontend_ftq/*"
    } else {
        set _test_filter "IS_SEQUENTIAL == 1 && NAME =~ ${_pat}/u_cpu/u_frontend_ftq/*"
    }
    set _test_cells [get_cells -quiet -hierarchical -filter $_test_filter]
    if {[llength $_test_cells] > 0} {
        set TOP_HIER $_pat
        break
    }
}
if {$TOP_HIER eq ""} {
    puts "  → 自动检测: student_top 为顶层 (TOP_HIER = \"\")"
} else {
    puts "  → 自动检测: 顶层下例化名 = $TOP_HIER"
}

# ---- 流水线寄存器组 ----
# 格式: {显示名称  层级通配模式（相对于 TOP_HIER）}
# 脚本会在该层级下搜索所有 IS_SEQUENTIAL=1 的 cell
set PIPELINE_GROUPS [list \
    [list "Frontend"       "u_cpu/u_frontend_ftq"       ] \
    [list "Stage1Dir"      "u_cpu/u_frontend_stage1_direction"] \
    [list "ABTB"           "u_cpu/u_frontend_abtb"      ] \
    [list "IF/ID"          "u_cpu/u_if_id_reg"           ] \
    [list "ID/EX.S0"       "u_cpu/u_id_ex_reg"           ] \
    [list "ID/EX.S1"       "u_cpu/u_id_ex_reg_s1"        ] \
    [list "EX/MEM.S0"      "u_cpu/u_ex_mem_reg"          ] \
    [list "EX/MEM.S1"      "u_cpu/u_ex_mem_reg_s1"       ] \
    [list "MEM/WB.S0"      "u_cpu/u_mem_wb_reg"          ] \
    [list "MEM/WB.S1"      "u_cpu/u_mem_wb_reg_s1"       ] \
    [list "RegFile"        "u_cpu/u_regfile"             ] \
    [list "RedirectCtl"    "u_cpu/u_redirect_ctrl"       ] \
    [list "CSR/Trap"       "u_cpu/u_csr_trap_unit"       ] \
    [list "MulDiv"         "u_cpu/u_muldiv_unit"         ] \
    [list "DualCnt"        "u_cpu/u_dual_issue_counter"  ] \
    [list "DCache(FSM)"    "u_dcache"                    ] \
    [list "DCacheBackend"  "u_dcache_bram_backend"       ] \
    [list "DCacheAxi"      "u_dcache_axi_backend"        ] \
    [list "AXIAdapter"     "u_dcache_axi_backend/u_axi_master_adapter"] \
    [list "MMIO"           "u_mmio_adapter"              ] \
]

# ---- 顶层零散寄存器组 ----
# 格式: {显示名称  cell 名称通配模式（相对于 TOP_HIER，不自动追加 /*）}
set EXTRA_SEQ_GROUPS [list \
]

# ---- RAM 组（特殊时序端点）----
# BRAM/LUTRAM 不是普通 FF，需要用 PRIMITIVE_TYPE/REF_NAME 过滤。
# ABTB/PHT 在 FPGA 上通常是 distributed RAM，因此也必须纳入。
set BRAM_GROUPS [list \
    [list "IROM(RAM)"       "u_irom"                  ] \
    [list "ABTB(RAM)"       "u_cpu/u_frontend_abtb"   ] \
    [list "PHT(RAM)"        "u_cpu/u_frontend_stage1_direction"] \
    [list "DRAM(RAM)"       "u_dram"                  ] \
    [list "DC_Backend(RAM)" "u_dcache_bram_backend"   ] \
    [list "DC_Data(RAM)"    "u_dcache"                ] \
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

proc find_misc_cells {hier_prefix known_groups} {
    # 查找 hier_prefix 下不属于任何 known sub-module 的时序单元
    # known_groups: list of sub-module hier patterns to exclude
    set all_cells [get_cells -quiet -hierarchical \
        -filter "IS_SEQUENTIAL == 1 && NAME =~ ${hier_prefix}/*"]
    set misc_cells {}
    foreach c $all_cells {
        set cname [get_property NAME $c]
        set in_known 0
        foreach kg $known_groups {
            if {[string match "${kg}/*" $cname]} {
                set in_known 1
                break
            }
        }
        if {!$in_known} {
            lappend misc_cells $c
        }
    }
    return $misc_cells
}

proc find_bram_cells {hier_prefix} {
    # 查找指定层级下的 RAM 原语，包括 BRAM 和 distributed RAM。
    set pattern "${hier_prefix}/*"
    set cells [get_cells -quiet -hierarchical \
        -filter "(PRIMITIVE_TYPE =~ BMEM.*.* || PRIMITIVE_TYPE =~ BLOCKRAM.* || PRIMITIVE_TYPE =~ LUTRAM.* || REF_NAME =~ RAMB* || REF_NAME =~ RAM*) && NAME =~ $pattern"]
    if {[llength $cells] == 0} {
        # 有些综合版本不会完整填 PRIMITIVE_TYPE，REF_NAME 作为兜底。
        set cells [get_cells -quiet -hierarchical \
            -filter "(REF_NAME =~ RAM* || REF_NAME =~ RAMB*) && NAME =~ $pattern"]
    }
    return $cells
}

proc format_ns {val} {
    # 保留 3 位小数；Vivado 对部分 BRAM/特殊路径可能返回空值或 inf。
    set val [string trim $val]
    if {$val eq "" || $val eq "N/A"} { return "  N/A  " }
    if {[string match -nocase "inf" $val] || [string match -nocase "+inf" $val]} {
        return "  INF  "
    }
    if {[string match -nocase "-inf" $val]} {
        return " -INF  "
    }
    if {![string is double -strict $val]} {
        return [format "%7s" $val]
    }
    return [format "%7.3f" $val]
}

proc format_levels {val} {
    set val [string trim $val]
    if {$val eq "" || $val eq "N/A"} { return " N/A " }
    if {![string is integer -strict $val]} {
        return [format "%5s" $val]
    }
    return [format "%5d" $val]
}

proc is_numeric {val} {
    set val [string trim $val]
    if {$val eq "" || $val eq "N/A"} { return 0 }
    if {[string match -nocase "*inf*" $val]} { return 0 }
    return [string is double -strict $val]
}

proc safe_property {property object {default "N/A"}} {
    if {[llength $object] == 0} { return $default }
    if {[catch {set value [get_property $property $object]}]} {
        return $default
    }
    set value [string trim $value]
    if {$value eq ""} { return $default }
    return $value
}

proc format_percent {val} {
    if {![is_numeric $val]} { return " N/A " }
    return [format "%5.1f" $val]
}

proc format_integer {val} {
    if {![string is integer -strict [string trim $val]]} {
        return [format "%5s" "N/A"]
    }
    return [format "%5d" $val]
}

proc normalize_path_pin {pin_name} {
    # 将 bus/数组下标归一化，使同一逻辑结构上的不同 bit 合并为一个路径族。
    set normalized $pin_name
    regsub -all {\[[0-9]+\]} $normalized {[*]} normalized
    regsub -all {_replica(_[0-9]+)?} $normalized {} normalized
    return $normalized
}

proc path_family_key {path} {
    set start_pin [safe_property STARTPOINT_PIN $path ""]
    set end_pin   [safe_property ENDPOINT_PIN $path ""]
    return "[normalize_path_pin $start_pin] -> [normalize_path_pin $end_pin]"
}

proc cluster_path_candidates {paths} {
    # 返回 {slack representative_path candidate_hits family_key}，按 slack 升序。
    # candidate_hits 仅表示本次预取候选中的命中数，不等于该路径族的总 bit 数。
    array set representative {}
    array set representative_slack {}
    array set candidate_hits {}
    set family_order {}

    foreach path $paths {
        set key [path_family_key $path]
        set slack [safe_property SLACK $path "N/A"]
        if {![is_numeric $slack]} { continue }

        if {![info exists candidate_hits($key)]} {
            set representative($key) $path
            set representative_slack($key) $slack
            set candidate_hits($key) 0
            lappend family_order $key
        }
        incr candidate_hits($key)

        if {$slack < $representative_slack($key)} {
            set representative($key) $path
            set representative_slack($key) $slack
        }
    }

    set clusters {}
    foreach key $family_order {
        lappend clusters [list \
            $representative_slack($key) \
            $representative($key) \
            $candidate_hits($key) \
            $key]
    }
    return [lsort -real -index 0 $clusters]
}

proc pin_physical_info {pin} {
    # safe_property 会把 Vivado object 转成普通字符串，这里显式解析回 pin object。
    set pin_object [lindex [get_pins -quiet $pin] 0]
    if {$pin_object eq ""} {
        return [dict create loc "N/A" clock_region "N/A" loc_x "" loc_y ""]
    }
    set cell [lindex [get_cells -quiet -of_objects $pin_object] 0]
    if {$cell eq ""} {
        return [dict create loc "N/A" clock_region "N/A" loc_x "" loc_y ""]
    }

    set loc [safe_property LOC $cell ""]
    set loc_x ""
    set loc_y ""
    regexp {SLICE_X([0-9]+)Y([0-9]+)} $loc _ loc_x loc_y

    set site [lindex [get_sites -quiet -of_objects $cell] 0]
    set clock_region [safe_property CLOCK_REGION $site "N/A"]
    if {$loc eq ""} { set loc "N/A" }
    return [dict create \
        loc $loc \
        clock_region $clock_region \
        loc_x $loc_x \
        loc_y $loc_y]
}

proc path_physical_metrics {path} {
    set data_delay  [safe_property DATAPATH_DELAY $path "N/A"]
    set logic_delay [safe_property DATAPATH_LOGIC_DELAY $path "N/A"]
    set net_delay   [safe_property DATAPATH_NET_DELAY $path "N/A"]
    set levels      [safe_property LOGIC_LEVELS $path "N/A"]
    set fanout      [safe_property MAX_FANOUT $path "N/A"]
    set skew        [safe_property SKEW $path "N/A"]

    set route_ratio "N/A"
    if {[is_numeric $data_delay] && $data_delay > 0 && [is_numeric $net_delay]} {
        set route_ratio [expr {100.0 * double($net_delay) / double($data_delay)}]
    }

    set start_pin [safe_property STARTPOINT_PIN $path ""]
    set end_pin   [safe_property ENDPOINT_PIN $path ""]
    set start_physical [pin_physical_info $start_pin]
    set end_physical   [pin_physical_info $end_pin]

    set start_x [dict get $start_physical loc_x]
    set start_y [dict get $start_physical loc_y]
    set end_x   [dict get $end_physical loc_x]
    set end_y   [dict get $end_physical loc_y]
    set span "N/A"
    if {[is_numeric $start_x] && [is_numeric $start_y] &&
        [is_numeric $end_x] && [is_numeric $end_y]} {
        set span [expr {abs($end_x - $start_x) + abs($end_y - $start_y)}]
    }

    # 这是诊断标签，不是工具给出的根因判定。
    set causes {}
    if {[is_numeric $route_ratio] && $route_ratio >= 70.0} {
        lappend causes "route"
    }
    if {[is_numeric $levels] && $levels >= 8} {
        lappend causes "logic-depth"
    }
    if {[is_numeric $fanout] && $fanout >= 32} {
        lappend causes "fanout"
    }
    set start_cr [dict get $start_physical clock_region]
    set end_cr   [dict get $end_physical clock_region]
    if {([is_numeric $span] && $span >= 40) ||
        ($start_cr ne "N/A" && $end_cr ne "N/A" && $start_cr ne $end_cr)} {
        lappend causes "placement"
    }
    if {[llength $causes] == 0} {
        lappend causes "balanced"
    }

    return [dict create \
        data_delay $data_delay \
        logic_delay $logic_delay \
        net_delay $net_delay \
        route_ratio $route_ratio \
        levels $levels \
        fanout $fanout \
        skew $skew \
        span $span \
        start_loc [dict get $start_physical loc] \
        end_loc [dict get $end_physical loc] \
        start_cr $start_cr \
        end_cr $end_cr \
        diagnosis [join $causes "+"]]
}

proc get_design_seq_cells {top_hier} {
    # 查找当前 student_top 设计域内的所有时序单元。
    if {$top_hier eq ""} {
        return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL == 1"]
    }
    return [get_cells -quiet -hierarchical \
        -filter "IS_SEQUENTIAL == 1 && NAME =~ ${top_hier}/*"]
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
        foreach p [get_ports -quiet *] { log_msg "      $p" }
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

# ---- Step 1: 收集所有 timing endpoint 组 ----
log_msg "\n\[Step 1\] 收集 timing endpoint 组...\n"

# all_groups entry: {显示名称 cell_object_list 类型}
set all_groups {}
set group_names {}
array set grouped_seq_names {}
array set grouped_bram_names {}

foreach grp $PIPELINE_GROUPS {
    set name [lindex $grp 0]
    set hier [join_hier $TOP_HIER [lindex $grp 1]]
    set cells [find_seq_cells $hier]
    set cnt [llength $cells]
    log_msg [format "  %-16s : %5d seq   (pattern: %s/*)" $name $cnt $hier]
    if {$cnt > 0} {
        lappend all_groups [list $name $cells "seq"]
        lappend group_names $name
        foreach c $cells {
            set grouped_seq_names([get_property NAME $c]) 1
        }
    } else {
        log_msg "    ⚠ 未找到时序单元；若该模块被综合优化或当前配置不存在，可以忽略"
    }
}

foreach grp $EXTRA_SEQ_GROUPS {
    set name [lindex $grp 0]
    set pattern [join_hier $TOP_HIER [lindex $grp 1]]
    set cells [get_cells -quiet -hierarchical \
        -filter "IS_SEQUENTIAL == 1 && NAME =~ ${pattern}"]
    set cnt [llength $cells]
    log_msg [format "  %-16s : %5d seq   (pattern: %s)" $name $cnt $pattern]
    if {$cnt > 0} {
        lappend all_groups [list $name $cells "seq"]
        lappend group_names $name
        foreach c $cells {
            set grouped_seq_names([get_property NAME $c]) 1
        }
    } else {
        log_msg "    ⚠ 未找到时序单元；请检查层级路径是否正确"
    }
}

foreach grp $BRAM_GROUPS {
    set name [lindex $grp 0]
    set hier [join_hier $TOP_HIER [lindex $grp 1]]
    set cells [find_bram_cells $hier]
    set cnt [llength $cells]
    log_msg [format "  %-16s : %5d ram   (pattern: %s/*)" $name $cnt $hier]
    if {$cnt > 0} {
        lappend all_groups [list $name $cells "bram"]
        lappend group_names $name
        foreach c $cells {
            set grouped_bram_names([get_property NAME $c]) 1
        }
    } else {
        log_msg "    ⚠ 未找到 RAM 原语；若当前配置不用该 backend，可以忽略"
    }
}

# ---- Step 1b: 覆盖审计 + 自动兜底组 ----
log_msg "\n\[Step 1b\] 分组覆盖审计...\n"

set all_seq_cells [get_design_seq_cells $TOP_HIER]
set ungrouped_seq_cells {}
set ungrouped_seq_names {}
foreach c $all_seq_cells {
    set cname [get_property NAME $c]
    if {![info exists grouped_seq_names($cname)]} {
        lappend ungrouped_seq_cells $c
        lappend ungrouped_seq_names $cname
    }
}

if {$TOP_HIER eq ""} {
    set all_bram_cells [get_cells -quiet -hierarchical \
        -filter "(PRIMITIVE_TYPE =~ BMEM.*.* || PRIMITIVE_TYPE =~ BLOCKRAM.* || PRIMITIVE_TYPE =~ LUTRAM.* || REF_NAME =~ RAMB* || REF_NAME =~ RAM*)"]
} else {
    set all_bram_cells [get_cells -quiet -hierarchical \
        -filter "(PRIMITIVE_TYPE =~ BMEM.*.* || PRIMITIVE_TYPE =~ BLOCKRAM.* || PRIMITIVE_TYPE =~ LUTRAM.* || REF_NAME =~ RAMB* || REF_NAME =~ RAM*) && NAME =~ ${TOP_HIER}/*"]
}
set ungrouped_bram_cells {}
set ungrouped_bram_names {}
foreach c $all_bram_cells {
    set cname [get_property NAME $c]
    if {![info exists grouped_bram_names($cname)]} {
        lappend ungrouped_bram_cells $c
        lappend ungrouped_bram_names $cname
    }
}

log_msg [format "  当前设计 sequential cells : %5d" [llength $all_seq_cells]]
log_msg [format "  手工归类 sequential cells : %5d" [array size grouped_seq_names]]
log_msg [format "  自动兜底 sequential cells : %5d" [llength $ungrouped_seq_cells]]
if {[llength $ungrouped_seq_cells] > 0} {
    lappend all_groups [list "OtherSeq" $ungrouped_seq_cells "seq"]
    lappend group_names "OtherSeq"
    log_msg "  → 已加入 OtherSeq 兜底组，以下为样例（最多 20 个）："
    set sample_idx 0
    foreach cname [lsort $ungrouped_seq_names] {
        incr sample_idx
        log_msg "    $cname"
        if {$sample_idx >= 20} { break }
    }
} else {
    log_msg "  ✔ 所有 sequential cells 都已落入手工分组。"
}

log_msg [format "  当前设计 RAM primitive    : %5d" [llength $all_bram_cells]]
log_msg [format "  手工归类 RAM primitive    : %5d" [array size grouped_bram_names]]
log_msg [format "  自动兜底 RAM primitive    : %5d" [llength $ungrouped_bram_cells]]
if {[llength $ungrouped_bram_cells] > 0} {
    lappend all_groups [list "OtherRAM" $ungrouped_bram_cells "ram"]
    lappend group_names "OtherRAM"
    log_msg "  → 已加入 OtherRAM 兜底组，以下为样例（最多 20 个）："
    set sample_idx 0
    foreach cname [lsort $ungrouped_bram_names] {
        incr sample_idx
        log_msg "    $cname"
        if {$sample_idx >= 20} { break }
    }
} else {
    log_msg "  ✔ 所有 RAM primitive 都已落入手工分组。"
}

set num_groups [llength $group_names]
log_msg "\n  共 $num_groups 个有效 endpoint 组\n"

if {$num_groups == 0} {
    log_msg "\n✘ 未找到任何 timing endpoint 组，脚本退出。"
    log_msg "  请检查 TOP_HIER 和层级路径配置是否与综合后的设计匹配。"
    log_msg "  提示：使用 get_cells -hierarchical *frontend_ftq* 手动验证。"
    close $report_file
    return
}

# ---- Step 2: 逐对分析路径 ----
set per_group_candidate_limit [expr {$MAX_PATHS * $PATH_CANDIDATE_MULTIPLIER}]
log_msg "\n\[Step 2\] 分析各组间时序路径 (每组最多 $MAX_PATHS 个路径族)...\n"
log_msg "  每组预取 $per_group_candidate_limit 条候选，按归一化 startpoint/endpoint 去重。"
log_msg "  Route% = NetDelay / DataPath；Span = 起终点 SLICE LOC 坐标曼哈顿距离。"
log_msg [string repeat "=" 148]

# 存储汇总数据
array set delay_matrix {}
array set slack_matrix {}
array set levels_matrix {}
array set raw_slack_matrix {}
array set raw_delay_matrix {}
array set raw_levels_matrix {}

foreach from_grp $all_groups {
    set from_name   [lindex $from_grp 0]
    set from_cells  [lindex $from_grp 1]

    foreach to_grp $all_groups {
        set to_name   [lindex $to_grp 0]
        set to_cells  [lindex $to_grp 1]

        # 跳过自身（对角线标记为 --- 但仍分析，以免遗漏组内关键路径）
        set is_self [expr {$from_name eq $to_name}]

        # 多取一些候选，再按路径族去重，避免同一 bus 的相邻 bit 占满报告。
        set path_candidates [get_timing_paths -quiet \
            -from $from_cells \
            -to   $to_cells \
            -max_paths $per_group_candidate_limit \
            -nworst $per_group_candidate_limit]

        set candidate_count [llength $path_candidates]
        set all_clusters [cluster_path_candidates $path_candidates]
        set family_count [llength $all_clusters]
        set clusters [lrange $all_clusters 0 [expr {$MAX_PATHS - 1}]]
        set path_count [llength $clusters]

        if {$path_count == 0} {
            if {$is_self} {
                set delay_matrix($from_name,$to_name) "  ---  "
                set slack_matrix($from_name,$to_name) "  ---  "
            } else {
                set delay_matrix($from_name,$to_name) "  N/P  "
                set slack_matrix($from_name,$to_name) "  N/P  "
            }
            continue
        }

        # 取最差路径信息
        set worst_path [lindex [lindex $clusters 0] 1]
        set worst_slack      [get_property SLACK $worst_path]
        set worst_data_delay [get_property DATAPATH_DELAY $worst_path]
        set worst_levels     [get_property LOGIC_LEVELS $worst_path]

        set delay_matrix($from_name,$to_name) [format_ns $worst_data_delay]
        set slack_matrix($from_name,$to_name) [format_ns $worst_slack]
        set levels_matrix($from_name,$to_name) [format_levels $worst_levels]
        if {[is_numeric $worst_slack]} {
            set raw_slack_matrix($from_name,$to_name)  $worst_slack
            set raw_delay_matrix($from_name,$to_name)  $worst_data_delay
            set raw_levels_matrix($from_name,$to_name) $worst_levels
        }

        # 打印详细信息
        log_msg ""
        log_msg [format "  %s → %s  (候选 %d，去重后 %d 个路径族，显示 %d)" \
            $from_name $to_name $candidate_count $family_count $path_count]
        log_msg [string repeat "-" 148]
        log_msg [format "    %-3s %9s %8s %8s %6s %5s %5s %7s %5s %4s %-22s %s" \
            "#" "Slack" "Logic" "Net" "Route%" "Lvl" "FO" "Skew" "Span" "Hits" "Diagnosis" "Endpoint"]
        log_msg [string repeat "-" 148]

        set idx 0
        foreach cluster $clusters {
            incr idx
            set p [lindex $cluster 1]
            set p_hits [lindex $cluster 2]
            set p_slack  [get_property SLACK $p]
            set p_end    [get_property ENDPOINT_PIN $p]
            set metrics  [path_physical_metrics $p]

            # 截断 endpoint 显示名
            set end_short $p_end
            if {[string length $p_end] > 46} {
                set end_short "...[string range $p_end end-43 end]"
            }

            log_msg [format "    %-3d %9s %8s %8s %6s %5s %5s %7s %5s %4d %-22s %s" \
                $idx \
                [format_ns $p_slack] \
                [format_ns [dict get $metrics logic_delay]] \
                [format_ns [dict get $metrics net_delay]] \
                [format_percent [dict get $metrics route_ratio]] \
                [format_levels [dict get $metrics levels]] \
                [format_integer [dict get $metrics fanout]] \
                [format_ns [dict get $metrics skew]] \
                [format_integer [dict get $metrics span]] \
                $p_hits \
                [dict get $metrics diagnosis] \
                $end_short]
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

# ---- 逻辑路径汇总（替代 Top-N 线网报告）----
log_msg ""
log_msg [string repeat "=" 80]
log_msg "\n\[Step 4\] 逻辑路径汇总（按 Slack 升序）\n"
log_msg "  每行 = 一条独立的架构级路径（寄存器组 → 寄存器组）"
log_msg "  FAIL = 时序违例，tight = slack < 0.5ns\n"

# 收集所有有效路径
set path_list {}
foreach from_name $group_names {
    foreach to_name $group_names {
        set key "$from_name,$to_name"
        if {[info exists raw_slack_matrix($key)]} {
            lappend path_list [list $raw_slack_matrix($key) \
                $raw_delay_matrix($key) \
                $raw_levels_matrix($key) \
                $from_name $to_name]
        }
    }
}

# 按 slack 升序排序
set sorted_paths [lsort -real -index 0 $path_list]

log_msg [format "  %-4s  %10s  %10s  %6s  %-35s %s" \
    "#" "Slack(ns)" "DataPath" "Levels" "逻辑路径" "状态"]
log_msg [string repeat "-" 96]

set pidx 0
foreach entry $sorted_paths {
    incr pidx
    set p_slack  [lindex $entry 0]
    set p_data   [lindex $entry 1]
    set p_levels [lindex $entry 2]
    set p_from   [lindex $entry 3]
    set p_to     [lindex $entry 4]

    set status ""
    if {$p_slack < 0} {
        set status "← FAIL"
    } elseif {$p_slack < 0.500} {
        set status "← tight"
    }

    set path_name "${p_from} → ${p_to}"
    log_msg [format "  %-4d  %10s  %10s  %6s  %-35s %s" \
        $pidx [format_ns $p_slack] [format_ns $p_data] [format_levels $p_levels] $path_name $status]
}

# 统计
set fail_count 0
set tight_count 0
foreach entry $sorted_paths {
    set s [lindex $entry 0]
    if {$s < 0}          { incr fail_count }
    if {$s >= 0 && $s < 0.500} { incr tight_count }
}
log_msg ""
log_msg [format "  汇总：%d 条违例 (FAIL) / %d 条偏紧 (tight) / %d 条总路径" \
    $fail_count $tight_count [llength $sorted_paths]]

# ---- Step 5: 全局最差路径兜底 ----
log_msg ""
log_msg [string repeat "=" 148]
log_msg "\n\[Step 5\] 全局最差路径族（最多 ${GLOBAL_MAX_PATHS} 个，不受分组限制）\n"
log_msg "  用于发现未被寄存器组分类覆盖的关键路径，并区分逻辑、布线和布局因素。"

set global_candidate_limit [expr {$GLOBAL_MAX_PATHS * $GLOBAL_CANDIDATE_MULTIPLIER}]
set global_candidates [get_timing_paths -quiet \
    -max_paths $global_candidate_limit \
    -nworst $global_candidate_limit \
    -sort_by slack]
set global_all_clusters [cluster_path_candidates $global_candidates]
set global_paths [lrange $global_all_clusters 0 [expr {$GLOBAL_MAX_PATHS - 1}]]
if {[llength $global_paths] > 0} {
    log_msg [format "  候选 %d 条，去重后 %d 个路径族，显示 %d 个。" \
        [llength $global_candidates] [llength $global_all_clusters] [llength $global_paths]]
    log_msg "  Hits = 预取候选中属于该路径族的条数；Diagnosis 为启发式诊断，不是 Vivado 根因判定。"
    log_msg [format "  %-4s %9s %8s %8s %8s %6s %5s %5s %7s %5s %4s %-22s %s" \
        "#" "Slack" "Data" "Logic" "Net" "Route%" "Lvl" "FO" "Skew" "Span" "Hits" "Diagnosis" "State"]
    log_msg [string repeat "-" 148]
    set gidx 0
    foreach cluster $global_paths {
        incr gidx
        set gp [lindex $cluster 1]
        set g_hits [lindex $cluster 2]
        set g_slack  [get_property SLACK $gp]
        set g_start  [get_property STARTPOINT_PIN $gp]
        set g_end    [get_property ENDPOINT_PIN $gp]
        set metrics  [path_physical_metrics $gp]
        if {[string length $g_start] > 68} {
            set g_start "...[string range $g_start end-65 end]"
        }
        if {[string length $g_end] > 68} {
            set g_end "...[string range $g_end end-65 end]"
        }
        set g_status ""
        if {[is_numeric $g_slack] && $g_slack < 0} { set g_status "← FAIL" }
        log_msg [format "  %-4d %9s %8s %8s %8s %6s %5s %5s %7s %5s %4d %-22s %s" \
            $gidx \
            [format_ns $g_slack] \
            [format_ns [dict get $metrics data_delay]] \
            [format_ns [dict get $metrics logic_delay]] \
            [format_ns [dict get $metrics net_delay]] \
            [format_percent [dict get $metrics route_ratio]] \
            [format_levels [dict get $metrics levels]] \
            [format_integer [dict get $metrics fanout]] \
            [format_ns [dict get $metrics skew]] \
            [format_integer [dict get $metrics span]] \
            $g_hits \
            [dict get $metrics diagnosis] \
            $g_status]
        log_msg "       Path: $g_start → $g_end"
        log_msg [format "       Phys: %s (%s) → %s (%s)" \
            [dict get $metrics start_loc] [dict get $metrics start_cr] \
            [dict get $metrics end_loc] [dict get $metrics end_cr]]
    }
} else {
    log_msg "  （未找到时序路径）"
}

# ---- 完成 ----
log_msg ""
log_msg [string repeat "=" 80]
log_msg " 报告已保存至: ${OUTPUT_DIR}/stage_timing_report.txt"
log_msg [string repeat "=" 80]

close $report_file

puts "\n✔ 完成！请查看 ${OUTPUT_DIR}/stage_timing_report.txt"
