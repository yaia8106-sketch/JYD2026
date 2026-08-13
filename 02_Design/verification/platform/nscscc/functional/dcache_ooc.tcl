# Post-route out-of-context check for the NSCSCC DCache configuration.
# Usage:
#   vivado -mode batch -source dcache_ooc.tcl \
#          -tclargs <output-directory> ?period-ns? ?route?

if {$argc < 1 || $argc > 3} {
    error "dcache_ooc.tcl requires output-directory and optional period-ns, route arguments"
}

set output_dir [file normalize [lindex $argv 0]]
set clock_period [expr {$argc >= 2 ? [lindex $argv 1] : 5.000}]
set run_route [expr {$argc >= 3 ? [lindex $argv 2] : 1}]
file mkdir $output_dir

set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ../../../..]]
set rtl_dir [file join $design_dir rtl]
set platform_rtl_dir [file join $design_dir platform nscscc rtl]

read_verilog -sv [file join $rtl_dir memory dcache_read_result_select.sv]
read_verilog -sv [file join $rtl_dir memory dcache_data_format.sv]
read_verilog -sv [file join $rtl_dir memory dcache.sv]
read_verilog -sv [file join $platform_rtl_dir dcache_data_ram.sv]

synth_design \
    -top dcache \
    -part xc7a200tfbg676-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

create_clock -name dcache_clk -period $clock_period [get_ports clk]

if {!$run_route} {
    report_utilization \
        -hierarchical \
        -file [file join $output_dir utilization_synth.rpt]
    report_timing_summary \
        -delay_type min_max \
        -max_paths 20 \
        -report_unconstrained \
        -warn_on_violation \
        -file [file join $output_dir timing_synth.rpt]
    puts "DCACHE_OOC_OUTPUT=$output_dir"
    return
}

opt_design
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore

report_utilization \
    -hierarchical \
    -file [file join $output_dir utilization.rpt]
report_timing_summary \
    -delay_type min_max \
    -max_paths 20 \
    -report_unconstrained \
    -warn_on_violation \
    -file [file join $output_dir timing_summary.rpt]
report_timing \
    -setup \
    -max_paths 20 \
    -path_type full_clock_expanded \
    -file [file join $output_dir timing_paths.rpt]
report_drc -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir dcache_routed.dcp]

set setup_paths [get_timing_paths -quiet -setup -max_paths 1]
if {[llength $setup_paths] > 0} {
    puts "DCACHE_OOC_WNS=[get_property SLACK [lindex $setup_paths 0]]"
}
puts "DCACHE_OOC_OUTPUT=$output_dir"
