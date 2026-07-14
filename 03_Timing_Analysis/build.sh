#!/usr/bin/env bash
# ================================================================
# Three-candidate timing flow:
#   1. Clean synthesis + route + mandatory pass-1 Explore.
#   2. Independent pass-2 routing_opt candidate from pass 1.
#   3. Independent pass-2 AggressiveExplore candidate from pass 1.
#
# Each physopt stage runs in its own Vivado process.  A pass-2 crash is
# recorded as a failed candidate and does not invalidate pass 1 or prevent
# the other pass-2 candidate from running.
#
# Usage:
#   ./03_Timing_Analysis/build.sh <parallel jobs> <COE configuration>
# Example:
#   ./03_Timing_Analysis/build.sh 16 withM
#
# Memory admission defaults (MiB):
#   VIVADO_MEM_BASE_MIB=4096
#   VIVADO_MEM_PER_JOB_MIB=768
#   VIVADO_MEM_RESERVE_MIB=2048
#
# COE configuration:
#   current | src0 | src1 | src2 | withM | withoutM
# ================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT}/03_Timing_Analysis"
PASS1_TCL="${SCRIPT_DIR}/run_synth_impl.tcl"
PASS2_TCL="${SCRIPT_DIR}/run_physopt_candidate.tcl"

usage() {
    printf '%s\n' \
        'Usage:' \
        '  ./03_Timing_Analysis/build.sh <parallel jobs> <COE configuration>' \
        '' \
        'Example:' \
        '  ./03_Timing_Analysis/build.sh 16 withM' \
        '' \
        'COE configuration:' \
        '  current | src0 | src1 | src2 | withM | withoutM' \
        '' \
        'Memory admission check:' \
        '  required = 4096 MiB + jobs * 768 MiB + 2048 MiB system reserve' \
        '  Override the three terms with VIVADO_MEM_BASE_MIB,' \
        '  VIVADO_MEM_PER_JOB_MIB, and VIVADO_MEM_RESERVE_MIB.' \
        '  Swap is reported but is not counted as safe Vivado capacity.' \
        '' \
        'Flow:' \
        '  pass1_explore -> {pass2_routing_opt, pass2_aggressive_explore}'
}

require_nonnegative_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: ${name} must be a non-negative integer, got '${value}'." >&2
        exit 2
    fi
}

require_positive_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: ${name} must be a positive integer, got '${value}'." >&2
        exit 2
    fi
}

