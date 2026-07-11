# Clean 200 MHz synthesis/implementation flow used by build.sh.
# It regenerates the private IROM64/DRAM4MyOwn IPs from the selected COE set,
# runs two explicit post-route Explore passes, updates the stage report, and
# writes a bitstream only when final setup timing is met.

proc flow_fail {message} {
    return -code error "run_synth_impl.tcl: $message"
}

proc require_positive_integer {option value} {
    if {![string is integer -strict $value] || $value < 1} {
        flow_fail "$option requires a positive integer, got '$value'"
    }
}

proc run_status {run_name} {
    set run_obj [get_runs -quiet $run_name]
    if {[llength $run_obj] == 0} {
        flow_fail "Vivado run '$run_name' does not exist"
    }
    return [get_property STATUS $run_obj]
}

proc require_complete_run {run_name} {
    set status [run_status $run_name]
    set progress [get_property PROGRESS [get_runs $run_name]]
    puts "  $run_name status: $status ($progress)"
    if {![regexp -nocase {complete} $status] && $progress ne "100%"} {
        flow_fail "run '$run_name' did not complete successfully"
    }
}

proc routed_checkpoint {run_name} {
    set run_obj [get_runs -quiet $run_name]
    if {[llength $run_obj] == 0} {
        flow_fail "Vivado run '$run_name' does not exist"
    }
    set run_dir [get_property DIRECTORY $run_obj]
    set candidates [glob -nocomplain -directory $run_dir "*_routed.dcp"]
    if {[llength $candidates] == 0} {
        return ""
    }
    return [lindex $candidates 0]
}

proc write_pass_outputs {output_dir pass_number} {
    set stem "postroute_physopt_pass${pass_number}"
    set checkpoint_file [file join $output_dir "${stem}.dcp"]
    set timing_file [file join $output_dir "timing_${stem}.rpt"]

    write_checkpoint -force $checkpoint_file
    report_timing_summary \
        -delay_type min_max \
        -max_paths 100 \
        -report_unconstrained \
        -warn_on_violation \
        -file $timing_file

    set worst_paths [get_timing_paths -quiet -setup -max_paths 1]
    if {[llength $worst_paths] > 0} {
        puts "  pass $pass_number setup WNS: [get_property SLACK [lindex $worst_paths 0]] ns"
    }
    puts "  checkpoint: $checkpoint_file"
    puts "  report    : $timing_file"
}

proc read_rtl_filelist {filelist} {
    if {![file exists $filelist]} {
        flow_fail "RTL filelist not found: $filelist"
    }
    set handle [open $filelist r]
    set contents [read $handle]
    close $handle

    set base_dir [file dirname $filelist]
    set result {}
    foreach raw_line [split $contents "\n"] {
        set line [string trim $raw_line]
        if {$line eq "" || [string match "#*" $line]} {
            continue
        }
        set rtl_file [file normalize [file join $base_dir $line]]
        if {![file exists $rtl_file]} {
            flow_fail "RTL source from $filelist is missing: $rtl_file"
        }
        lappend result $rtl_file
    }
    return $result
}

