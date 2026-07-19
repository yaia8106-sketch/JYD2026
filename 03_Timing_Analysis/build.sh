#!/usr/bin/env bash
# ================================================================
# Restartable three-candidate timing flow:
#   1. Synthesis + route, followed by a persisted routed checkpoint.
#   2. Mandatory pass-1 Explore in an independent Vivado process.
#   3. Independent pass-2 routing_opt candidate from pass 1.
#   4. Independent pass-2 AggressiveExplore candidate from pass 1.
#
# An incomplete run with an identical input fingerprint is resumed
# automatically. Each physopt stage runs in its own Vivado process. Failed
# pass-1 Explore and AggressiveExplore stages are retried once in a fresh
# single-threaded process. A final pass-2 failure is recorded without
# invalidating pass 1 or the other candidate, and is retried on the next call.
#
# Usage:
#   03_Timing_Analysis/build.sh [--fresh] <parallel jobs> <COE configuration> [frequency MHz]
# Example:
#   03_Timing_Analysis/build.sh 5 withM
#   03_Timing_Analysis/build.sh 5 withM 180
#
# COE configuration:
#   current | src0 | src1 | src2 | withM | withoutM
# ================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT}/03_Timing_Analysis"
ROUTE_TCL="${SCRIPT_DIR}/run_synth_impl.tcl"
PHYSOPT_TCL="${SCRIPT_DIR}/run_physopt_candidate.tcl"
FLOW_FINGERPRINT_SCHEMA="restartable-timing-flow-v1"
MAX_PARALLEL_JOBS=5

usage() {
    printf '%s\n' \
        'Usage:' \
        '  03_Timing_Analysis/build.sh [--fresh] <parallel jobs (1..5)> <COE configuration> [frequency MHz]' \
        '' \
        'Example:' \
        '  03_Timing_Analysis/build.sh 5 withM' \
        '  03_Timing_Analysis/build.sh 5 withM 180' \
        '  03_Timing_Analysis/build.sh --fresh 5 withM 180' \
        '' \
        'Frequency:' \
        '  Optional positive MHz value; default: 200' \
        '  Both 180 and 180MHz forms are accepted.' \
        '' \
        'COE configuration:' \
        '  current | src0 | src1 | src2 | withM | withoutM' \
        '' \
        'Recovery:' \
        '  An incomplete run is resumed only when its complete input fingerprint' \
        '  matches. --fresh always starts a new clean synthesis/implementation.' \
        '' \
        'Flow:' \
        '  route -> pass1_explore -> {pass2_routing_opt, pass2_aggressive_explore}' \
        '  Failed pass-1 Explore and AggressiveExplore get one single-thread retry.'
}

require_positive_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: ${name} must be a positive integer, got '${value}'." >&2
        exit 2
    fi
}

normalize_frequency_mhz() {
    local value="$1"
    if [[ "${value}" =~ ^([0-9]+([.][0-9]+)?)([mM][hH][zZ])?$ ]]; then
        value="${BASH_REMATCH[1]}"
    else
        echo "ERROR: frequency must be a positive MHz value, got '${1}'." >&2
        exit 2
    fi
    if ! awk -v value="${value}" 'BEGIN { exit !(value > 0) }'; then
        echo "ERROR: frequency must be greater than zero, got '${1}'." >&2
        exit 2
    fi
    awk -v value="${value}" 'BEGIN {
        text = sprintf("%.9f", value)
        sub(/0+$/, "", text)
        sub(/[.]$/, "", text)
        print text
    }'
}

FORCE_FRESH=0
POSITIONAL_ARGS=()
for arg in "$@"; do
    case "${arg}" in
        -h|--help)
            usage
            exit 0
            ;;
        --fresh)
            FORCE_FRESH=1
            ;;
        --)
            ;;
        --*)
            echo "ERROR: unknown option '${arg}'." >&2
            usage >&2
            exit 2
            ;;
        *)
            POSITIONAL_ARGS+=("${arg}")
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"
if (( FORCE_FRESH )); then
    FRESH_REQUESTED="YES"
else
    FRESH_REQUESTED="NO"
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage >&2
    exit 2
fi