detect_available_memory() {
    local mem_available_kib swap_free_kib
    local cgroup_max cgroup_current cgroup_headroom_mib

    if [[ ! -r /proc/meminfo ]]; then
        echo "ERROR: cannot read /proc/meminfo; refusing to start Vivado without a memory check." >&2
        return 1
    fi

    mem_available_kib="$(awk '$1 == "MemAvailable:" {print $2; exit}' /proc/meminfo)"
    swap_free_kib="$(awk '$1 == "SwapFree:" {print $2; exit}' /proc/meminfo)"
    if [[ ! "${mem_available_kib}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: MemAvailable is missing from /proc/meminfo; refusing to start Vivado." >&2
        return 1
    fi

    MEMORY_AVAILABLE_MIB=$((mem_available_kib / 1024))
    MEMORY_SWAP_FREE_MIB=0
    if [[ "${swap_free_kib}" =~ ^[0-9]+$ ]]; then
        MEMORY_SWAP_FREE_MIB=$((swap_free_kib / 1024))
    fi
    MEMORY_LIMIT_SOURCE="/proc/meminfo MemAvailable"

    # In a cgroup, the host's MemAvailable can exceed this process's actual
    # allowance. Use the smaller headroom so containers also fail safely.
    if [[ -r /sys/fs/cgroup/memory.max \
          && -r /sys/fs/cgroup/memory.current ]]; then
        cgroup_max="$(</sys/fs/cgroup/memory.max)"
        cgroup_current="$(</sys/fs/cgroup/memory.current)"
        if [[ "${cgroup_max}" =~ ^[0-9]+$ \
              && "${cgroup_current}" =~ ^[0-9]+$ ]]; then
            if (( cgroup_max > cgroup_current )); then
                cgroup_headroom_mib=$(((cgroup_max - cgroup_current) / 1048576))
            else
                cgroup_headroom_mib=0
            fi
            if (( cgroup_headroom_mib < MEMORY_AVAILABLE_MIB )); then
                MEMORY_AVAILABLE_MIB="${cgroup_headroom_mib}"
                MEMORY_LIMIT_SOURCE="cgroup v2 remaining allowance"
            fi
        fi
    elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes \
            && -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
        cgroup_max="$(</sys/fs/cgroup/memory/memory.limit_in_bytes)"
        cgroup_current="$(</sys/fs/cgroup/memory/memory.usage_in_bytes)"
        if [[ "${cgroup_max}" =~ ^[0-9]+$ \
              && "${cgroup_current}" =~ ^[0-9]+$ \
              && ${#cgroup_max} -lt 19 ]]; then
            if (( cgroup_max > cgroup_current )); then
                cgroup_headroom_mib=$(((cgroup_max - cgroup_current) / 1048576))
            else
                cgroup_headroom_mib=0
            fi
            if (( cgroup_headroom_mib < MEMORY_AVAILABLE_MIB )); then
                MEMORY_AVAILABLE_MIB="${cgroup_headroom_mib}"
                MEMORY_LIMIT_SOURCE="cgroup v1 remaining allowance"
            fi
        fi
    fi
}

check_memory_admission() {
    if ! detect_available_memory; then
        return 1
    fi

    MEMORY_VIVADO_ESTIMATE_MIB=$((MEMORY_BASE_MIB
                                  + JOBS * MEMORY_PER_JOB_MIB))
    MEMORY_REQUIRED_MIB=$((MEMORY_VIVADO_ESTIMATE_MIB
                           + MEMORY_RESERVE_MIB))
    MEMORY_MAX_SAFE_JOBS=0
    if (( MEMORY_AVAILABLE_MIB > MEMORY_BASE_MIB + MEMORY_RESERVE_MIB )); then
        MEMORY_MAX_SAFE_JOBS=$(((MEMORY_AVAILABLE_MIB
                                - MEMORY_BASE_MIB
                                - MEMORY_RESERVE_MIB)
                               / MEMORY_PER_JOB_MIB))
    fi

    echo "================================================================"
    echo " Vivado memory admission check"
    echo "================================================================"
    printf 'Detected available RAM : %s MiB (%s)\n' \
        "${MEMORY_AVAILABLE_MIB}" "${MEMORY_LIMIT_SOURCE}"
    printf 'Estimated Vivado RAM  : %s MiB = %s + %s jobs * %s\n' \
        "${MEMORY_VIVADO_ESTIMATE_MIB}" "${MEMORY_BASE_MIB}" \
        "${JOBS}" "${MEMORY_PER_JOB_MIB}"
    printf 'System reserve        : %s MiB\n' "${MEMORY_RESERVE_MIB}"
    printf 'Required available RAM: %s MiB\n' "${MEMORY_REQUIRED_MIB}"
    printf 'Free swap (not counted): %s MiB\n' "${MEMORY_SWAP_FREE_MIB}"

    if (( MEMORY_AVAILABLE_MIB < MEMORY_REQUIRED_MIB )); then
        echo "Memory check          : FAILED" >&2
        if (( MEMORY_MAX_SAFE_JOBS > 0 )); then
            printf 'ERROR: %s jobs are unsafe with current free RAM; retry with at most %s jobs or free more RAM.\n' \
                "${JOBS}" "${MEMORY_MAX_SAFE_JOBS}" >&2
        else
            echo "ERROR: current free RAM is insufficient even for one Vivado job; free memory first." >&2
        fi
        echo "Vivado has not been started and no result directory has been changed." >&2
        return 1
    fi

    echo "Memory check          : PASSED"
    printf 'Current safe job limit: %s\n' "${MEMORY_MAX_SAFE_JOBS}"
    echo "================================================================"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 2 ]]; then
    usage >&2
    exit 2
fi

JOBS="$1"
COE_NAME="$2"

require_positive_integer "parallel jobs" "${JOBS}"

# Existing withM logs peak near 4 GiB for this design. Add conservative
# per-job headroom and preserve enough physical RAM for Linux/the desktop.
# Swap is intentionally excluded so a check cannot pass by accepting a
# machine-freezing amount of paging.
MEMORY_BASE_MIB="${VIVADO_MEM_BASE_MIB:-4096}"
MEMORY_PER_JOB_MIB="${VIVADO_MEM_PER_JOB_MIB:-768}"
MEMORY_RESERVE_MIB="${VIVADO_MEM_RESERVE_MIB:-2048}"
require_nonnegative_integer "VIVADO_MEM_BASE_MIB" "${MEMORY_BASE_MIB}"
require_positive_integer "VIVADO_MEM_PER_JOB_MIB" "${MEMORY_PER_JOB_MIB}"
require_nonnegative_integer "VIVADO_MEM_RESERVE_MIB" "${MEMORY_RESERVE_MIB}"

case "${COE_NAME}" in
    current|src0|src1|src2)
        COE_SOURCE_NAME="${COE_NAME}"
        ;;
    withM)
        COE_SOURCE_NAME="new_with_Mext"
        ;;
    withoutM)
        COE_SOURCE_NAME="new_without_Mext"
        ;;
    *)
        echo "ERROR: unknown COE configuration '${COE_NAME}'." >&2
        echo "Valid configurations: current | src0 | src1 | src2 | withM | withoutM" >&2
        exit 2
        ;;
