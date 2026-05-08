# ============================================================
# run_vivado_flow.tcl
#
# One-shot Vivado driver for JYD2025_Contest-rv32i:
#   COE/IP update -> synthesis -> implementation (no bitstream) ->
#   open_run impl_1 -> source report_stage_timing.tcl
#
# Called by:
#   ./run_vivado_flow.sh [coe_name] [jobs]
#
# Direct Vivado usage:
#   vivado -mode tcl -source 03_Timing_Analysis/run_vivado_flow.tcl \
#          -tclargs /home/anokyai/桌面/CPU_Workspace src0 20
# ============================================================

if {$argc >= 1} {
    set workspace [lindex $argv 0]
} else {
    set workspace "/home/anokyai/桌面/CPU_Workspace"
}
if {$argc >= 2} { set coe_name [lindex $argv 1] } else { set coe_name "current" }
if {$argc >= 3} { set build_jobs [lindex $argv 2] } else { set build_jobs 20 }

set workspace [file normalize $workspace]
set project_path  "${workspace}/JYD2025_Contest-rv32i/digital_twin.xpr"
set timing_script "${workspace}/03_Timing_Analysis/report_stage_timing.tcl"
set coe_dst       "${workspace}/JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/imports/JYD2025/resource/coe"

proc die {msg} {
    puts "ERROR: $msg"
    exit 1
}

proc ensure_file {path label} {
    if {![file exists $path]} {
        die "$label not found: $path"
    }
}

proc run_status_ok {run_name} {
    set status [get_property STATUS [get_runs $run_name]]
    puts ">>> ${run_name}: ${status}"
    if {![regexp -nocase {complete} $status]} {
        die "${run_name} did not complete successfully: ${status}"
    }
}

proc normalize_coe_word {word} {
    set word [string trim $word]
    regsub -nocase {^0x} $word "" word
    if {![regexp {^[0-9A-Fa-f]+$} $word]} {
        die "Invalid COE word: ${word}"
    }
    return [string toupper [string range "00000000${word}" end-7 end]]
}

proc read_irom_words {src} {
    set fp [open $src r]
    set text [read $fp]
    close $fp

    set words {}
    set in_vec 0
    foreach raw [split $text "\n"] {
        set line [string trim $raw]
        if {[regexp -nocase {memory_initialization_vector\s*=(.*)} $line -> rest]} {
            set in_vec 1
            set line $rest
        } elseif {!$in_vec} {
            continue
        }

        regsub -all {;} $line "," line
        foreach item [split $line ","] {
            set word [string trim $item]
            if {$word ne ""} {
                lappend words [normalize_coe_word $word]
            }
        }
    }

    return $words
}

proc write_irom_slot_coe {dst words offset} {
    set fp [open $dst w]
    puts $fp "memory_initialization_radix=16;"
    puts $fp "memory_initialization_vector="
    for {set i 0} {$i < 4096} {incr i} {
        set src_idx [expr {$i * 2 + $offset}]
        if {$src_idx < [llength $words]} {
            set word [string toupper [lindex $words $src_idx]]
        } else {
            set word "00000013"
        }
        set word [string range "00000000${word}" end-7 end]
        if {$i == 4095} {
            puts $fp "${word};"
        } else {
            puts $fp "${word},"
        }
    }
    close $fp
}

proc write_irom_slot_coes {src slot0_dst slot1_dst} {
    set words [read_irom_words $src]
    if {[llength $words] > 4096} {
        die "irom.coe has [llength $words] words, but slot IROM supports 4096 base words"
    }
    write_irom_slot_coe $slot0_dst $words 0
    write_irom_slot_coe $slot1_dst $words 1
    puts ">>> IROM slots: [llength $words] words -> irom_slot0.coe / irom_slot1.coe"
}

proc verify_copied_coe {src dst label} {
    set src_words [read_irom_words $src]
    set dst_words [read_irom_words $dst]
    if {[llength $src_words] != [llength $dst_words]} {
        die "${label} COE length mismatch: source=[llength $src_words], import=[llength $dst_words]"
    }
    for {set i 0} {$i < [llength $src_words]} {incr i} {
        if {[lindex $src_words $i] ne [lindex $dst_words $i]} {
            die "${label} COE mismatch at word ${i}: source=[lindex $src_words $i], import=[lindex $dst_words $i]"
        }
    }
    puts ">>> COE check OK: ${label} copied ([llength $src_words] words)"
}

proc verify_irom_slot_coes {irom slot0 slot1} {
    set words [read_irom_words $irom]
    set slot_words [list [read_irom_words $slot0] [read_irom_words $slot1]]
    foreach offset {0 1} {
        set bank [lindex $slot_words $offset]
        if {[llength $bank] != 4096} {
            die "irom_slot${offset}.coe has [llength $bank] words, expected 4096"
        }
        for {set i 0} {$i < 4096} {incr i} {
            set src_idx [expr {$i * 2 + $offset}]
            if {$src_idx < [llength $words]} {
                set expected [lindex $words $src_idx]
            } else {
                set expected "00000013"
            }
            set actual [lindex $bank $i]
            if {$actual ne $expected} {
                die "irom_slot${offset}.coe mismatch at bank word ${i} (source word ${src_idx}): expected ${expected}, got ${actual}"
            }
        }
    }
    puts ">>> COE check OK: IROM slot0=even words, slot1=odd words, NOP padded"
}

