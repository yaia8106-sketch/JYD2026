#!/bin/bash
# 使用 Vivado TCL 模式运行 tb_student_top 行为仿真
# 输出捕获到 debug 目录

VIVADO=/tools/Xilinx/Vivado/2024.1/bin/vivado
PROJECT=/home/anokyai/桌面/CPU_Workspace/JYD2025_Contest-rv32i/digital_twin.xpr
DEBUG_DIR=/home/anokyai/桌面/CPU_Workspace/02_Design/sim/debug
TB_FILE=$DEBUG_DIR/tb_student_top.sv
LOG_FILE=$DEBUG_DIR/sim_output.log

echo "=== Starting Vivado Behavioral Simulation ==="
echo "Project: $PROJECT"
echo "TB: $TB_FILE"
echo "Output: $LOG_FILE"

$VIVADO -mode tcl -nojournal -nolog -source /dev/stdin <<'TCLEOF'
# Open project
open_project {/home/anokyai/桌面/CPU_Workspace/JYD2025_Contest-rv32i/digital_twin.xpr}

# Check if tb_student_top is already in sim sources, if not add it
set tb_path {/home/anokyai/桌面/CPU_Workspace/02_Design/sim/debug/tb_student_top.sv}
set existing [get_files -quiet $tb_path]
if {$existing eq ""} {
    add_files -fileset sim_1 $tb_path
    puts "Added TB to sim_1 fileset"
} else {
    puts "TB already in project"
}

# Set the top module for simulation
set_property top tb_student_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Launch simulation
puts "Launching behavioral simulation..."
launch_simulation -mode behavioral

# Run for sufficient time
run 200us

puts "=== SIMULATION COMPLETE ==="
close_sim
close_project
exit
TCLEOF

echo "=== Done ==="