JOBS="$1"
COE_NAME="$2"
FREQUENCY_MHZ="$(normalize_frequency_mhz "${3:-200}")"
CLOCK_PERIOD_NS="$(awk -v frequency="${FREQUENCY_MHZ}" \
    'BEGIN { printf "%.9f", 1000.0 / frequency }')"

require_positive_integer "parallel jobs" "${JOBS}"
JOBS="$((10#${JOBS}))"
if (( JOBS > MAX_PARALLEL_JOBS )); then
    echo "ERROR: parallel jobs must not exceed ${MAX_PARALLEL_JOBS}, got '${JOBS}'." >&2
    exit 2
fi
VIVADO_CPU_LIST="0-$((JOBS - 1))"

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
if [[ ! -f "${ROUTE_TCL}" || ! -f "${PHYSOPT_TCL}" ]]; then
    echo "ERROR: timing-flow Tcl scripts are incomplete under ${SCRIPT_DIR}." >&2
    exit 2
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
if ! command -v taskset >/dev/null 2>&1; then
    echo "ERROR: taskset is required to enforce the ${JOBS}-CPU build limit." >&2
    exit 127
fi

RESULTS_BASE="${CPU_TIMING_RESULTS_BASE:-${SCRIPT_DIR}/results}"
RESULT_ROOT="${RESULTS_BASE}/${COE_NAME}"
PROJECT_STATE_FILE="${RESULTS_BASE}/.project_state"
BUILD_LOCK_FILE="${SCRIPT_DIR}/results/.build.lock"
mkdir -p "${RESULT_ROOT}/runs" "$(dirname "${BUILD_LOCK_FILE}")"

if ! command -v flock >/dev/null 2>&1; then
    echo "ERROR: flock is required for safe restartable builds." >&2
    exit 127
fi
exec 9>"${BUILD_LOCK_FILE}"
if ! flock -n 9; then
    echo "ERROR: another timing build is already using the shared Vivado project." >&2
    exit 75
