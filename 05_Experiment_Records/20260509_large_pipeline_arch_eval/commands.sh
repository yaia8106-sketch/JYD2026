#!/usr/bin/env bash
set -euo pipefail

EXP_DIR="05_Experiment_Records/20260509_large_pipeline_arch_eval"
RAW_DIR="${EXP_DIR}/raw"
mkdir -p "${RAW_DIR}"

python3 03_Timing_Analysis/large_pipeline_arch_estimator.py \
  --timing-report 05_Experiment_Records/20260509_baseline_assessment/raw/stage_timing_report.txt \
  --perf-log 05_Experiment_Records/20260509_baseline_assessment/raw/run_perf_default.log \
  --programs src0 src1 src2 \
  --max-insts 3000000 \
  --jobs 18 \
  2>&1 | tee "${RAW_DIR}/large_pipeline_arch_estimator.log"
