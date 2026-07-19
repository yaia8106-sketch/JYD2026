# ================================================================
# run_physopt_candidate.tcl
#
# Open a routed checkpoint in a fresh Vivado process, run one physical
# optimization strategy, and emit a complete comparison artifact set.  The
# same script is used for mandatory pass 1 and the independent pass-2
# candidates so every expensive physopt stage is restartable at a DCP
# boundary.  The Bash orchestrator is responsible for isolating crashes and
# recording FAILED status when Vivado exits non-zero.  Any routing invalidated
# by physopt is completed with route_design -preserve before the candidate
# checkpoint, reports, and bitstream are generated.
# ================================================================

proc candidate_usage {} {
    puts "Usage:"
    puts "  vivado -mode batch -source 03_Timing_Analysis/run_physopt_candidate.tcl \\"
    puts "         -tclargs --input-dcp FILE --output-dir DIR --strategy NAME"
    puts "                  ?--pass-number N? ?--jobs N? ?--freq-mhz F?"
    puts "                  ?--bitstream-file FILE?"
    puts "Strategies: explore | routing_opt | aggressive_explore"
}

proc candidate_fail {message} {
    return -code error "run_physopt_candidate.tcl: $message"
}

proc require_positive_integer {option value} {
    if {![string is integer -strict $value] || $value < 1} {
        candidate_fail "$option requires a positive integer, got '$value'"
    }
}

proc require_positive_number {option value} {
    if {![string is double -strict $value] || $value <= 0.0} {
        candidate_fail "$option requires a positive number, got '$value'"
    }
}

proc worst_slack {analysis_type} {
    if {$analysis_type eq "setup"} {
        set paths [get_timing_paths -quiet -setup -max_paths 1]
    } else {
        set paths [get_timing_paths -quiet -hold -max_paths 1]
    }
    if {[llength $paths] == 0} {
        candidate_fail "no $analysis_type timing path was found"
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
        candidate_fail "$context still has [llength $unrouted_after] unrouted logical net(s) after route_design -preserve: $sample"
    }

    if {$unrouted_count > 0} {
        puts "$context routing repair completed successfully."
    }
    return $unrouted_count
}

set input_dcp_arg ""
set output_dir_arg ""
set strategy ""
set pass_number 2
set jobs 8
set frequency_mhz 200.0
set bitstream_file_arg ""

if {![info exists argv]} {
    set argv {}
}

set arg_index 0
while {$arg_index < [llength $argv]} {
    set arg [lindex $argv $arg_index]
    switch -- $arg {
        --input-dcp {
            incr arg_index
            if {$arg_index >= [llength $argv]} { candidate_fail "missing value after --input-dcp" }
            set input_dcp_arg [lindex $argv $arg_index]
        }
        --output-dir {
            incr arg_index
            if {$arg_index >= [llength $argv]} { candidate_fail "missing value after --output-dir" }
            set output_dir_arg [lindex $argv $arg_index]
        }
        --strategy {
            incr arg_index
            if {$arg_index >= [llength $argv]} { candidate_fail "missing value after --strategy" }
            set strategy [lindex $argv $arg_index]
        }
        --pass-number {
            incr arg_index
            if {$arg_index >= [llength $argv]} { candidate_fail "missing value after --pass-number" }
            set pass_number [lindex $argv $arg_index]
            require_positive_integer --pass-number $pass_number
        }
        --jobs {
            incr arg_index
            if {$arg_index >= [llength $argv]} { candidate_fail "missing value after --jobs" }
            set jobs [lindex $argv $arg_index]
            require_positive_integer --jobs $jobs
        }
        --freq-mhz {
            incr arg_index
            if {$arg_index >= [llength $argv]} { candidate_fail "missing value after --freq-mhz" }
            set frequency_mhz [lindex $argv $arg_index]
            require_positive_number --freq-mhz $frequency_mhz
        }
        --bitstream-file {
            incr arg_index
            if {$arg_index >= [llength $argv]} { candidate_fail "missing value after --bitstream-file" }
            set bitstream_file_arg [lindex $argv $arg_index]
        }
        --help - -h {
            candidate_usage
            return
        }
        default {
            candidate_usage
            candidate_fail "unknown option '$arg'"
        }
    }
    incr arg_index
}

if {$input_dcp_arg eq ""} { candidate_fail "--input-dcp is required" }
if {$output_dir_arg eq ""} { candidate_fail "--output-dir is required" }
if {$strategy ni {explore routing_opt aggressive_explore}} {
    candidate_fail "unsupported strategy '$strategy'"
}
set clock_period_ns [expr {1000.0 / double($frequency_mhz)}]