fi

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

    if (cd "${output_dir}" && taskset --cpu-list "${VIVADO_CPU_LIST}" \
            vivado -mode batch -notrace \
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

manifest_last_value() {
    local manifest_file="$1"
    local key="$2"
    awk -v key="${key}" '
        index($0, key ": ") == 1 {
            value = substr($0, length(key) + 3)
        }
        END { print value }
    ' "${manifest_file}"
}

fingerprint_payload() {
    local input_file relative_path digest

    printf 'schema=%s\n' "${FLOW_FINGERPRINT_SCHEMA}"
    printf 'coe=%s\n' "${COE_NAME}"
    printf 'frequency_mhz=%s\n' "${FREQUENCY_MHZ}"
    printf 'vivado=%s\n' "${VIVADO_VERSION}"

    while IFS= read -r -d '' input_file; do
        [[ -f "${input_file}" ]] || continue
        relative_path="${input_file#"${ROOT}/"}"
        digest="$(sha256sum "${input_file}" | awk '{print $1}')"
        printf 'file=%s\nsha256=%s\n' "${relative_path}" "${digest}"
    done < <(
        {
            find "${ROOT}/02_Design/rtl" \
                "${ROOT}/02_Design/contest_readonly/rtl" \
                "${ROOT}/JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/new" \
                -type f \( -name '*.sv' -o -name '*.v' -o -name '*.svh' \
                    -o -name '*.vh' \) -print0
            find "${ROOT}/JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/ip" \
                -type f -name '*.xci' \
                ! -path '*/IROM64/*' ! -path '*/DRAM4MyOwn/*' \
                ! -path '*/pll_1/*' -print0
            printf '%s\0' \
                "${ROOT}/JYD2025_Contest-rv32i/digital_twin.xpr" \
                "${ROOT}/JYD2025_Contest-rv32i/digital_twin.srcs/constrs_1/new/digital_twin.xdc" \
                "${COE_DIR}/irom64.coe" "${COE_DIR}/dram.coe" \
                "${BASH_SOURCE[0]}" "${ROUTE_TCL}" "${PHYSOPT_TCL}" \
                "${SCRIPT_DIR}/report_stage_timing.tcl"
        } | sort -zu
    )
}

legacy_source_compatible() {
    local commit="$1"
    local coe_relative="${COE_DIR#"${ROOT}/"}"

    [[ "${commit}" != "unknown" ]] || return 1
    git -C "${ROOT}" rev-parse --verify "${commit}^{commit}" >/dev/null 2>&1 \
        || return 1
    git -C "${ROOT}" diff --quiet "${commit}" -- \
        02_Design/rtl \
        02_Design/contest_readonly/rtl \
        JYD2025_Contest-rv32i/digital_twin.xpr \
        JYD2025_Contest-rv32i/digital_twin.srcs/constrs_1/new/digital_twin.xdc \
        JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/ip/IROMEven32/IROMEven32.xci \
        JYD2025_Contest-rv32i/digital_twin.srcs/sources_1/ip/IROMOdd32/IROMOdd32.xci \
        "${coe_relative}"
}

legacy_routed_checkpoint_matches_run() {
    local manifest_file="$1"
    local project_dcp="${ROOT}/JYD2025_Contest-rv32i/digital_twin.runs/impl_1/top_routed.dcp"
    local started completed started_epoch completed_epoch dcp_epoch

    [[ -s "${project_dcp}" ]] || return 1
    started="$(manifest_last_value "${manifest_file}" Started)"
    completed="$(manifest_last_value "${manifest_file}" Completed)"
    started_epoch="$(date -d "${started}" +%s 2>/dev/null)" || return 1
    dcp_epoch="$(stat -c %Y "${project_dcp}")"
    (( dcp_epoch >= started_epoch )) || return 1
    if [[ -n "${completed}" ]]; then
        completed_epoch="$(date -d "${completed}" +%s 2>/dev/null)" || return 1
        (( dcp_epoch <= completed_epoch )) || return 1
    fi
}

find_resume_run() {
    local manifest_file fingerprint status

    while IFS= read -r manifest_file; do
        fingerprint="$(manifest_last_value "${manifest_file}" 'Build fingerprint')"
        [[ "${fingerprint}" == "${BUILD_FINGERPRINT}" ]] || continue
        status="$(manifest_last_value "${manifest_file}" Status)"
        case "${status}" in
            FAILED|RUNNING|SUCCESS_WITH_WARNINGS)
                printf '%s\t%s\n' "$(dirname "${manifest_file}")" exact
                return 0
                ;;
            SUCCESS)
                return 1
                ;;
        esac
    done < <(find "${RESULT_ROOT}/runs" -mindepth 2 -maxdepth 2 \
        -type f -name manifest.txt -printf '%T@ %p\n' \
        | sort -nr | cut -d' ' -f2-)
    return 1
}

matching_fingerprint_exists() {
    local manifest_file fingerprint

    while IFS= read -r manifest_file; do
        fingerprint="$(manifest_last_value "${manifest_file}" 'Build fingerprint')"
        [[ "${fingerprint}" == "${BUILD_FINGERPRINT}" ]] && return 0
    done < <(find "${RESULT_ROOT}/runs" -mindepth 2 -maxdepth 2 \
        -type f -name manifest.txt -print)
    return 1
}

find_legacy_resume_run() {
    local manifest_file fingerprint status manifest_coe manifest_frequency
    local legacy_commit run_dir

    while IFS= read -r manifest_file; do
        fingerprint="$(manifest_last_value "${manifest_file}" 'Build fingerprint')"
        [[ -z "${fingerprint}" ]] || continue
        manifest_coe="$(manifest_last_value "${manifest_file}" 'COE configuration')"
        [[ "${manifest_coe}" == "${COE_NAME}" ]] || continue
        manifest_frequency="$(manifest_last_value "${manifest_file}" 'Requested frequency')"
        manifest_frequency="${manifest_frequency% MHz}"
        awk -v old="${manifest_frequency}" -v new="${FREQUENCY_MHZ}" \
            'BEGIN { exit !(old != "" && (old - new < 0.0000005) && (new - old < 0.0000005)) }' \
            || continue

        status="$(manifest_last_value "${manifest_file}" Status)"
        case "${status}" in
            FAILED|RUNNING) ;;
            SUCCESS|SUCCESS_WITH_WARNINGS) return 1 ;;
            *) continue ;;
        esac

        legacy_commit="$(manifest_last_value "${manifest_file}" 'Git commit')"
        legacy_source_compatible "${legacy_commit}" || continue
        run_dir="$(dirname "${manifest_file}")"
        if candidate_artifacts_complete "${run_dir}/pass1_explore" 1 \
            || legacy_routed_checkpoint_matches_run "${manifest_file}"; then
            printf '%s\t%s\n' "${run_dir}" legacy
            return 0
        fi
    done < <(find "${RESULT_ROOT}/runs" -mindepth 2 -maxdepth 2 \
        -type f -name manifest.txt -printf '%T@ %p\n' \
        | sort -nr | cut -d' ' -f2-)
    return 1
}

