# ============================================================
# build_and_timing.tcl — Modular Vivado build script
#
# Modes:
#   all     — COE → IP → synth → impl → timing → bitstream
#   check   — COE → IP → synth → impl → timing (不生成 bitstream)
#   synth   — COE → IP → synth
#   impl    — impl + bitstream (assumes synth done)
#   timing  — open impl → timing report
#   coe     — COE → IP regenerate only
#
# Usage from shell:
#   vivado -mode tcl -source build_and_timing.tcl -tclargs <mode> <coe> <jobs>
# Usage from Vivado TCL console:
#   set build_mode all; set coe_name src2; source build_and_timing.tcl
# ============================================================

set workspace      [file normalize [file join [file dirname [info script]] ".."]]
set project_path   "${workspace}/JYD2025_Contest-rv32i/digital_twin.xpr"
set timing_script  "${workspace}/03_Timing_Analysis/report_stage_timing.tcl"
set coe_dst        "${workspace}/JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/imports/JYD2025/resource/coe"

# ---- Parse arguments ----
if {![info exists build_mode]} {
    if {$argc >= 1} {
        set build_mode [lindex $argv 0]
    } else {
        set build_mode "all"
    }
}
if {![info exists coe_name]} {
    if {$argc >= 2} {
        set coe_name [lindex $argv 1]
    } else {
        set coe_name "current"
    }
}

if {![info exists build_jobs]} {
    if {$argc >= 3} {
        set build_jobs [lindex $argv 2]
    } else {
        set build_jobs 18
    }
}

set coe_src "${workspace}/02_Design/coe/${coe_name}"
if {![file isdirectory $coe_src]} {
    set coe_src "${workspace}/02_Design/coe/single_issue/${coe_name}"
}
set valid_modes {all check synth impl timing coe}
if {$build_mode ni $valid_modes} {
    puts "ERROR: Unknown mode '$build_mode'. Valid: $valid_modes"
    exit 1
}

puts "========================================================"
puts " Mode: ${build_mode}  |  COE: ${coe_name}"
puts "========================================================"

# ---- Procedures ----
proc step_copy_coe {} {
    upvar coe_src src coe_dst dst coe_name name
    puts ">>> Copying COE files (${name})..."
    if {![file exists "${src}/irom.coe"]} {
        error "IROM COE not found: ${src}/irom.coe"
    }
    if {![file exists "${src}/dram.coe"]} {
        error "DRAM COE not found: ${src}/dram.coe"
    }
    file mkdir $dst
    file copy -force "${src}/irom.coe" "${dst}/irom.coe"
    file copy -force "${src}/dram.coe" "${dst}/dram.coe"
    write_irom_slot_coes "${dst}/irom.coe" "${dst}/irom_slot0.coe" "${dst}/irom_slot1.coe"
    verify_copied_coe "${src}/irom.coe" "${dst}/irom.coe" "IROM"
    verify_copied_coe "${src}/dram.coe" "${dst}/dram.coe" "DRAM"
    verify_irom_slot_coes "${dst}/irom.coe" "${dst}/irom_slot0.coe" "${dst}/irom_slot1.coe"
    puts ">>> COE copied: [file size ${dst}/irom.coe]B irom, [file size ${dst}/dram.coe]B dram"
}