esac

COE_DIR="${ROOT}/02_Design/coe/irom64/${COE_SOURCE_NAME}"
if [[ ! -f "${COE_DIR}/irom64.coe" || ! -f "${COE_DIR}/dram.coe" ]]; then
    echo "ERROR: ${COE_DIR} must contain irom64.coe and dram.coe." >&2
    exit 2
fi
if [[ ! -f "${PASS1_TCL}" || ! -f "${PASS2_TCL}" ]]; then
    echo "ERROR: timing-flow Tcl scripts are incomplete under ${SCRIPT_DIR}." >&2
    exit 2
fi

# This gate deliberately runs before sourcing Vivado and before creating or
# replacing any result paths. An unsafe invocation therefore has no build-side
# effects beyond its diagnostic output.
if ! check_memory_admission; then
    exit 3
fi

if ! command -v vivado >/dev/null 2>&1; then
    if [[ -f /tools/Xilinx/Vivado/2024.1/settings64.sh ]]; then
        # shellcheck disable=SC1091
        source /tools/Xilinx/Vivado/2024.1/settings64.sh
    fi
fi
if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: Vivado was not found. Source the Vivado settings script first." >&2
    exit 127
fi

RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
RESULT_ROOT="${SCRIPT_DIR}/results/${COE_NAME}"
RUN_DIR="${RESULT_ROOT}/runs/${RUN_ID}"
PASS1_DIR="${RUN_DIR}/pass1_explore"
PASS2_ROUTING_DIR="${RUN_DIR}/pass2_routing_opt"
PASS2_AGGRESSIVE_DIR="${RUN_DIR}/pass2_aggressive_explore"
MANIFEST="${RUN_DIR}/manifest.txt"
COMPARISON="${RUN_DIR}/comparison.txt"

mkdir -p "${PASS1_DIR}" \
    "${PASS2_ROUTING_DIR}" "${PASS2_AGGRESSIVE_DIR}"

replace_link() {
    local target="$1"
    local link_path="$2"
    if [[ -e "${link_path}" && ! -L "${link_path}" ]]; then
        rm -f "${link_path}"
    fi
    ln -sfn "${target}" "${link_path}"
}

write_stage_status() {
    local output_dir="$1"
    local state="$2"
    local exit_code="$3"
    local detail="$4"
    {
        printf 'Status: %s\n' "${state}"
        printf 'Exit code: %s\n' "${exit_code}"
        printf 'Updated: %s\n' "$(date --iso-8601=seconds)"
        printf 'Detail: %s\n' "${detail}"
        printf 'Log: %s\n' "${output_dir}/vivado.log"
    } > "${output_dir}/status.txt"
}

run_vivado_stage() {
    local label="$1"
    local tcl_script="$2"
    local output_dir="$3"
    shift 3

    mkdir -p "${output_dir}/tmp"
    write_stage_status "${output_dir}" RUNNING 0 "${label} is running"
    echo ">>> ${label}"
    echo "    output: ${output_dir}"
    echo "    log   : ${output_dir}/vivado.log"

    if (cd "${output_dir}" && vivado -mode batch -notrace \
            -log "${output_dir}/vivado.log" \
            -journal "${output_dir}/vivado.jou" \
            -tempDir "${output_dir}/tmp" \
            -source "${tcl_script}" \
            -tclargs "$@"); then
        write_stage_status "${output_dir}" SUCCESS 0 "${label} completed"
        return 0
    else
        local exit_code=$?
        write_stage_status "${output_dir}" FAILED "${exit_code}" \
            "${label} failed; previous successful stages remain valid"
        return "${exit_code}"
    fi
}

