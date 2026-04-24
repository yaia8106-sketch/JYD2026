#!/bin/bash
VIVADO=/tools/Xilinx/Vivado/2024.1/bin/vivado
PROJECT=/home/anokyai/桌面/CPU_Workspace/JYD2025_Contest-rv32i/digital_twin.xpr
$VIVADO -mode batch -source /dev/stdin <<'TCLEOF'
open_project {/home/anokyai/桌面/CPU_Workspace/JYD2025_Contest-rv32i/digital_twin.xpr}
set_property top tb_student_top [get_filesets sim_1]
launch_simulation -mode behavioral
run 200us
close_sim
close_project
exit
TCLEOF