proc bind_canonical_design_sources {workspace} {
    set source_set [get_filesets sources_1]
    set rtl_root [file normalize [file join $workspace "02_Design" "rtl"]]
    set filelist_dir [file join $rtl_root "filelists"]

    set canonical_rtl {}
    foreach filelist_name {cpu_blocks.f dcache_bram.f} {
        set canonical_rtl [concat $canonical_rtl \
            [read_rtl_filelist [file join $filelist_dir $filelist_name]]]
    }
    foreach relative_path {
        core/cpu_top.sv
        mmio/mmio_bridge.sv
        top/student_top.sv
    } {
        set rtl_file [file normalize [file join $rtl_root $relative_path]]
        if {![file exists $rtl_file]} {
            flow_fail "canonical RTL source is missing: $rtl_file"
        }
        lappend canonical_rtl $rtl_file
    }
    set canonical_rtl [lsort -unique $canonical_rtl]

    # Remove only CPU workspace RTL. Official shell sources under the Vivado
    # project remain untouched.
    foreach file_obj [get_files -quiet -of_objects $source_set] {
        set old_path [file normalize [get_property NAME $file_obj]]
        if {[file extension $old_path] eq ".sv"
            && [string first "/02_Design/rtl/" $old_path] >= 0} {
            remove_files $file_obj
        }
    }
    add_files -fileset $source_set -norecurse $canonical_rtl

    foreach ip_relative {
        JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/ip/IROM64/IROM64.xci
        JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/ip/DRAM4MyOwn/DRAM4MyOwn.xci
    } {
        set ip_file [file normalize [file join $workspace $ip_relative]]
        if {![file exists $ip_file]} {
            flow_fail "memory IP is missing: $ip_file"
        }
        set ip_name [file rootname [file tail $ip_file]]
        foreach existing_ip [get_ips -quiet $ip_name] {
            set existing_ip_file [file normalize [get_property IP_FILE $existing_ip]]
            if {$existing_ip_file ne $ip_file} {
                puts "Replacing stale $ip_name IP: $existing_ip_file"
                remove_files [get_files $existing_ip_file]
            }
        }
        if {[llength [get_files -quiet $ip_file]] == 0} {
            add_files -fileset $source_set -norecurse $ip_file
        }
    }

    update_compile_order -fileset sources_1
    puts "Bound [llength $canonical_rtl] canonical RTL files and private memory IPs."
}

set jobs 16
set coe_dir_arg ""
set bitstream_file_arg ""
set dry_run 0

if {![info exists argv]} {
    set argv {}
}

set arg_index 0
while {$arg_index < [llength $argv]} {
    set arg [lindex $argv $arg_index]
    switch -- $arg {
        --jobs {
            incr arg_index
            if {$arg_index >= [llength $argv]} { flow_fail "missing value after --jobs" }
            set jobs [lindex $argv $arg_index]
            require_positive_integer --jobs $jobs
        }
        --coe-dir {
            incr arg_index
            if {$arg_index >= [llength $argv]} { flow_fail "missing value after --coe-dir" }
            set coe_dir_arg [lindex $argv $arg_index]
        }
        --bitstream-file {
            incr arg_index
            if {$arg_index >= [llength $argv]} { flow_fail "missing value after --bitstream-file" }
            set bitstream_file_arg [lindex $argv $arg_index]
        }
        --dry-run {
            set dry_run 1
        }
        default {
            flow_fail "unknown option '$arg'"
        }
    }
    incr arg_index
}

set script_dir [file normalize [file dirname [info script]]]
set workspace [file normalize [file join $script_dir ".."]]
set project_path [file join $workspace "JYD2025_Contest-rv32i" "digital_twin.xpr"]
set output_dir [file join $script_dir "results"]
set stage_timing_script [file join $script_dir "report_stage_timing.tcl"]

if {$coe_dir_arg eq ""} {
    flow_fail "--coe-dir is required"
}
if {$bitstream_file_arg eq ""} {
    flow_fail "--bitstream-file is required"
}

if {[file pathtype $coe_dir_arg] eq "absolute"} {
    set coe_dir [file normalize $coe_dir_arg]
} else {
    set coe_dir [file normalize [file join $workspace $coe_dir_arg]]
}
set irom64_coe [file join $coe_dir "irom64.coe"]
set dram_coe [file join $coe_dir "dram.coe"]

if {[file pathtype $bitstream_file_arg] eq "absolute"} {
    set bitstream_file [file normalize $bitstream_file_arg]
} else {
    set bitstream_file [file normalize [file join $workspace $bitstream_file_arg]]
}

if {![file exists $project_path]} { flow_fail "project not found: $project_path" }
if {![file exists $stage_timing_script]} { flow_fail "stage report script not found: $stage_timing_script" }
if {![file exists $irom64_coe]} { flow_fail "IROM64 COE not found: $irom64_coe" }
if {![file exists $dram_coe]} { flow_fail "DRAM COE not found: $dram_coe" }

puts "================================================================"
puts " CPU synthesis, implementation, timing, and bitstream flow"
puts "================================================================"
puts "Project        : $project_path"
puts "Jobs           : $jobs"
puts "IROM64 COE     : $irom64_coe"
puts "DRAM COE       : $dram_coe"
puts "Bitstream      : $bitstream_file"
puts "Post-route     : Explore pass 1 + Explore pass 2"