metric_value() {
    local summary_file="$1"
    local metric_name="$2"
    awk -F': ' -v key="${metric_name}" '$1 == key {print $2; exit}' \
        "${summary_file}"
}

candidate_artifacts_complete() {
    local output_dir="$1"
    local pass_number="$2"
    [[ -s "${output_dir}/postroute_physopt_pass${pass_number}.dcp" \
        && -s "${output_dir}/timing_postroute_physopt_pass${pass_number}.rpt" \
        && -s "${output_dir}/final_timing_summary.txt" \
        && -s "${output_dir}/stage_timing_report.txt" \
        && -s "${output_dir}/design.bit" ]] \
        && summary_metrics_complete "${output_dir}/final_timing_summary.txt"
}

summary_metrics_complete() {
    local summary_file="$1"
    local metric value
    local number_pattern='^-?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$'
    for metric in 'Setup WNS (ns)' 'Setup TNS (ns)' \
        'Hold WHS (ns)' 'Hold THS (ns)'; do
        value="$(metric_value "${summary_file}" "${metric}")"
        if [[ ! "${value}" =~ ${number_pattern} ]]; then
            return 1
        fi
    done
    return 0
}

candidate_is_better() {
    local candidate_summary="$1"
    local best_summary="$2"
    local candidate_wns candidate_tns candidate_whs
    local best_wns best_tns best_whs

    candidate_wns="$(metric_value "${candidate_summary}" 'Setup WNS (ns)')"
    candidate_tns="$(metric_value "${candidate_summary}" 'Setup TNS (ns)')"
    candidate_whs="$(metric_value "${candidate_summary}" 'Hold WHS (ns)')"
    best_wns="$(metric_value "${best_summary}" 'Setup WNS (ns)')"
    best_tns="$(metric_value "${best_summary}" 'Setup TNS (ns)')"
    best_whs="$(metric_value "${best_summary}" 'Hold WHS (ns)')"

    awk -v cw="${candidate_wns}" -v ct="${candidate_tns}" \
        -v ch="${candidate_whs}" -v bw="${best_wns}" \
        -v bt="${best_tns}" -v bh="${best_whs}" 'BEGIN {
            if (ch >= 0 && bh < 0) exit 0
            if (ch < 0 && bh >= 0) exit 1
            if (cw > bw + 0.0000005) exit 0
            if (cw < bw - 0.0000005) exit 1
            exit !(ct > bt)
        }'
}

GIT_COMMIT="$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
if [[ -n "$(git -C "${ROOT}" status --porcelain 2>/dev/null)" ]]; then
    GIT_STATE="dirty"
else
    GIT_STATE="clean"
fi

{
    printf 'Run ID: %s\n' "${RUN_ID}"
    printf 'Started: %s\n' "$(date --iso-8601=seconds)"
    printf 'Workspace: %s\n' "${ROOT}"
    printf 'Git commit: %s\n' "${GIT_COMMIT}"
    printf 'Git state: %s\n' "${GIT_STATE}"
    printf 'COE configuration: %s\n' "${COE_NAME}"
    printf 'COE directory: %s\n' "${COE_DIR}"
    printf 'Parallel jobs: %s\n' "${JOBS}"
    printf 'Memory check: PASSED\n'
    printf 'Available RAM at admission: %s MiB (%s)\n' \
        "${MEMORY_AVAILABLE_MIB}" "${MEMORY_LIMIT_SOURCE}"
    printf 'Estimated Vivado RAM: %s MiB\n' \
        "${MEMORY_VIVADO_ESTIMATE_MIB}"
    printf 'Reserved system RAM: %s MiB\n' "${MEMORY_RESERVE_MIB}"
    printf 'Required available RAM: %s MiB\n' "${MEMORY_REQUIRED_MIB}"
    printf 'Safe job limit at admission: %s\n' "${MEMORY_MAX_SAFE_JOBS}"
    printf 'Flow: pass1_explore -> {pass2_routing_opt, pass2_aggressive_explore}\n'
    printf 'Status: RUNNING\n'
} > "${MANIFEST}"

replace_link "runs/${RUN_ID}" "${RESULT_ROOT}/latest"
rm -f "${RESULT_ROOT}/final_timing_summary.txt" \
    "${RESULT_ROOT}/stage_timing_report.txt" \
    "${RESULT_ROOT}/recommended.dcp" \
    "${RESULT_ROOT}/recommended.bit" \
    "${RESULT_ROOT}/comparison.txt"

