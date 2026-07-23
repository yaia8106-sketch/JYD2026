#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE_ROOT="/home/anokyai/Desktop/CPU_Workspace"
readonly MODEL_SOURCE="${WORKSPACE_ROOT}/02_Design/model/cpp_arch_explorer"
readonly COE_ROOT="${WORKSPACE_ROOT}/02_Design/verification/riscv/coe/single_issue"

readonly RUN_MODE="${1:-full}"
case "${RUN_MODE}" in
    full)
        default_output_dir="/tmp/backend_iq_round3_low_depth"
        default_programs="current,src0,src1,src2,new_without_Mext,new_with_Mext"
        default_max_instructions=0
        default_progress=100000000
        ;;
    smoke)
        default_output_dir="/tmp/backend_iq_round3_low_depth_smoke"
        default_programs="current"
        default_max_instructions=100000
        default_progress=0
        ;;
    *)
        echo "Usage: $0 [full|smoke]" >&2
        exit 2
        ;;
esac

readonly BUILD_DIR="${BACKEND_IQ_BUILD_DIR:-/tmp/cpp_arch_explorer_build}"
readonly OUTPUT_DIR="${BACKEND_IQ_OUTPUT_DIR:-${default_output_dir}}"
readonly PROGRAMS="${BACKEND_IQ_PROGRAMS:-${default_programs}}"
readonly MAX_INSTRUCTIONS="${BACKEND_IQ_MAX_INSTRUCTIONS:-${default_max_instructions}}"
readonly PROGRESS="${BACKEND_IQ_PROGRESS:-${default_progress}}"
readonly JOBS="${BACKEND_IQ_JOBS:-6}"
readonly BUILD_JOBS="${BACKEND_IQ_BUILD_JOBS:-16}"

# The default 3 x 3 x 2 grid contains 18 low-cost configurations.  The
# environment overrides make it possible to add a depth without editing this
# script, for example BACKEND_IQ_INT_DEPTHS=4,6,8,12.
readonly INT_DEPTHS="${BACKEND_IQ_INT_DEPTHS:-4,6,8}"
readonly LS_DEPTHS="${BACKEND_IQ_LS_DEPTHS:-2,4,6}"
readonly MDU_DEPTHS="${BACKEND_IQ_MDU_DEPTHS:-1,2}"

cmake \
    -S "${MODEL_SOURCE}" \
    -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release

cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" \
    --target backend_iq_study backend_model_tests

"${BUILD_DIR}/backend_model_tests"

study_args=(
    --coe-root "${COE_ROOT}"
    --output-dir "${OUTPUT_DIR}"
    --programs "${PROGRAMS}"
    --int-depths "${INT_DEPTHS}"
    --ls-depths "${LS_DEPTHS}"
    --mdu-depths "${MDU_DEPTHS}"
    --branch-mode gshare
    --progress "${PROGRESS}"
    --jobs "${JOBS}"
)

if (( MAX_INSTRUCTIONS > 0 )); then
    study_args+=(--max-instructions "${MAX_INSTRUCTIONS}")
fi

"${BUILD_DIR}/backend_iq_study" "${study_args[@]}"

echo "Per-program results: ${OUTPUT_DIR}/backend_per_program.csv"
echo "Aggregate results:   ${OUTPUT_DIR}/backend_aggregate.csv"
