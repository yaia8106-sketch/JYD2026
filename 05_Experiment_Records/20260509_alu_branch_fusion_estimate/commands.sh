#!/usr/bin/env bash
set -euo pipefail

EXP_DIR="05_Experiment_Records/20260509_alu_branch_fusion_estimate"
RAW_DIR="${EXP_DIR}/raw"
mkdir -p "${RAW_DIR}"

(
  cd 02_Design/sim/riscv_tests
  python3 alu_branch_fusion_estimator.py src0 src1 src2 \
    --jobs 18 \
    --max-insts 3000000 \
    --limit 12
) 2>&1 | tee "${RAW_DIR}/alu_branch_fusion_estimator.log"