proc verify_ip_coe_binding {ip coe_file} {
    set actual [get_property CONFIG.Coe_File [get_ips $ip]]
    set expected_norm [file normalize $coe_file]
    set actual_norm [file normalize $actual]
    if {$actual_norm ne $expected_norm} {
        die "${ip} CONFIG.Coe_File mismatch: expected ${expected_norm}, got ${actual_norm}"
    }
    puts ">>> IP check OK: ${ip} -> ${expected_norm}"
}

proc ensure_irom_slot_ip {ip coe_file} {
    if {[llength [get_ips -quiet $ip]] == 0} {
        puts ">>> Creating IP ${ip}..."
        create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name $ip
    }

    set_property -dict [list \
        CONFIG.Memory_Type {Single_Port_ROM} \
        CONFIG.Write_Width_A {32} \
        CONFIG.Write_Depth_A {4096} \
        CONFIG.Enable_A {Always_Enabled} \
        CONFIG.Load_Init_File {true} \
        CONFIG.Coe_File [file normalize $coe_file] \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
        CONFIG.Register_PortA_Output_of_Memory_Core {false} \
    ] [get_ips $ip]
}

proc step_copy_coe {coe_src coe_dst coe_name} {
    puts ">>> Copying COE files (${coe_name})..."
    file mkdir $coe_dst
    ensure_file "${coe_src}/irom.coe" "IROM COE"
    ensure_file "${coe_src}/dram.coe" "DRAM COE"

    file copy -force "${coe_src}/irom.coe" "${coe_dst}/irom.coe"
    file copy -force "${coe_src}/dram.coe" "${coe_dst}/dram.coe"
    write_irom_slot_coes "${coe_dst}/irom.coe" "${coe_dst}/irom_slot0.coe" "${coe_dst}/irom_slot1.coe"
    verify_copied_coe "${coe_src}/irom.coe" "${coe_dst}/irom.coe" "IROM"
    verify_copied_coe "${coe_src}/dram.coe" "${coe_dst}/dram.coe" "DRAM"
    verify_irom_slot_coes "${coe_dst}/irom.coe" "${coe_dst}/irom_slot0.coe" "${coe_dst}/irom_slot1.coe"
    puts ">>> COE copied: [file size ${coe_dst}/irom.coe]B irom, [file size ${coe_dst}/dram.coe]B dram"
}

proc step_regen_ip {coe_dst} {
    puts ">>> Regenerating IROM slot banks / DRAM IP..."
    ensure_irom_slot_ip IROMEven32 "${coe_dst}/irom_slot0.coe"
    ensure_irom_slot_ip IROMOdd32  "${coe_dst}/irom_slot1.coe"
    set_property CONFIG.Coe_File [file normalize "${coe_dst}/dram.coe"] [get_ips DRAM4MyOwn]
    verify_ip_coe_binding IROMEven32 "${coe_dst}/irom_slot0.coe"
    verify_ip_coe_binding IROMOdd32  "${coe_dst}/irom_slot1.coe"
    verify_ip_coe_binding DRAM4MyOwn "${coe_dst}/dram.coe"

    foreach ip {IROMEven32 IROMOdd32 DRAM4MyOwn} {
        set ip_run "${ip}_synth_1"
        if {[llength [get_runs -quiet $ip_run]] > 0} {
            reset_run $ip_run
        }
        generate_target all [get_ips $ip]
    }
}

proc step_synth {jobs} {
    puts ">>> Resetting and running synthesis (-jobs ${jobs})..."
    reset_run synth_1
    if {[llength [get_runs -quiet impl_1]] > 0} {
        reset_run impl_1
    }
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    run_status_ok synth_1
}

proc step_impl {jobs} {
    puts ">>> Running implementation for timing (-jobs ${jobs}, no bitstream)..."
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
    launch_runs impl_1 -jobs $jobs
    wait_on_run impl_1
    run_status_ok impl_1
}

proc step_timing {run_name timing_script} {
    puts ">>> Opening ${run_name} and sourcing timing report..."
    open_run $run_name
    puts ">>> source ${timing_script}"
    source $timing_script
}

ensure_file $project_path "Vivado project"
ensure_file $timing_script "Timing script"

set coe_src "${workspace}/02_Design/coe/${coe_name}"
if {![file isdirectory $coe_src]} {
    set coe_src "${workspace}/02_Design/coe/single_issue/${coe_name}"
}
if {![file isdirectory $coe_src]} {
    die "COE directory not found for '${coe_name}': tried 02_Design/coe/${coe_name} and 02_Design/coe/single_issue/${coe_name}"
}

puts "========================================================"
puts " run_vivado_flow.tcl"
puts "========================================================"
puts " workspace : ${workspace}"
puts " project   : ${project_path}"
puts " coe       : ${coe_name} (${coe_src})"
puts " jobs      : ${build_jobs}"
puts " timing    : ${timing_script}"
puts "========================================================"

open_project $project_path

step_copy_coe $coe_src $coe_dst $coe_name
step_regen_ip $coe_dst
step_synth $build_jobs
step_impl $build_jobs
step_timing impl_1 $timing_script

puts "\n>>> DONE: synth + impl + timing report complete."
close_project