proc normalize_coe_word {word} {
    set word [string trim $word]
    regsub -nocase {^0x} $word "" word
    if {![regexp {^[0-9A-Fa-f]+$} $word]} {
        error "Invalid COE word: ${word}"
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

proc write_irom_slot_coes {src slot0_dst slot1_dst} {
    set words [read_irom_words $src]

    if {[llength $words] > 4096} {
        error "irom.coe has [llength $words] words, but slot IROM supports 4096 base words"
    }

    write_irom_slot_coe $slot0_dst $words 0
    write_irom_slot_coe $slot1_dst $words 1
    puts ">>> IROM slots: [llength $words] words -> irom_slot0.coe / irom_slot1.coe"
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

proc verify_copied_coe {src dst label} {
    set src_words [read_irom_words $src]
    set dst_words [read_irom_words $dst]
    if {[llength $src_words] != [llength $dst_words]} {
        error "${label} COE length mismatch: source=[llength $src_words], import=[llength $dst_words]"
    }
    for {set i 0} {$i < [llength $src_words]} {incr i} {
        if {[lindex $src_words $i] ne [lindex $dst_words $i]} {
            error "${label} COE mismatch at word ${i}: source=[lindex $src_words $i], import=[lindex $dst_words $i]"
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
            error "irom_slot${offset}.coe has [llength $bank] words, expected 4096"
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
                error "irom_slot${offset}.coe mismatch at bank word ${i} (source word ${src_idx}): expected ${expected}, got ${actual}"
            }
        }
    }
    puts ">>> COE check OK: IROM slot0=even words, slot1=odd words, NOP padded"
}

proc verify_ip_coe_binding {ip coe_file} {
    set actual [get_property CONFIG.Coe_File [get_ips $ip]]
    set expected_norm [file normalize $coe_file]
    if {[file pathtype $actual] eq "absolute"} {
        set actual_norm [file normalize $actual]
    } else {
        set ip_file [get_property IP_FILE [get_ips $ip]]
        set actual_norm [file normalize [file join [file dirname $ip_file] $actual]]
    }
    if {$actual_norm ne $expected_norm} {
        error "${ip} CONFIG.Coe_File mismatch: expected ${expected_norm}, got ${actual_norm}"
    }
    puts ">>> IP check OK: ${ip} -> ${expected_norm}"
}

proc step_regen_ip {} {
    upvar coe_dst dst
    puts ">>> Regenerating IROM slot banks/DRAM IP..."
    # Keep legacy IP module names to avoid wider Vivado project churn:
    # IROMEven32 is slot0, IROMOdd32 is slot1.
    ensure_irom_slot_ip IROMEven32 "${dst}/irom_slot0.coe"
    ensure_irom_slot_ip IROMOdd32  "${dst}/irom_slot1.coe"
    set_property CONFIG.Coe_File [file normalize "${dst}/dram.coe"] [get_ips DRAM4MyOwn]
    verify_ip_coe_binding IROMEven32 "${dst}/irom_slot0.coe"
    verify_ip_coe_binding IROMOdd32  "${dst}/irom_slot1.coe"
    verify_ip_coe_binding DRAM4MyOwn "${dst}/dram.coe"
    foreach ip {IROMEven32 IROMOdd32 DRAM4MyOwn} {
        set ip_run "${ip}_synth_1"
        if {[llength [get_runs -quiet $ip_run]] > 0} {
            reset_run $ip_run
        }
        generate_target all [get_ips $ip]
    }
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

proc step_synth {jobs} {
    puts ">>> Resetting and running synthesis (-jobs $jobs)..."
    reset_run synth_1
    reset_run impl_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    puts ">>> Synthesis: [get_property STATUS [get_runs synth_1]]"
}

proc step_impl {jobs {with_bitstream 1}} {
    puts ">>> Configuring implementation directives..."
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
    if {$with_bitstream} {
        puts ">>> Running implementation + bitstream (-jobs $jobs)..."
        launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    } else {
        puts ">>> Running implementation (-jobs $jobs, no bitstream)..."
        launch_runs impl_1 -jobs $jobs
    }
    wait_on_run impl_1
    puts ">>> Implementation: [get_property STATUS [get_runs impl_1]]"
}

proc step_timing {script} {
    puts ">>> Running timing analysis..."
    open_run impl_1
    source $script
}

# ---- Open project ----
puts ">>> Opening project..."
open_project $project_path

# ---- Execute based on mode ----
switch $build_mode {
    coe {
        step_copy_coe
        step_regen_ip
    }
    synth {
        step_copy_coe
        step_regen_ip
        step_synth $build_jobs
    }
    impl {
        step_impl $build_jobs 1
    }
    timing {
        step_timing $timing_script
    }
    check {
        step_copy_coe
        step_regen_ip
        step_synth $build_jobs
        step_impl $build_jobs 0
        step_timing $timing_script
    }
    all {
        step_copy_coe
        step_regen_ip
        step_synth $build_jobs
        step_impl $build_jobs 0
        step_timing $timing_script
        puts ">>> Generating bitstream..."
        reset_run impl_1 -from_step write_bitstream
        launch_runs impl_1 -to_step write_bitstream -jobs $build_jobs
        wait_on_run impl_1
        puts ">>> Bitstream: [get_property STATUS [get_runs impl_1]]"
    }
}

puts "\n>>> DONE (mode: ${build_mode}, coe: ${coe_name})."
unset build_mode
unset coe_name
unset build_jobs
close_project