echo "================================================================"
echo " Multi-candidate synthesis / implementation flow"
echo "================================================================"
echo "Run directory : ${RUN_DIR}"
echo "COE           : ${COE_NAME} (${COE_DIR})"
echo "Jobs          : ${JOBS}"
echo "Pass 1        : Explore (mandatory)"
echo "Pass 2A       : routing_opt (independent)"
echo "Pass 2B       : AggressiveExplore (independent)"
echo "================================================================"

if run_vivado_stage "Mandatory pass 1 Explore" "${PASS1_TCL}" "${PASS1_DIR}" \
    --jobs "${JOBS}" --extra-physopt 0 \
    --coe-dir "${COE_DIR}" --output-dir "${PASS1_DIR}" \
    --bitstream-file "${PASS1_DIR}/design.bit"; then
    :
else
    PASS1_EXIT=$?
    printf 'Completed: %s\nStatus: FAILED\nFailure: mandatory pass 1\n' \
        "$(date --iso-8601=seconds)" >> "${MANIFEST}"
    echo "ERROR: mandatory pass 1 failed; see ${PASS1_DIR}/vivado.log" >&2
    exit "${PASS1_EXIT}"
fi

if ! candidate_artifacts_complete "${PASS1_DIR}" 1; then
    write_stage_status "${PASS1_DIR}" FAILED 1 \
        "mandatory pass 1 returned success but required artifacts are incomplete"
    printf 'Completed: %s\nStatus: FAILED\nFailure: incomplete pass-1 artifacts\n' \
        "$(date --iso-8601=seconds)" >> "${MANIFEST}"
    echo "ERROR: mandatory pass-1 artifacts are incomplete." >&2
    exit 1
fi

PASS1_DCP="${PASS1_DIR}/postroute_physopt_pass1.dcp"
ROUTING_STATUS="FAILED"
AGGRESSIVE_STATUS="FAILED"

if run_vivado_stage "Pass 2 routing-only candidate" "${PASS2_TCL}" \
    "${PASS2_ROUTING_DIR}" --jobs "${JOBS}" \
    --input-dcp "${PASS1_DCP}" --output-dir "${PASS2_ROUTING_DIR}" \
    --strategy routing_opt --bitstream-file "${PASS2_ROUTING_DIR}/design.bit"; then
    if candidate_artifacts_complete "${PASS2_ROUTING_DIR}" 2; then
        ROUTING_STATUS="SUCCESS"
    else
        write_stage_status "${PASS2_ROUTING_DIR}" FAILED 1 \
            "Vivado returned success but required candidate artifacts are incomplete"
    fi
else
    echo "WARNING: routing_opt candidate failed; continuing." >&2
fi

if run_vivado_stage "Pass 2 AggressiveExplore candidate" "${PASS2_TCL}" \
    "${PASS2_AGGRESSIVE_DIR}" --jobs "${JOBS}" \
    --input-dcp "${PASS1_DCP}" --output-dir "${PASS2_AGGRESSIVE_DIR}" \
    --strategy aggressive_explore \
    --bitstream-file "${PASS2_AGGRESSIVE_DIR}/design.bit"; then
    if candidate_artifacts_complete "${PASS2_AGGRESSIVE_DIR}" 2; then
        AGGRESSIVE_STATUS="SUCCESS"
    else
        write_stage_status "${PASS2_AGGRESSIVE_DIR}" FAILED 1 \
            "Vivado returned success but required candidate artifacts are incomplete"
    fi
else
    echo "WARNING: AggressiveExplore candidate failed; continuing." >&2
fi

BEST_NAME="pass1_explore"
BEST_DIR="${PASS1_DIR}"
BEST_SUMMARY="${PASS1_DIR}/final_timing_summary.txt"
BEST_DCP="${PASS1_DIR}/postroute_physopt_pass1.dcp"

if [[ "${ROUTING_STATUS}" == "SUCCESS" ]] && \
    candidate_is_better "${PASS2_ROUTING_DIR}/final_timing_summary.txt" "${BEST_SUMMARY}"; then
    BEST_NAME="pass2_routing_opt"
    BEST_DIR="${PASS2_ROUTING_DIR}"
    BEST_SUMMARY="${BEST_DIR}/final_timing_summary.txt"
    BEST_DCP="${BEST_DIR}/postroute_physopt_pass2.dcp"
