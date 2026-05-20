set script_dir [file normalize [file dirname [info script]]]
set project_dir [file normalize [file join $script_dir ..]]
set workspace_dir [file normalize [file join $project_dir ..]]

set coe_set "dual_issue/current"
set jobs 8
if {[llength $argv] >= 1} {
    set coe_set [lindex $argv 0]
}
if {[llength $argv] >= 2} {
    set jobs [lindex $argv 1]
}

set python [auto_execok python3]
if {$python eq ""} {
    error "python3 not found"
}

puts [exec $python [file join $project_dir scripts prepare_mem.py] \
    --workspace $workspace_dir \
    --coe $coe_set]

set vivado_dir [file join $project_dir vivado]
file mkdir $vivado_dir

create_project -force PhysicalTwin_XC7A35T $vivado_dir -part xc7a35tftg256-2
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]

set local_rtl [list \
    [file join $project_dir rtl board_top.sv] \
    [file join $project_dir rtl seg6_hex_scan.sv] \
    [file join $project_dir rtl mmio_bridge.sv] \
    [file join $project_dir rtl IROMEven32.sv] \
    [file join $project_dir rtl IROMOdd32.sv] \
    [file join $project_dir rtl DRAM4MyOwn.sv] \
    [file join $project_dir rtl dcache_data_ram.sv] \
]

set cpu_rtl [list \
    [file join $workspace_dir 02_Design rtl cpu_defs.sv] \
    [file join $workspace_dir 02_Design rtl alu.sv] \
    [file join $workspace_dir 02_Design rtl alu_src_mux.sv] \
    [file join $workspace_dir 02_Design rtl branch_condition.sv] \
    [file join $workspace_dir 02_Design rtl branch_predictor.sv] \
    [file join $workspace_dir 02_Design rtl branch_unit.sv] \
    [file join $workspace_dir 02_Design rtl csr_trap_unit.sv] \
    [file join $workspace_dir 02_Design rtl cpu_top.sv] \
    [file join $workspace_dir 02_Design rtl dcache.sv] \
    [file join $workspace_dir 02_Design rtl decoder.sv] \
    [file join $workspace_dir 02_Design rtl dual_issue_counter.sv] \
    [file join $workspace_dir 02_Design rtl dual_issue_decider.sv] \
    [file join $workspace_dir 02_Design rtl ex_stage_ctrl.sv] \
    [file join $workspace_dir 02_Design rtl ex_mem_reg.sv] \
    [file join $workspace_dir 02_Design rtl ex_mem_reg_s1.sv] \
    [file join $workspace_dir 02_Design rtl forwarding.sv] \
    [file join $workspace_dir 02_Design rtl id_ex_reg.sv] \
    [file join $workspace_dir 02_Design rtl id_ex_reg_s1.sv] \
    [file join $workspace_dir 02_Design rtl id_stage_derive.sv] \
    [file join $workspace_dir 02_Design rtl if_id_reg.sv] \
    [file join $workspace_dir 02_Design rtl if_stage_buffer.sv] \
    [file join $workspace_dir 02_Design rtl imm_gen.sv] \
    [file join $workspace_dir 02_Design rtl irom_addr_ctrl.sv] \
    [file join $workspace_dir 02_Design rtl mem_interface.sv] \
    [file join $workspace_dir 02_Design rtl mem_wb_reg.sv] \
    [file join $workspace_dir 02_Design rtl mem_wb_reg_s1.sv] \
    [file join $workspace_dir 02_Design rtl memory_access_unit.sv] \
    [file join $workspace_dir 02_Design rtl muldiv_unit.sv] \
    [file join $workspace_dir 02_Design rtl next_pc_mux.sv] \
    [file join $workspace_dir 02_Design rtl pc_reg.sv] \
    [file join $workspace_dir 02_Design rtl redirect_ctrl.sv] \
    [file join $workspace_dir 02_Design rtl regfile.sv] \
    [file join $workspace_dir 02_Design rtl student_top.sv] \
    [file join $workspace_dir 02_Design rtl wb_mux.sv] \
]

set platform_rtl [list \
    [file join $workspace_dir 02_Design contest_readonly rtl counter.sv] \
]

add_files -norecurse [concat $local_rtl $cpu_rtl $platform_rtl]
add_files -fileset constrs_1 -norecurse [file join $project_dir constraints board.xdc]

set_property include_dirs [list \
    [file join $project_dir generated] \
    [file join $workspace_dir 02_Design rtl] \
] [current_fileset]

set_property top board_top [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

open_run impl_1
report_utilization -file [file join $project_dir vivado utilization_impl.rpt]
report_timing_summary -delay_type max -file [file join $project_dir vivado timing_summary_impl.rpt]

puts "Bitstream: [file join $vivado_dir PhysicalTwin_XC7A35T.runs impl_1 board_top.bit]"