archive_failed_stage() {
    local stage_dir="$1"
    local archive_dir

    ARCHIVED_STAGE_DIR=""
    if [[ -d "${stage_dir}" ]] \
        && find "${stage_dir}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        archive_dir="${stage_dir}_attempt_failed_$(date +%Y%m%d_%H%M%S)_$$"
        mv -- "${stage_dir}" "${archive_dir}"
        ARCHIVED_STAGE_DIR="${archive_dir}"
        echo ">>> Archived incomplete stage: ${archive_dir}"
    fi
    mkdir -p "${stage_dir}"
}

write_project_state() {
    local temporary_file="${PROJECT_STATE_FILE}.tmp.$$"
    {
        printf 'Build fingerprint: %s\n' "${BUILD_FINGERPRINT}"
        printf 'Run ID: %s\n' "${RUN_ID}"
        printf 'Status: PREPARING\n'
        printf 'Updated: %s\n' "$(date --iso-8601=seconds)"
    } > "${temporary_file}"
    mv -f "${temporary_file}" "${PROJECT_STATE_FILE}"
}

project_state_matches() {
    [[ -f "${PROJECT_STATE_FILE}" ]] \
        && [[ "$(manifest_last_value "${PROJECT_STATE_FILE}" 'Build fingerprint')" \
            == "${BUILD_FINGERPRINT}" ]] \
        && [[ "$(manifest_last_value "${PROJECT_STATE_FILE}" 'Run ID')" == "${RUN_ID}" ]] \
        && [[ "$(manifest_last_value "${PROJECT_STATE_FILE}" Status)" == "READY" ]]
}

VIVADO_VERSION="$(vivado -version 2>/dev/null | sed -n '1p')"
BUILD_FINGERPRINT="$(fingerprint_payload | sha256sum | awk '{print $1}')"

RESUMING=0
RESUME_KIND="none"
RESUME_SELECTION=""
if (( ! FORCE_FRESH )); then
    RESUME_SELECTION="$(find_resume_run || true)"
    if [[ -z "${RESUME_SELECTION}" ]] && ! matching_fingerprint_exists; then
        RESUME_SELECTION="$(find_legacy_resume_run || true)"
    fi
fi

if [[ -n "${RESUME_SELECTION}" ]]; then
    RUN_DIR="${RESUME_SELECTION%%$'\t'*}"
    RESUME_KIND="${RESUME_SELECTION#*$'\t'}"
    RUN_ID="$(basename "${RUN_DIR}")"
    RESUMING=1
else
    RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
    RUN_DIR="${RESULT_ROOT}/runs/${RUN_ID}"
fi

ROUTE_DIR="${RUN_DIR}/route"
ROUTED_DCP="${ROUTE_DIR}/pre_physopt_routed.dcp"
PASS1_DIR="${RUN_DIR}/pass1_explore"
PASS2_ROUTING_DIR="${RUN_DIR}/pass2_routing_opt"
PASS2_AGGRESSIVE_DIR="${RUN_DIR}/pass2_aggressive_explore"
MANIFEST="${RUN_DIR}/manifest.txt"
COMPARISON="${RUN_DIR}/comparison.txt"
mkdir -p "${ROUTE_DIR}" "${PASS1_DIR}" \
    "${PASS2_ROUTING_DIR}" "${PASS2_AGGRESSIVE_DIR}"

GIT_COMMIT="$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
if [[ -n "$(git -C "${ROOT}" status --porcelain 2>/dev/null)" ]]; then
    GIT_STATE="dirty"