fi

if [[ "${AGGRESSIVE_STATUS}" == "SUCCESS" ]] && \
    candidate_is_better "${PASS2_AGGRESSIVE_DIR}/final_timing_summary.txt" "${BEST_SUMMARY}"; then
    BEST_NAME="pass2_aggressive_explore"
    BEST_DIR="${PASS2_AGGRESSIVE_DIR}"
    BEST_SUMMARY="${BEST_DIR}/final_timing_summary.txt"
    BEST_DCP="${BEST_DIR}/postroute_physopt_pass2.dcp"
fi

append_candidate_report() {
    local display_name="$1"
    local state="$2"
    local output_dir="$3"
    printf '%s\n' "[${display_name}]"
    printf 'Status: %s\n' "${state}"
    if [[ "${state}" == "SUCCESS" ]]; then
        printf 'Setup WNS (ns): %s\n' \
            "$(metric_value "${output_dir}/final_timing_summary.txt" 'Setup WNS (ns)')"
        printf 'Setup TNS (ns): %s\n' \
            "$(metric_value "${output_dir}/final_timing_summary.txt" 'Setup TNS (ns)')"
        printf 'Hold WHS (ns): %s\n' \
            "$(metric_value "${output_dir}/final_timing_summary.txt" 'Hold WHS (ns)')"
        printf 'Hold THS (ns): %s\n' \
            "$(metric_value "${output_dir}/final_timing_summary.txt" 'Hold THS (ns)')"
        printf 'Timing status: %s\n' \
            "$(metric_value "${output_dir}/final_timing_summary.txt" 'Timing status')"
    else
        printf 'Failure report: %s\n' "${output_dir}/status.txt"
        printf 'Log: %s\n' "${output_dir}/vivado.log"
    fi
    printf '\n'
}

{
    printf 'Run ID: %s\n\n' "${RUN_ID}"
    append_candidate_report "pass1_explore" SUCCESS "${PASS1_DIR}"
    append_candidate_report "pass2_routing_opt" "${ROUTING_STATUS}" \
        "${PASS2_ROUTING_DIR}"
    append_candidate_report "pass2_aggressive_explore" "${AGGRESSIVE_STATUS}" \
        "${PASS2_AGGRESSIVE_DIR}"
    printf '[Recommendation]\n'
    printf 'Selected candidate: %s\n' "${BEST_NAME}"
    printf 'Selected directory: %s\n' "${BEST_DIR}"
    printf 'Selection policy: routed/DRC success, non-negative hold, best WNS, then best TNS\n'
} > "${COMPARISON}"

replace_link "${BEST_NAME}" "${RUN_DIR}/best"
replace_link "latest/best/final_timing_summary.txt" \
    "${RESULT_ROOT}/final_timing_summary.txt"
replace_link "latest/best/stage_timing_report.txt" \
    "${RESULT_ROOT}/stage_timing_report.txt"
replace_link "latest/best/design.bit" "${RESULT_ROOT}/recommended.bit"
replace_link "latest/best/$(basename "${BEST_DCP}")" \
    "${RESULT_ROOT}/recommended.dcp"
replace_link "latest/comparison.txt" "${RESULT_ROOT}/comparison.txt"

if [[ "${ROUTING_STATUS}" == "SUCCESS" && \
      "${AGGRESSIVE_STATUS}" == "SUCCESS" ]]; then
    OVERALL_STATUS="SUCCESS"
else
    OVERALL_STATUS="SUCCESS_WITH_WARNINGS"
fi

{
    printf 'Completed: %s\n' "$(date --iso-8601=seconds)"
    printf 'Status: %s\n' "${OVERALL_STATUS}"
    printf 'Pass 2 routing_opt: %s\n' "${ROUTING_STATUS}"
    printf 'Pass 2 aggressive_explore: %s\n' "${AGGRESSIVE_STATUS}"
    printf 'Selected candidate: %s\n' "${BEST_NAME}"
    printf 'Comparison: %s\n' "${COMPARISON}"
} >> "${MANIFEST}"

echo ""
echo "================================================================"
echo " Flow complete: ${OVERALL_STATUS}"
echo " Selected candidate : ${BEST_NAME}"
echo " Selected summary   : ${BEST_SUMMARY}"
echo " Comparison report  : ${COMPARISON}"
echo " Stable result root : ${RESULT_ROOT}"
echo "================================================================"
sed -n '1,$p' "${COMPARISON}"
