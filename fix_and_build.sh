#!/bin/bash
# fix_and_build.sh — Fix IP COE paths + full rebuild
# Usage: ./fix_and_build.sh [src0|src1|src2|current]

COE_NAME="${1:-current}"
COE_DIR="/home/anokyai/桌面/CPU_Workspace/02_Design/coe/${COE_NAME}"
PROJECT="/home/anokyai/桌面/CPU_Workspace/JYD2025_Contest-rv32i/digital_twin.xpr"
TIMING="/home/anokyai/桌面/CPU_Workspace/03_Timing_Analysis/scripts/report_stage_timing.tcl"

# ---- XCI files (the REAL source of truth for IP config) ----
XCI_BASE="/home/anokyai/CPU_Workspace/01_Docs/2026/JYD2025_Contest-rv32i/JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/ip"
IROM_XCI="${XCI_BASE}/IROM4MyOwn/IROM4MyOwn.xci"
DRAM_XCI="${XCI_BASE}/DRAM4MyOwn/DRAM4MyOwn.xci"

if [ ! -f "${COE_DIR}/irom.coe" ]; then
    echo "ERROR: ${COE_DIR}/irom.coe not found"
    exit 1
fi

echo ">>> Building with COE set: ${COE_NAME} (${COE_DIR})"

# ---- Step 0: Patch XCI files directly on disk ----
echo ">>> Patching IROM XCI: COE → ${COE_DIR}/irom.coe"
sed -i "s|\"Coe_File\": \[ { \"value\": \"[^\"]*\"|\"Coe_File\": [ { \"value\": \"${COE_DIR}/irom.coe\"|" "$IROM_XCI"
echo ">>> Patching DRAM XCI: COE → ${COE_DIR}/dram.coe"
sed -i "s|\"Coe_File\": \[ { \"value\": \"[^\"]*\"|\"Coe_File\": [ { \"value\": \"${COE_DIR}/dram.coe\"|" "$DRAM_XCI"

# Verify
echo ">>> IROM XCI now: $(grep Coe_File "$IROM_XCI")"
echo ">>> DRAM XCI now: $(grep Coe_File "$DRAM_XCI")"

# ---- Step 0.5: Delete stale .mif so generate_target must recreate them ----
OLD_IP_BASE="/home/anokyai/CPU_Workspace/01_Docs/2026/JYD2025_Contest-rv32i/JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/ip"
GEN_IP_BASE="/home/anokyai/桌面/CPU_Workspace/JYD2025_Contest-rv32i/digital_twin.gen/sources_1/ip"
for f in \
    "${OLD_IP_BASE}/IROM4MyOwn/IROM4MyOwn.mif" \
    "${OLD_IP_BASE}/DRAM4MyOwn/DRAM4MyOwn.mif" \
    "${GEN_IP_BASE}/IROM/IROM.mif" \
    "${GEN_IP_BASE}/DRAM/DRAM.mif"; do
    if [ -f "$f" ]; then
        echo ">>> Deleting stale: $f"
        rm -f "$f"
    fi
done

vivado -mode tcl -nojournal -nolog <<EOF
open_project ${PROJECT}

# ---- Reset and regenerate IP (picks up patched XCI + forces .mif regen) ----
puts ">>> Regenerating IROM/DRAM IP..."
foreach ip {IROM4MyOwn DRAM4MyOwn} {
    set ip_run "\${ip}_synth_1"
    if {[llength [get_runs -quiet \$ip_run]] > 0} {
        reset_run \$ip_run
    }
    generate_target all [get_ips \$ip]
}

# ---- Reset synth + impl ----
puts ">>> Resetting synthesis and implementation..."
reset_run synth_1
reset_run impl_1

# ---- Run synthesis ----
puts ">>> Running synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
puts ">>> Synthesis status: [get_property STATUS [get_runs synth_1]]"

# ---- Run implementation + bitstream ----
puts ">>> Configuring implementation directives..."
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

puts ">>> Running implementation + bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts ">>> Implementation status: [get_property STATUS [get_runs impl_1]]"

# ---- Timing analysis ----
puts ">>> Running timing analysis..."
open_run impl_1
source ${TIMING}

puts "\n>>> BUILD COMPLETE (COE set: ${COE_NAME})."
close_project
exit
EOF