else
    GIT_STATE="clean"
fi

if (( RESUMING )); then
    if [[ "${RESUME_KIND}" == "legacy" ]]; then
        if [[ ! -s "${ROUTED_DCP}" ]] \
            && ! candidate_artifacts_complete "${PASS1_DIR}" 1; then
            cp --reflink=auto \
                "${ROOT}/JYD2025_Contest-rv32i/digital_twin.runs/impl_1/top_routed.dcp" \
                "${ROUTED_DCP}"
            write_stage_status "${ROUTE_DIR}" SUCCESS 0 \
                "adopted routed checkpoint from the matching legacy failed run"
        fi
        printf 'Build fingerprint: %s\n' "${BUILD_FINGERPRINT}" >> "${MANIFEST}"
        printf 'Recovery schema: %s\n' "${FLOW_FINGERPRINT_SCHEMA}" >> "${MANIFEST}"
    fi
    {
        printf 'Resumed: %s\n' "$(date --iso-8601=seconds)"
        printf 'Resume kind: %s\n' "${RESUME_KIND}"
        printf 'Resume parallel jobs: %s\n' "${JOBS}"
        printf 'Status: RUNNING\n'
    } >> "${MANIFEST}"
else
    {
        printf 'Run ID: %s\n' "${RUN_ID}"
        printf 'Started: %s\n' "$(date --iso-8601=seconds)"
        printf 'Workspace: %s\n' "${ROOT}"
        printf 'Git commit: %s\n' "${GIT_COMMIT}"
        printf 'Git state: %s\n' "${GIT_STATE}"
        printf 'Build fingerprint: %s\n' "${BUILD_FINGERPRINT}"
        printf 'Recovery schema: %s\n' "${FLOW_FINGERPRINT_SCHEMA}"
        printf 'COE configuration: %s\n' "${COE_NAME}"
        printf 'COE directory: %s\n' "${COE_DIR}"
        printf 'Parallel jobs: %s\n' "${JOBS}"
        printf 'Fresh requested: %s\n' "${FRESH_REQUESTED}"
        printf 'Requested frequency: %s MHz\n' "${FREQUENCY_MHZ}"
        printf 'Requested clock period: %s ns\n' "${CLOCK_PERIOD_NS}"
        printf 'Vivado version: %s\n' "${VIVADO_VERSION}"
        printf 'Flow: route -> pass1_explore -> {pass2_routing_opt, pass2_aggressive_explore}\n'
        printf 'Status: RUNNING\n'
    } > "${MANIFEST}"
fi

replace_link "runs/${RUN_ID}" "${RESULT_ROOT}/latest"
if (( ! RESUMING )); then
    rm -f "${RESULT_ROOT}/final_timing_summary.txt" \
        "${RESULT_ROOT}/stage_timing_report.txt" \
        "${RESULT_ROOT}/recommended.dcp" \
        "${RESULT_ROOT}/recommended.bit" \
        "${RESULT_ROOT}/comparison.txt"
fi

if (( RESUMING )); then
    RECOVERY_LABEL="RESUME (${RESUME_KIND})"
else
    RECOVERY_LABEL="NEW"
fi

echo "================================================================"
echo " Multi-candidate synthesis / implementation flow"
echo "================================================================"
echo "Run directory : ${RUN_DIR}"
echo "Recovery      : ${RECOVERY_LABEL}"
echo "Fingerprint   : ${BUILD_FINGERPRINT}"
echo "COE           : ${COE_NAME} (${COE_DIR})"
echo "Jobs          : ${JOBS}"
echo "CPU affinity  : ${VIVADO_CPU_LIST} (${JOBS} logical CPUs maximum)"
echo "Frequency     : ${FREQUENCY_MHZ} MHz (${CLOCK_PERIOD_NS} ns)"
echo "Route DCP     : ${ROUTED_DCP}"
echo "Pass 1        : Explore (mandatory)"
echo "Pass 2A       : routing_opt (independent)"
echo "Pass 2B       : AggressiveExplore (one single-thread retry on failure)"
echo "================================================================"