set open_project_obj [current_project -quiet]
if {$open_project_obj ne ""} {
    close_project
}
open_project $project_path
bind_canonical_design_sources $workspace

set synth_run [get_runs -quiet synth_1]
set impl_run [get_runs -quiet impl_1]
if {[llength $synth_run] == 0} { flow_fail "synth_1 does not exist" }
if {[llength $impl_run] == 0} { flow_fail "impl_1 does not exist" }

set irom64_ip [get_ips -quiet IROM64]
set dram_ip [get_ips -quiet DRAM4MyOwn]
if {[llength $irom64_ip] != 1} { flow_fail "expected exactly one IROM64 IP" }
if {[llength $dram_ip] != 1} { flow_fail "expected exactly one DRAM4MyOwn IP" }

if {$dry_run} {
    puts "Dry run: project, runs, IPs, and COE files were found."
    puts "  current IROM64 COE     : [get_property CONFIG.Coe_File $irom64_ip]"
    puts "  current DRAM4MyOwn COE : [get_property CONFIG.Coe_File $dram_ip]"
    close_project
    return
}

puts ""
puts "Updating private memory initialization files"
set_property CONFIG.Load_Init_File true $irom64_ip
set_property CONFIG.Coe_File $irom64_coe $irom64_ip
set_property CONFIG.Load_Init_File true $dram_ip
set_property CONFIG.Coe_File $dram_coe $dram_ip

set memory_ips [concat $irom64_ip $dram_ip]
reset_target all $memory_ips
generate_target all $memory_ips
foreach ip_run_name {IROM64_synth_1 DRAM4MyOwn_synth_1} {
    if {[llength [get_runs -quiet $ip_run_name]] > 0} {
        catch {reset_run $ip_run_name}
    }
}

set_property STRATEGY Flow_PerfOptimized_high $synth_run
set_property STRATEGY Performance_Explore $impl_run
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE Explore $impl_run
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt $impl_run
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore $impl_run

puts ""
puts "Resetting synth_1 and impl_1"
catch {reset_run impl_1}
reset_run synth_1
update_compile_order -fileset sources_1

puts "Launching synthesis"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
require_complete_run synth_1

puts "Launching implementation through route_design"
launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
require_complete_run impl_1

set routed_dcp [routed_checkpoint impl_1]
if {$routed_dcp eq ""} {
    flow_fail "impl_1 did not produce a routed checkpoint"
}

file mkdir $output_dir
puts "Opening routed checkpoint: $routed_dcp"
open_checkpoint $routed_dcp

for {set pass_number 1} {$pass_number <= 2} {incr pass_number} {
    puts ""
    puts "Running post-route phys_opt_design pass $pass_number (Explore)"
    phys_opt_design -directive Explore
    write_pass_outputs $output_dir $pass_number
}

report_utilization -file [file join $output_dir "utilization_final.rpt"]
report_route_status -file [file join $output_dir "route_status_final.rpt"]

puts "Generating pipeline-stage timing analysis"
source $stage_timing_script

set final_setup_paths [get_timing_paths -quiet -setup -max_paths 1]
if {[llength $final_setup_paths] == 0} {
    flow_fail "cannot write bitstream because no setup timing path was found"
}
set final_setup_slack [get_property SLACK [lindex $final_setup_paths 0]]
if {$final_setup_slack < 0.0} {
    flow_fail "refusing to write a timing-failing bitstream (WNS=${final_setup_slack} ns)"
}

file mkdir [file dirname $bitstream_file]
puts "Final setup WNS: $final_setup_slack ns"
puts "Writing bitstream: $bitstream_file"
write_bitstream -force $bitstream_file

puts ""
puts "================================================================"
puts "Flow complete"
puts "Final checkpoint : [file join $output_dir postroute_physopt_pass2.dcp]"
puts "Final timing     : [file join $output_dir timing_postroute_physopt_pass2.rpt]"
puts "Stage report     : [file join $script_dir stage_timing_report.txt]"
puts "Bitstream        : $bitstream_file"
puts "================================================================"

close_project
