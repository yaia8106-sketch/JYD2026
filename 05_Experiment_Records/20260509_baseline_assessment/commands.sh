#!/usr/bin/env bash
set -euo pipefail

# Run from repo root: /home/anokyai/桌面/CPU_Workspace
EXP_DIR="05_Experiment_Records/20260509_baseline_assessment"
RAW_DIR="${EXP_DIR}/raw"
mkdir -p "${RAW_DIR}"

# Baseline official small performance set.
(
  cd 02_Design/sim/riscv_tests
  bash run_perf.sh
) 2>&1 | tee "${RAW_DIR}/run_perf_default.log"

# COE CPI/stall attribution.  This is a software-model guide, not RTL timing.
(
  cd 02_Design/sim/riscv_tests
  python3 cpi_attribution.py current src0 src1 src2 \
    --jobs 18 \
    --max-cyc 2000000 \
    --queue-max-s0 200000
) 2>&1 | tee "${RAW_DIR}/cpi_attribution_current_src0_src1_src2.log"

# Dynamic hotspot report for the contest-focused COE inputs.
(
  cd 02_Design/sim/riscv_tests
  python3 coe_hotspots.py src0 src1 src2 \
    --jobs 18 \
    --max-s0 250000 \
    --limit 12
) 2>&1 | tee "${RAW_DIR}/coe_hotspots_src0_src1_src2.log"

# Baseline Vivado timing, no bitstream.
./run_vivado_flow.sh current 18 2>&1 | tee "${RAW_DIR}/vivado_flow_current_18.log"

# Preserve the generated timing reports beside the logs.
cp 03_Timing_Analysis/stage_timing_report.txt "${RAW_DIR}/stage_timing_report.txt"
cp JYD2025_Contest-rv32i/digital_twin.runs/impl_1/top_timing_summary_routed.rpt "${RAW_DIR}/top_timing_summary_routed.rpt"
cp JYD2025_Contest-rv32i/digital_twin.runs/impl_1/top_route_status.rpt "${RAW_DIR}/top_route_status.rpt"
cp JYD2025_Contest-rv32i/digital_twin.runs/impl_1/top_utilization_placed.rpt "${RAW_DIR}/top_utilization_placed.rpt"