if [[ -s "${ROUTED_DCP}" ]]; then
    echo ">>> Reusing completed synthesis/route checkpoint"
    echo "    checkpoint: ${ROUTED_DCP}"
else
    RESUME_PROJECT_RUNS=0
    if (( RESUMING )) && project_state_matches; then
        RESUME_PROJECT_RUNS=1
    fi
    archive_failed_stage "${ROUTE_DIR}"
    write_project_state

    ROUTE_ARGS=(
        --jobs "${JOBS}"
        --freq-mhz "${FREQUENCY_MHZ}"
        --extra-physopt 0
        --output-dir "${ROUTE_DIR}"
        --stop-after-route
        --routed-checkpoint-file "${ROUTED_DCP}"
        --resume-state-file "${PROJECT_STATE_FILE}"
    )
    if (( RESUME_PROJECT_RUNS )); then
        echo ">>> Retrying the failed Vivado project run from its last completed step"
        ROUTE_ARGS+=(--no-reset)
    else
        ROUTE_ARGS+=(--coe-dir "${COE_DIR}")
    fi

    if run_vivado_stage "Synthesis and implementation through route" \
        "${ROUTE_TCL}" "${ROUTE_DIR}" "${ROUTE_ARGS[@]}"; then
        if [[ ! -s "${ROUTED_DCP}" ]]; then
            write_stage_status "${ROUTE_DIR}" FAILED 1 \
                "route stage returned success without a persisted routed checkpoint"
        fi
    else
        ROUTE_EXIT=$?
        printf 'Completed: %s\nStatus: FAILED\nFailure: synthesis/route\n' \
            "$(date --iso-8601=seconds)" >> "${MANIFEST}"
        echo "ERROR: synthesis/route failed; the next identical call will resume this run." >&2
        exit "${ROUTE_EXIT}"
    fi

    if [[ ! -s "${ROUTED_DCP}" ]]; then
        printf 'Completed: %s\nStatus: FAILED\nFailure: missing routed checkpoint\n' \
            "$(date --iso-8601=seconds)" >> "${MANIFEST}"
        echo "ERROR: routed checkpoint was not persisted." >&2
        exit 1
    fi
fi

PASS1_INITIAL_STATUS="REUSED"
PASS1_RETRY_STATUS="NOT_NEEDED"
PASS1_INITIAL_FAILURE_DIR=""
if candidate_artifacts_complete "${PASS1_DIR}" 1; then
    echo ">>> Reusing completed mandatory pass 1 Explore"
else
    archive_failed_stage "${PASS1_DIR}"
    PASS1_INITIAL_STATUS="FAILED"
    if run_vivado_stage "Mandatory pass 1 Explore" "${PHYSOPT_TCL}" \
        "${PASS1_DIR}" --jobs "${JOBS}" --freq-mhz "${FREQUENCY_MHZ}" \
        --input-dcp "${ROUTED_DCP}" --output-dir "${PASS1_DIR}" \
        --strategy explore --pass-number 1 \
        --bitstream-file "${PASS1_DIR}/design.bit"; then
        if candidate_artifacts_complete "${PASS1_DIR}" 1; then
            PASS1_INITIAL_STATUS="SUCCESS"
        else
            write_stage_status "${PASS1_DIR}" FAILED 1 \
                "pass 1 returned success but required artifacts are incomplete"
        fi
    fi

    if [[ "${PASS1_INITIAL_STATUS}" != "SUCCESS" ]]; then
        echo "WARNING: retrying mandatory pass 1 with one Vivado thread." >&2
        archive_failed_stage "${PASS1_DIR}"
        PASS1_INITIAL_FAILURE_DIR="${ARCHIVED_STAGE_DIR}"
        PASS1_RETRY_STATUS="FAILED"
        if run_vivado_stage "Mandatory pass 1 single-thread retry" \
            "${PHYSOPT_TCL}" "${PASS1_DIR}" --jobs 1 \
            --freq-mhz "${FREQUENCY_MHZ}" \
            --input-dcp "${ROUTED_DCP}" --output-dir "${PASS1_DIR}" \
            --strategy explore --pass-number 1 \
            --bitstream-file "${PASS1_DIR}/design.bit"; then
            if candidate_artifacts_complete "${PASS1_DIR}" 1; then
                PASS1_RETRY_STATUS="SUCCESS"
            else
                write_stage_status "${PASS1_DIR}" FAILED 1 \
                    "single-thread pass-1 retry returned incomplete artifacts"
            fi
        fi
    fi
