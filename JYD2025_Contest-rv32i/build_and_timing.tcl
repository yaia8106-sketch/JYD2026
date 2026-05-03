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

set workspace      "/home/anokyai/桌面/CPU_Workspace"
set project_path   "${workspace}/JYD2025_Contest-rv32i/digital_twin.xpr"
set timing_script  "${workspace}/03_Timing_Analysis/scripts/report_stage_timing.tcl"
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
        set build_jobs 4
    }
}

set coe_src "${workspace}/02_Design/coe/${coe_name}"
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
    file copy -force "${src}/irom.coe" "${dst}/irom.coe"
    file copy -force "${src}/dram.coe" "${dst}/dram.coe"
    puts ">>> COE copied: [file size ${dst}/irom.coe]B irom, [file size ${dst}/dram.coe]B dram"
}

proc step_regen_ip {} {
    upvar coe_dst dst
    puts ">>> Regenerating IROM/DRAM IP..."
    set_property CONFIG.Coe_File [file normalize "${dst}/irom.coe"] [get_ips IROM4MyOwn]
    set_property CONFIG.Coe_File [file normalize "${dst}/dram.coe"] [get_ips DRAM4MyOwn]
    foreach ip {IROM4MyOwn DRAM4MyOwn} {
        set ip_run "${ip}_synth_1"
        if {[llength [get_runs -quiet $ip_run]] > 0} {
            reset_run $ip_run
        }
        generate_target all [get_ips $ip]
    }
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