set script_dir [file normalize [file dirname [info script]]]
set stage_timing_script [file join $script_dir "report_stage_timing.tcl"]
set input_dcp [file normalize $input_dcp_arg]
set output_dir [file normalize $output_dir_arg]
if {$bitstream_file_arg ne ""} {
    set bitstream_file [file normalize $bitstream_file_arg]
} else {
    set bitstream_file [file join $output_dir "design.bit"]
}

if {![file exists $input_dcp]} { candidate_fail "input DCP not found: $input_dcp" }
if {![file exists $stage_timing_script]} {
    candidate_fail "stage timing script not found: $stage_timing_script"
}

file mkdir $output_dir
file mkdir [file dirname $bitstream_file]
set_param general.maxThreads $jobs

puts "================================================================"
puts " Post-route physical optimization pass $pass_number"
puts "================================================================"
puts "Input DCP       : $input_dcp"
puts "Strategy        : $strategy"
puts "Jobs            : $jobs"
puts "CPU clock       : $frequency_mhz MHz ($clock_period_ns ns)"
puts "Output directory: $output_dir"
puts "Bitstream       : $bitstream_file"

open_checkpoint $input_dcp

switch -- $strategy {
    explore {
        puts "Running: phys_opt_design -directive Explore"
        phys_opt_design -directive Explore
        set strategy_command "phys_opt_design -directive Explore"
    }
    routing_opt {
        puts "Running: phys_opt_design -routing_opt"
        phys_opt_design -routing_opt
        set strategy_command "phys_opt_design -routing_opt"
    }
    aggressive_explore {
        puts "Running: phys_opt_design -directive AggressiveExplore"
        phys_opt_design -directive AggressiveExplore
        set strategy_command "phys_opt_design -directive AggressiveExplore"
    }
}

set repaired_unrouted_count \
    [complete_post_physopt_routing "Pass-$pass_number $strategy physopt"]

set checkpoint_file [file join $output_dir "postroute_physopt_pass${pass_number}.dcp"]
set timing_file [file join $output_dir "timing_postroute_physopt_pass${pass_number}.rpt"]
set summary_file [file join $output_dir "final_timing_summary.txt"]

write_checkpoint -force $checkpoint_file
report_timing_summary -delay_type min_max -max_paths 100 \
    -report_unconstrained -warn_on_violation -file $timing_file
report_utilization -file [file join $output_dir "utilization_final.rpt"]
report_route_status -file [file join $output_dir "route_status_final.rpt"]
report_drc -file [file join $output_dir "drc_final.rpt"]

set STAGE_TIMING_OUTPUT_DIR $output_dir
set STAGE_TIMING_CLK_PERIOD $clock_period_ns
source $stage_timing_script

set setup_wns [worst_slack setup]
set setup_tns [total_negative_slack setup]
set hold_whs [worst_slack hold]
set hold_ths [total_negative_slack hold]
set timing_met [expr {$setup_wns >= 0.0 && $hold_whs >= 0.0}]
set timing_status [expr {$timing_met ? "MET" : "VIOLATED"}]
set programming_status [expr {$timing_met ? "SAFE_TO_PROGRAM" : "DO_NOT_PROGRAM"}]

set summary_handle [open $summary_file w]
puts $summary_handle "Pass: $pass_number"
puts $summary_handle "Final post-route pass: $pass_number"
puts $summary_handle "Strategy: $strategy"
puts $summary_handle "Strategy command: $strategy_command"
puts $summary_handle "Requested frequency (MHz): $frequency_mhz"
puts $summary_handle "Requested clock period (ns): $clock_period_ns"
puts $summary_handle "Post-physopt unrouted logical nets before repair: $repaired_unrouted_count"
puts $summary_handle "Parent checkpoint: $input_dcp"
puts $summary_handle "Setup WNS (ns): $setup_wns"
puts $summary_handle "Setup TNS (ns): $setup_tns"
puts $summary_handle "Hold WHS (ns): $hold_whs"
puts $summary_handle "Hold THS (ns): $hold_ths"
puts $summary_handle "Timing status: $timing_status"
puts $summary_handle "Hardware recommendation: $programming_status"
puts $summary_handle "Timing report: $timing_file"
puts $summary_handle "Checkpoint: $checkpoint_file"
puts $summary_handle "Bitstream: $bitstream_file"
close $summary_handle

if {!$timing_met} {
    puts "WARNING: writing a comparison bitstream with timing status $timing_status."
    puts "WARNING: this bitstream is marked $programming_status in $summary_file."
}
write_bitstream -force $bitstream_file

puts "================================================================"
puts " Pass-$pass_number candidate complete"
puts " Strategy  : $strategy"
puts " Setup WNS : $setup_wns ns"
puts " Setup TNS : $setup_tns ns"
puts " Hold WHS  : $hold_whs ns"
puts " Hold THS  : $hold_ths ns"
puts " Status    : $timing_status"
puts " Summary   : $summary_file"
puts "================================================================"

close_design
