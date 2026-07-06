# Rebind imported RTL copies in the Vivado project to the canonical workspace
# sources. COE files, IP, constraints, and non-RTL project files are untouched.

set script_dir [file dirname [file normalize [info script]]]
set workspace  [file normalize [file join $script_dir ".."]]
set project_path [file join $workspace "JYD2025_Contest-rv32i" "digital_twin.xpr"]
set imported_marker "/digital_twin.srcs/sources_1/imports/02_Design/rtl/"
set canonical_root [file join $workspace "02_Design" "rtl"]

if {![file exists $project_path]} {
    error "Vivado project not found: $project_path"
}

open_project $project_path
set source_set [get_filesets sources_1]
set rebind_plan {}

foreach file_obj [get_files -of_objects $source_set] {
    set old_path [file normalize [get_property NAME $file_obj]]
    set marker_pos [string first $imported_marker $old_path]
    if {$marker_pos < 0 || [file extension $old_path] ne ".sv"} {
        continue
    }

    set relative_start [expr {$marker_pos + [string length $imported_marker]}]
    set relative_path [string range $old_path $relative_start end]
    set canonical_path [file normalize [file join $canonical_root $relative_path]]
    if {![file exists $canonical_path]} {
        error "Canonical RTL source is missing for $old_path: $canonical_path"
    }

    lappend rebind_plan [list \
        $old_path \
        $canonical_path \
        [get_property LIBRARY $file_obj] \
        [get_property FILE_TYPE $file_obj] \
        [get_property USED_IN $file_obj]]
}

if {[llength $rebind_plan] == 0} {
    puts "No imported SystemVerilog RTL files need rebinding."
    close_project
    exit 0
}

puts "Rebinding [llength $rebind_plan] SystemVerilog RTL files:"
foreach item $rebind_plan {
    lassign $item old_path canonical_path library file_type used_in
    puts "  $old_path"
    puts "    -> $canonical_path"

    remove_files [get_files $old_path]
    add_files -fileset $source_set -norecurse $canonical_path
    set new_file [get_files $canonical_path]
    set_property LIBRARY $library $new_file
    set_property FILE_TYPE $file_type $new_file
    set_property USED_IN $used_in $new_file
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Closing a Tcl-opened project persists the project edits.
close_project
puts "RTL source rebinding complete."
