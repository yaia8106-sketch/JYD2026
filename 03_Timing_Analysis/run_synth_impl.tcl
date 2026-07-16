# ================================================================
# run_synth_impl.tcl
#
# Run the project synthesis and timing-oriented implementation flow
# without relying on Vivado GUI strategy settings.
#
# Default flow:
#   synth_1: Flow_PerfOptimized_high
#   impl_1 : opt_design                 Explore
#            place_design               ExtraTimingOpt
#            post-place phys_opt_design AggressiveExplore
#            route_design               AggressiveExplore
#            route checkpoint opened by this script
#            post-route phys_opt_design Explore        (pass 1)
#            conditional route_design -preserve        (repair only)
#            optional iterative phys_opt_design Explore (direct use only)
#
# Batch usage:
#   vivado -mode batch \
#     -source 03_Timing_Analysis/run_synth_impl.tcl \
#     -tclargs --jobs 16 --extra-physopt 1
#
# Useful options:
#   --jobs N             Parallel jobs for project runs (default: 16)
#   --freq-mhz F         CPU clock frequency in MHz (default: 200)
#   --extra-physopt N    Extra same-process post-route Explore passes after
#                        pass 1 (default: 0). build.sh deliberately keeps this
#                        at 0 and runs pass-2 candidates in fresh processes.
#   --bitstream          Write a bitstream from the final optimized design
#   --bitstream-file F   Override the output bitstream path
#   --output-dir DIR     Store DCP/reports/bitstream metadata under DIR
#   --coe-dir DIR        Regenerate IROM64/DRAM4MyOwn from DIR/irom64.coe
#                        and DIR/dram.coe before a clean build
#   --no-reset           Reuse completed synthesis/routing results when possible
#   --dry-run            Open the project and print the intended flow only
#   --help               Print usage
#
# Outputs for a direct invocation (build.sh uses a timestamped pass-1 dir):
#   <output-dir>/
#     postroute_physopt_pass1.dcp
#     timing_postroute_physopt_pass1.rpt
#     postroute_physopt_pass2.dcp        (only with --extra-physopt >= 1)
#     timing_postroute_physopt_pass2.rpt
#     final_timing_summary.txt
#     utilization_final.rpt
#     top_physopt_passN.bit              (only with --bitstream)
#
# The existing report_stage_timing.tcl is sourced on the final design and
# writes stage_timing_report.txt under the selected output directory.
# ================================================================

proc flow_usage {} {
    puts "Usage:"
    puts "  vivado -mode batch -source 03_Timing_Analysis/run_synth_impl.tcl \\"
    puts "         -tclargs ?--jobs N? ?--freq-mhz F? ?--extra-physopt N?"
    puts "                  ?--bitstream?"
    puts "                  ?--bitstream-file FILE? ?--output-dir DIR?"
    puts "                  ?--coe-dir DIR?"
    puts "                  ?--no-reset? ?--dry-run?"
}

proc flow_fail {message} {
    return -code error "run_synth_impl.tcl: $message"
}

proc require_nonnegative_integer {option value} {
    if {![string is integer -strict $value] || $value < 0} {
        flow_fail "$option requires a non-negative integer, got '$value'"
    }
}

proc require_positive_integer {option value} {
    if {![string is integer -strict $value] || $value < 1} {
        flow_fail "$option requires a positive integer, got '$value'"
    }
}