fi

if ! candidate_artifacts_complete "${PASS1_DIR}" 1; then
    {
        printf 'Completed: %s\n' "$(date --iso-8601=seconds)"
        printf 'Status: FAILED\n'
        printf 'Failure: mandatory pass 1\n'
        printf 'Pass 1 initial: %s\n' "${PASS1_INITIAL_STATUS}"
        printf 'Pass 1 retry: %s\n' "${PASS1_RETRY_STATUS}"
    } >> "${MANIFEST}"
    echo "ERROR: mandatory pass 1 failed; the routed checkpoint remains resumable." >&2
    exit 1
fi

PASS1_DCP="${PASS1_DIR}/postroute_physopt_pass1.dcp"
ROUTING_STATUS="FAILED"
AGGRESSIVE_STATUS="FAILED"
AGGRESSIVE_INITIAL_STATUS="FAILED"
AGGRESSIVE_RETRY_STATUS="NOT_NEEDED"
AGGRESSIVE_INITIAL_FAILURE_DIR=""

if candidate_artifacts_complete "${PASS2_ROUTING_DIR}" 2; then
    ROUTING_STATUS="SUCCESS"
    echo ">>> Reusing completed Pass 2 routing-only candidate"
else
    archive_failed_stage "${PASS2_ROUTING_DIR}"
    if run_vivado_stage "Pass 2 routing-only candidate" "${PHYSOPT_TCL}" \
        "${PASS2_ROUTING_DIR}" --jobs "${JOBS}" \
        --freq-mhz "${FREQUENCY_MHZ}" \
        --input-dcp "${PASS1_DCP}" --output-dir "${PASS2_ROUTING_DIR}" \
        --strategy routing_opt --pass-number 2 \
        --bitstream-file "${PASS2_ROUTING_DIR}/design.bit"; then
        if candidate_artifacts_complete "${PASS2_ROUTING_DIR}" 2; then
            ROUTING_STATUS="SUCCESS"
        else
            write_stage_status "${PASS2_ROUTING_DIR}" FAILED 1 \
                "Vivado returned success but required candidate artifacts are incomplete"
        fi
    else
        echo "WARNING: routing_opt candidate failed; continuing." >&2
    fi
fi

if candidate_artifacts_complete "${PASS2_AGGRESSIVE_DIR}" 2; then
    AGGRESSIVE_INITIAL_STATUS="REUSED"
    AGGRESSIVE_STATUS="SUCCESS"
    echo ">>> Reusing completed Pass 2 AggressiveExplore candidate"
else
    archive_failed_stage "${PASS2_AGGRESSIVE_DIR}"
    if run_vivado_stage "Pass 2 AggressiveExplore candidate" "${PHYSOPT_TCL}" \
        "${PASS2_AGGRESSIVE_DIR}" --jobs "${JOBS}" \
        --freq-mhz "${FREQUENCY_MHZ}" \
        --input-dcp "${PASS1_DCP}" --output-dir "${PASS2_AGGRESSIVE_DIR}" \
        --strategy aggressive_explore --pass-number 2 \
        --bitstream-file "${PASS2_AGGRESSIVE_DIR}/design.bit"; then
        if candidate_artifacts_complete "${PASS2_AGGRESSIVE_DIR}" 2; then
            AGGRESSIVE_INITIAL_STATUS="SUCCESS"
            AGGRESSIVE_STATUS="SUCCESS"
        else
            write_stage_status "${PASS2_AGGRESSIVE_DIR}" FAILED 1 \
                "Vivado returned success but required candidate artifacts are incomplete"
        fi
    else
        echo "WARNING: initial AggressiveExplore candidate failed." >&2
    fi
fi

