#!/usr/bin/env bash
set -euo pipefail

EXP_DIR="05_Experiment_Records/20260509_pipeline_split_estimate"
RAW_DIR="${EXP_DIR}/raw"
mkdir -p "${RAW_DIR}"

python3 03_Timing_Analysis/pipeline_split_estimator.py \
  --timing-report 05_Experiment_Records/20260509_baseline_assessment/raw/stage_timing_report.txt \
  --baseline-cycles 3645 \
  --programs src0 src1 src2 \
  --max-insts 3000000 \
  --jobs 18 \
  2>&1 | tee "${RAW_DIR}/pipeline_split_estimator.log"