proc require_positive_number {option value} {
    if {![string is double -strict $value] || $value <= 0.0} {
        flow_fail "$option requires a positive number, got '$value'"
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

proc require_routed_run {run_name} {
    set status [run_status $run_name]
    set progress [get_property PROGRESS [get_runs $run_name]]
    set checkpoint [routed_checkpoint $run_name]
    puts "  $run_name status: $status ($progress)"
    if {$checkpoint eq ""} {
        flow_fail "run '$run_name' did not produce a routed checkpoint"
    }
    puts "  routed checkpoint: $checkpoint"
}

proc complete_post_physopt_routing {context} {
    set unrouted_before [get_nets -quiet -hierarchical \
        -filter {ROUTE_STATUS == UNROUTED}]
    set unrouted_count [llength $unrouted_before]

    if {$unrouted_count > 0} {
        puts "WARNING: $context left $unrouted_count unrouted logical net(s)."
        puts "Running route_design -preserve to complete post-physopt routing."
        route_design -preserve
    } else {
        puts "$context routing check: fully routed; no repair required."
    }

    set unrouted_after [get_nets -quiet -hierarchical \
        -filter {ROUTE_STATUS == UNROUTED}]
    if {[llength $unrouted_after] > 0} {
        set sample [join [lrange $unrouted_after 0 7] ", "]
        flow_fail "$context still has [llength $unrouted_after] unrouted logical net(s) after route_design -preserve: $sample"
    }

    if {$unrouted_count > 0} {
        puts "$context routing repair completed successfully."
    }
    return $unrouted_count
}

proc report_and_checkpoint {output_dir pass_number} {
    set stem "postroute_physopt_pass${pass_number}"
    set checkpoint_file [file join $output_dir "${stem}.dcp"]
    set timing_file [file join $output_dir "timing_${stem}.rpt"]

    puts ""
    puts "Writing pass $pass_number checkpoint and timing report"
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

proc worst_slack {analysis_type} {
    if {$analysis_type eq "setup"} {
        set paths [get_timing_paths -quiet -setup -max_paths 1]
    } else {
        set paths [get_timing_paths -quiet -hold -max_paths 1]
    }
    if {[llength $paths] == 0} {
        flow_fail "no $analysis_type timing path was found"
    }
    return [get_property SLACK [lindex $paths 0]]
}

proc total_negative_slack {analysis_type} {
    if {$analysis_type eq "setup"} {
        set paths [get_timing_paths -quiet -setup -slack_lesser_than 0.0 \
            -max_paths 100000 -nworst 1]
    } else {
        set paths [get_timing_paths -quiet -hold -slack_lesser_than 0.0 \
            -max_paths 100000 -nworst 1]
    }
    set total 0.0
    foreach path $paths {
        set total [expr {$total + [get_property SLACK $path]}]
    }
    return $total
}

# ---- Command-line options -------------------------------------------------

set jobs 16
set frequency_mhz 200.0
set extra_physopt_passes 0
set write_bitstream_enabled 0
set bitstream_file_arg ""
set output_dir_arg ""
set coe_dir_arg ""
set reset_runs_enabled 1
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
        --freq-mhz {
            incr arg_index
            if {$arg_index >= [llength $argv]} { flow_fail "missing value after --freq-mhz" }
            set frequency_mhz [lindex $argv $arg_index]
            require_positive_number --freq-mhz $frequency_mhz
        }
        --extra-physopt {
            incr arg_index
            if {$arg_index >= [llength $argv]} { flow_fail "missing value after --extra-physopt" }
            set extra_physopt_passes [lindex $argv $arg_index]
            require_nonnegative_integer --extra-physopt $extra_physopt_passes
        }
        --bitstream {
            set write_bitstream_enabled 1
        }
        --bitstream-file {
            incr arg_index
            if {$arg_index >= [llength $argv]} { flow_fail "missing value after --bitstream-file" }
            set bitstream_file_arg [lindex $argv $arg_index]
            set write_bitstream_enabled 1
        }
        --output-dir {
            incr arg_index
            if {$arg_index >= [llength $argv]} { flow_fail "missing value after --output-dir" }
            set output_dir_arg [lindex $argv $arg_index]
        }
        --coe-dir {
            incr arg_index
            if {$arg_index >= [llength $argv]} { flow_fail "missing value after --coe-dir" }
            set coe_dir_arg [lindex $argv $arg_index]
        }
        --no-reset {
            set reset_runs_enabled 0
        }
        --dry-run {
            set dry_run 1
        }
        --help - -h {
            flow_usage
            return
        }
        default {
            flow_usage
            flow_fail "unknown option '$arg'"
        }
    }
    incr arg_index
}

set clock_period_ns [expr {1000.0 / double($frequency_mhz)}]

# ---- Project paths --------------------------------------------------------

set script_dir [file normalize [file dirname [info script]]]
set workspace [file normalize [file join $script_dir ".."]]
set project_path [file join $workspace "JYD2025_Contest-rv32i" "digital_twin.xpr"]
set stage_timing_script [file join $script_dir "report_stage_timing.tcl"]

if {$output_dir_arg ne ""} {
    if {[file pathtype $output_dir_arg] eq "absolute"} {
        set output_dir [file normalize $output_dir_arg]
    } else {
        set output_dir [file normalize [file join $workspace $output_dir_arg]]
    }
} else {
    set output_dir [file join $script_dir "results"]
}

set coe_dir ""
set irom64_coe ""
set dram_coe ""
if {$coe_dir_arg ne ""} {
    if {[file pathtype $coe_dir_arg] eq "absolute"} {
        set coe_dir [file normalize $coe_dir_arg]
    } elseif {[file isdirectory [file join $workspace $coe_dir_arg]]} {
        set coe_dir [file normalize [file join $workspace $coe_dir_arg]]
    } else {
        set coe_dir [file normalize [file join $workspace "02_Design" "coe" "irom64" $coe_dir_arg]]
    }
    set irom64_coe [file join $coe_dir "irom64.coe"]
    set dram_coe [file join $coe_dir "dram.coe"]
    if {![file isdirectory $coe_dir]} { flow_fail "COE directory not found: $coe_dir" }
    if {![file exists $irom64_coe]} { flow_fail "IROM64 COE not found: $irom64_coe" }
    if {![file exists $dram_coe]} { flow_fail "DRAM COE not found: $dram_coe" }
    if {!$reset_runs_enabled} {
        flow_fail "--coe-dir cannot be combined with --no-reset; COE changes require a clean build"
    }
}

if {$bitstream_file_arg ne ""} {
    if {[file pathtype $bitstream_file_arg] eq "absolute"} {
        set requested_bitstream_file [file normalize $bitstream_file_arg]
    } else {
        set requested_bitstream_file [file normalize [file join $workspace $bitstream_file_arg]]
    }
} else {
    set requested_bitstream_file ""
}

if {![file exists $project_path]} {
    flow_fail "project not found: $project_path"
}
if {![file exists $stage_timing_script]} {
    flow_fail "stage timing script not found: $stage_timing_script"
}

puts "================================================================"
puts " CPU synthesis and timing-oriented implementation"
puts "================================================================"
puts "Project              : $project_path"
puts "Jobs                 : $jobs"
puts "CPU clock            : $frequency_mhz MHz ($clock_period_ns ns)"
puts "Reset synth/impl     : $reset_runs_enabled"
puts "Post-route physopt   : Explore (pass 1)"
puts "Extra physopt passes : $extra_physopt_passes"
puts "Write bitstream      : $write_bitstream_enabled"
if {$requested_bitstream_file ne ""} {
    puts "Bitstream file       : $requested_bitstream_file"
}
if {$coe_dir ne ""} {
    puts "COE directory        : $coe_dir"
    puts "  IROM64              : $irom64_coe"
    puts "  DRAM                : $dram_coe"
}
puts "Output directory     : $output_dir"

# If sourced from an already-open GUI project, close it first so that the
# project is reopened from the canonical workspace path.
set open_project_obj [current_project -quiet]
if {$open_project_obj ne ""} {
    puts "Closing currently open project: $open_project_obj"
    close_project
}
open_project $project_path

set synth_run [get_runs -quiet synth_1]
set impl_run [get_runs -quiet impl_1]
if {[llength $synth_run] == 0} { flow_fail "synth_1 does not exist" }
if {[llength $impl_run] == 0} { flow_fail "impl_1 does not exist" }

set pll_ip [get_ips -quiet pll]
if {[llength $pll_ip] != 1} {
    flow_fail "expected exactly one pll Clocking Wizard IP"
}
set current_pll_frequency \
    [get_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $pll_ip]
if {$current_pll_frequency eq "" || \
    ![string is double -strict $current_pll_frequency]} {
    flow_fail "pll has no numeric CONFIG.CLKOUT2_REQUESTED_OUT_FREQ"
}
set frequency_change_required [expr {
    abs(double($current_pll_frequency) - double($frequency_mhz)) > 0.0005
}]

if {$dry_run} {
    puts ""
    puts "Dry run: no project settings or run results were changed."
    puts "PLL clk_out2 current  : $current_pll_frequency MHz"
    puts "PLL clk_out2 requested: $frequency_mhz MHz"
    puts "PLL regeneration      : [expr {$frequency_change_required ? "required" : "not required"}]"
    if {$coe_dir ne ""} {
        set dry_irom64_ip [get_ips -quiet IROM64]
        set dry_dram_ip [get_ips -quiet DRAM4MyOwn]
        if {[llength $dry_irom64_ip] != 1} { flow_fail "expected exactly one IROM64 IP" }
        if {[llength $dry_dram_ip] != 1} { flow_fail "expected exactly one DRAM4MyOwn IP" }
        puts "COE target IPs found: IROM64, DRAM4MyOwn"
        puts "  current IROM64 COE     : [get_property CONFIG.Coe_File $dry_irom64_ip]"
        puts "  current DRAM4MyOwn COE : [get_property CONFIG.Coe_File $dry_dram_ip]"
    }
    puts "Current synth strategy: [get_property STRATEGY $synth_run]"
    puts "Current impl strategy : [get_property STRATEGY $impl_run]"
    foreach property_name {
        STEPS.OPT_DESIGN.ARGS.DIRECTIVE
        STEPS.PLACE_DESIGN.ARGS.DIRECTIVE
        STEPS.PHYS_OPT_DESIGN.IS_ENABLED
        STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE
        STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE
        STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED
        STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE
    } {
        if {[catch {set property_value [get_property $property_name $impl_run]} property_error]} {
            flow_fail "unsupported impl_1 property '$property_name': $property_error"
        }
        puts "  $property_name = $property_value"
    }
    if {!$reset_runs_enabled} {
        set existing_checkpoint [routed_checkpoint impl_1]
        if {$existing_checkpoint eq ""} {
            flow_fail "resume check failed: no routed checkpoint exists"
        }
        puts "Resume checkpoint check: $existing_checkpoint"
        open_checkpoint $existing_checkpoint
        puts "Resume checkpoint design: [current_design]"
        close_design
    }
    close_project
    return
}

if {!$reset_runs_enabled && $frequency_change_required} {
    flow_fail "--freq-mhz cannot change pll frequency with --no-reset; a clean build is required"
}

puts ""
puts "Configuring CPU clock"
if {$frequency_change_required} {
    puts "  pll clk_out2: $current_pll_frequency MHz -> $frequency_mhz MHz"
    set_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $frequency_mhz $pll_ip
    reset_target all $pll_ip
    generate_target all $pll_ip
    if {[llength [get_runs -quiet pll_synth_1]] > 0} {
        catch {reset_run pll_synth_1}
    }
    puts "  regenerated pll output products"
} else {
    puts "  pll clk_out2 already requests $frequency_mhz MHz"
}

# Update only the two private memories used by Core_cpu. The template IROM and
# DRAM IP remain untouched. Resetting their generated products prevents a
# stale OOC checkpoint from silently retaining the previous program image.
if {$coe_dir ne ""} {
    set irom64_ip [get_ips -quiet IROM64]
    set dram_ip [get_ips -quiet DRAM4MyOwn]
    if {[llength $irom64_ip] != 1} { flow_fail "expected exactly one IROM64 IP" }
    if {[llength $dram_ip] != 1} { flow_fail "expected exactly one DRAM4MyOwn IP" }

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
    puts "  IROM64 CONFIG.Coe_File     = [get_property CONFIG.Coe_File $irom64_ip]"
    puts "  DRAM4MyOwn CONFIG.Coe_File = [get_property CONFIG.Coe_File $dram_ip]"
}

# ---- Explicit strategy configuration -------------------------------------

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
puts "Configured strategies:"
puts "  synth_1: [get_property STRATEGY $synth_run]"
puts "  impl_1 : [get_property STRATEGY $impl_run]"
puts "  opt     : [get_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE $impl_run]"
puts "  place   : [get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $impl_run]"
puts "  physopt : [get_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE $impl_run]"
puts "  route   : [get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $impl_run]"
puts "  postroute physopt: [get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE $impl_run]"

# ---- Synthesis and implementation ----------------------------------------

if {$reset_runs_enabled} {
    puts ""
    puts "Resetting impl_1 and synth_1"
    catch {reset_run impl_1}
    reset_run synth_1
}

update_compile_order -fileset sources_1

puts ""
puts "Launching synthesis"
set synth_status [run_status synth_1]
if {!$reset_runs_enabled && [regexp -nocase {synth_design Complete} $synth_status]} {
    puts "  Reusing completed synth_1"
} else {
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
}
require_complete_run synth_1

puts ""
puts "Launching implementation through route_design"
set existing_routed_checkpoint [routed_checkpoint impl_1]
if {!$reset_runs_enabled && $existing_routed_checkpoint ne ""} {
    puts "  Reusing completed route_design"
} else {
    launch_runs impl_1 -to_step route_design -jobs $jobs
    wait_on_run impl_1
}
require_routed_run impl_1

file mkdir $output_dir
set final_routed_checkpoint [routed_checkpoint impl_1]
puts "Opening routed checkpoint directly: $final_routed_checkpoint"
open_checkpoint $final_routed_checkpoint

# Run pass 1 explicitly after routing. Additional passes operate iteratively on
# the result of the previous pass. This avoids Vivado-version-dependent names
# for the optional project-run post-route physopt step.
set total_physopt_passes [expr {$extra_physopt_passes + 1}]
set repaired_unrouted_count 0
for {set pass_number 1} {$pass_number <= $total_physopt_passes} {incr pass_number} {
    puts ""
    puts "Running post-route phys_opt_design pass $pass_number (Explore)"
    phys_opt_design -directive Explore
    set repaired_unrouted_count \
        [complete_post_physopt_routing "Post-route physopt pass $pass_number"]
    report_and_checkpoint $output_dir $pass_number
}

set final_pass_number $total_physopt_passes
report_utilization -file [file join $output_dir "utilization_final.rpt"]
report_route_status -file [file join $output_dir "route_status_final.rpt"]
report_drc -file [file join $output_dir "drc_final.rpt"]

puts ""
puts "Generating pipeline-stage timing analysis from final pass"
set STAGE_TIMING_OUTPUT_DIR $output_dir
set STAGE_TIMING_CLK_PERIOD $clock_period_ns
source $stage_timing_script

set final_setup_slack [worst_slack setup]
set final_setup_tns [total_negative_slack setup]
set final_hold_slack [worst_slack hold]
set final_hold_ths [total_negative_slack hold]
set final_timing_met [expr {$final_setup_slack >= 0.0 && $final_hold_slack >= 0.0}]
set final_timing_status [expr {$final_timing_met ? "MET" : "VIOLATED"}]
set programming_status [expr {$final_timing_met ? "SAFE_TO_PROGRAM" : "DO_NOT_PROGRAM"}]
set final_timing_report [file join $output_dir "timing_postroute_physopt_pass${final_pass_number}.rpt"]
set final_timing_summary_file [file join $output_dir "final_timing_summary.txt"]

set summary_handle [open $final_timing_summary_file w]
puts $summary_handle "Pass: $final_pass_number"
puts $summary_handle "Final post-route pass: $final_pass_number"
puts $summary_handle "Strategy: explore"
puts $summary_handle "Strategy command: phys_opt_design -directive Explore"
puts $summary_handle "Requested frequency (MHz): $frequency_mhz"
puts $summary_handle "Requested clock period (ns): $clock_period_ns"
puts $summary_handle "Post-physopt unrouted logical nets before repair: $repaired_unrouted_count"
puts $summary_handle "Setup WNS (ns): $final_setup_slack"
puts $summary_handle "Setup TNS (ns): $final_setup_tns"
puts $summary_handle "Hold WHS (ns): $final_hold_slack"
puts $summary_handle "Hold THS (ns): $final_hold_ths"
puts $summary_handle "Timing status: $final_timing_status"
puts $summary_handle "Hardware recommendation: $programming_status"
puts $summary_handle "Timing report: $final_timing_report"
puts $summary_handle "Checkpoint: [file join $output_dir postroute_physopt_pass${final_pass_number}.dcp]"
close $summary_handle

puts ""
puts "================================================================"
puts " FINAL TIMING SUMMARY"
puts " Setup WNS : $final_setup_slack ns"
puts " Setup TNS : $final_setup_tns ns"
puts " Hold WHS  : $final_hold_slack ns"
puts " Hold THS  : $final_hold_ths ns"
puts " Status    : $final_timing_status"
puts " Report    : $final_timing_report"
puts " Summary   : $final_timing_summary_file"
puts "================================================================"

if {$write_bitstream_enabled} {
    if {$requested_bitstream_file ne ""} {
        set bitstream_file $requested_bitstream_file
    } else {
        set bitstream_file [file join $output_dir "top_physopt_pass${final_pass_number}.bit"]
    }
    file mkdir [file dirname $bitstream_file]
    if {!$final_timing_met} {
        puts "WARNING: writing a comparison bitstream with timing status $final_timing_status."
        puts "WARNING: this bitstream is marked $programming_status in $final_timing_summary_file."
    }
    puts ""
    puts "Writing bitstream: $bitstream_file"
    write_bitstream -force $bitstream_file

    set summary_handle [open $final_timing_summary_file a]
    puts $summary_handle "Bitstream: $bitstream_file"
    close $summary_handle
}

puts ""
puts "================================================================"
puts " Flow complete"
puts " Setup WNS       : $final_setup_slack ns ($final_timing_status)"
puts " Final checkpoint: [file join $output_dir postroute_physopt_pass${final_pass_number}.dcp]"
puts " Final timing rpt : $final_timing_report"
puts " Timing summary  : $final_timing_summary_file"
puts " Stage timing rpt : [file join $output_dir stage_timing_report.txt]"
if {$write_bitstream_enabled} {
    puts " Bitstream        : $bitstream_file"
}
puts "================================================================"

close_project