if [[ "${AGGRESSIVE_STATUS}" != "SUCCESS" ]]; then
    echo "WARNING: retrying AggressiveExplore once with one Vivado thread." >&2
    archive_failed_stage "${PASS2_AGGRESSIVE_DIR}"
    AGGRESSIVE_INITIAL_FAILURE_DIR="${ARCHIVED_STAGE_DIR}"
    AGGRESSIVE_RETRY_STATUS="FAILED"

    if run_vivado_stage \
        "Pass 2 AggressiveExplore single-thread retry" \
        "${PHYSOPT_TCL}" "${PASS2_AGGRESSIVE_DIR}" --jobs 1 \
        --freq-mhz "${FREQUENCY_MHZ}" \
        --input-dcp "${PASS1_DCP}" \
        --output-dir "${PASS2_AGGRESSIVE_DIR}" \
        --strategy aggressive_explore --pass-number 2 \
        --bitstream-file "${PASS2_AGGRESSIVE_DIR}/design.bit"; then
        if candidate_artifacts_complete "${PASS2_AGGRESSIVE_DIR}" 2; then
            AGGRESSIVE_RETRY_STATUS="SUCCESS"
            AGGRESSIVE_STATUS="SUCCESS"
        else
            write_stage_status "${PASS2_AGGRESSIVE_DIR}" FAILED 1 \
                "single-thread retry returned success but required candidate artifacts are incomplete"
        fi
    else
        echo "WARNING: AggressiveExplore single-thread retry failed; continuing." >&2
    fi
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
    printf 'Requested frequency: %s MHz\n' "${FREQUENCY_MHZ}"
    printf 'Requested clock period: %s ns\n\n' "${CLOCK_PERIOD_NS}"
    append_candidate_report "pass1_explore" SUCCESS "${PASS1_DIR}"
    append_candidate_report "pass2_routing_opt" "${ROUTING_STATUS}" \
        "${PASS2_ROUTING_DIR}"
    append_candidate_report "pass2_aggressive_explore" "${AGGRESSIVE_STATUS}" \
        "${PASS2_AGGRESSIVE_DIR}"
    printf '%s\n' '[pass1_explore_attempts]'
    printf 'Initial jobs: %s\n' "${JOBS}"
    printf 'Initial status: %s\n' "${PASS1_INITIAL_STATUS}"
    if [[ "${PASS1_RETRY_STATUS}" == "NOT_NEEDED" ]]; then
        printf 'Retry attempted: NO\n'
    else
        printf 'Retry attempted: YES\n'
        printf 'Retry jobs: 1\n'
        printf 'Retry status: %s\n' "${PASS1_RETRY_STATUS}"
        printf 'Initial failure directory: %s\n' \
            "${PASS1_INITIAL_FAILURE_DIR}"
    fi
    printf '\n'
    printf '%s\n' '[pass2_aggressive_explore_attempts]'
    printf 'Initial jobs: %s\n' "${JOBS}"
    printf 'Initial status: %s\n' "${AGGRESSIVE_INITIAL_STATUS}"
    if [[ "${AGGRESSIVE_RETRY_STATUS}" == "NOT_NEEDED" ]]; then
        printf 'Retry attempted: NO\n'
    else
        printf 'Retry attempted: YES\n'
        printf 'Retry jobs: 1\n'
        printf 'Retry status: %s\n' "${AGGRESSIVE_RETRY_STATUS}"
        printf 'Initial failure directory: %s\n' \
            "${AGGRESSIVE_INITIAL_FAILURE_DIR}"
        printf 'Initial failure report: %s/status.txt\n' \
            "${AGGRESSIVE_INITIAL_FAILURE_DIR}"
        printf 'Initial failure log: %s/vivado.log\n' \
            "${AGGRESSIVE_INITIAL_FAILURE_DIR}"
    fi
    printf '\n'
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
    printf 'Pass 1 initial: %s\n' "${PASS1_INITIAL_STATUS}"
    printf 'Pass 1 retry: %s\n' "${PASS1_RETRY_STATUS}"
    printf 'Pass 2 routing_opt: %s\n' "${ROUTING_STATUS}"
    printf 'Pass 2 aggressive initial: %s\n' \
        "${AGGRESSIVE_INITIAL_STATUS}"
    printf 'Pass 2 aggressive retry: %s\n' \
        "${AGGRESSIVE_RETRY_STATUS}"
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
