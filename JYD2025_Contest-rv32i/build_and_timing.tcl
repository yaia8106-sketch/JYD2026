# ============================================================
# build_and_timing.tcl
#
# Compatibility wrapper.
#
# The old script targeted the previous dual-bank IROM frontend
# (IROMEven32/IROMOdd32) and is no longer the maintained build
# entry point. Use 03_Analysis/run_vivado_flow.tcl for the current
# FTQ frontend and IROM64 flow.
# ============================================================

set workspace [file normalize [file join [file dirname [info script]] ".."]]
set new_flow  "${workspace}/03_Analysis/run_vivado_flow.tcl"

if {$argc >= 1} {
    set first_arg [lindex $argv 0]
} elseif {[info exists build_mode]} {
    set first_arg $build_mode
} else {
    set first_arg "current"
}

set legacy_modes {all check synth impl timing coe}
if {$first_arg in $legacy_modes} {
    puts "ERROR: JYD2025_Contest-rv32i/build_and_timing.tcl is obsolete."
    puts "       It still belonged to the old dual-bank IROM flow."
    puts "       Current maintained entry point:"
    puts "         vivado -mode tcl -source ${new_flow} -tclargs ${workspace} <coe_name> <jobs>"
    puts ""
    puts "       Example:"
    puts "         vivado -mode tcl -source ${new_flow} -tclargs ${workspace} current 18"
    exit 1
}

if {$argc >= 1} {
    set coe_name [lindex $argv 0]
} elseif {[info exists coe_name]} {
    set coe_name $coe_name
} else {
    set coe_name "current"
}

if {$argc >= 2} {
    set build_jobs [lindex $argv 1]
} elseif {![info exists build_jobs]} {
    set build_jobs 18
}

puts "WARNING: build_and_timing.tcl is deprecated; forwarding to 03_Analysis/run_vivado_flow.tcl"
set argv [list $workspace $coe_name $build_jobs]
set argc [llength $argv]
source $new_flow
