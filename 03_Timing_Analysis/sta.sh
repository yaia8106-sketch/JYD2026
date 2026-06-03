#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${WORKSPACE}/JYD2025_Contest-rv32i/digital_twin.xpr"
TIMING_TCL="${SCRIPT_DIR}/report_stage_timing.tcl"
VIVADO_WORK="${SCRIPT_DIR}/vivado_work"
RUN_NAME="${1:-impl_1}"

if [[ "${RUN_NAME}" == "-h" || "${RUN_NAME}" == "--help" ]]; then
    cat <<'EOF'
Usage:
  sta [impl_run]

Runs timing analysis on an existing Vivado implementation run.
Default impl_run is impl_1. This script does not run synthesis or implementation.
EOF
    exit 0
fi

if [[ ! -f "${PROJECT_PATH}" ]]; then
    echo "ERROR: Vivado project not found: ${PROJECT_PATH}" >&2
    exit 2
fi

if [[ ! -f "${TIMING_TCL}" ]]; then
    echo "ERROR: timing script not found: ${TIMING_TCL}" >&2
    exit 2
fi

if ! command -v vivado >/dev/null 2>&1; then
    if [[ -f /tools/Xilinx/Vivado/2024.1/settings64.sh ]]; then
        # shellcheck disable=SC1091
        source /tools/Xilinx/Vivado/2024.1/settings64.sh
    fi
fi

if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: vivado command not found. Source Vivado settings64.sh first." >&2
    exit 127
fi

mkdir -p "${VIVADO_WORK}"

RUN_TCL="$(mktemp "${TMPDIR:-/tmp}/cpu_sta_existing_impl.XXXXXX.tcl")"
trap 'rm -f "${RUN_TCL}"' EXIT

export CPU_STA_PROJECT_PATH="${PROJECT_PATH}"
export CPU_STA_TIMING_TCL="${TIMING_TCL}"
export CPU_STA_RUN_NAME="${RUN_NAME}"

cat >"${RUN_TCL}" <<'EOF'
proc fail {msg} {
    puts stderr ""
    puts stderr "ERROR: $msg"
    exit 1
}

set project_path [file normalize $::env(CPU_STA_PROJECT_PATH)]
set timing_tcl   [file normalize $::env(CPU_STA_TIMING_TCL)]
set run_name     $::env(CPU_STA_RUN_NAME)

puts "================================================================"
puts " existing implementation timing analysis"
puts "================================================================"
puts "  Project : $project_path"
puts "  Run     : $run_name"
puts "  Script  : $timing_tcl"

if {![file exists $project_path]} {
    fail "Vivado project not found: $project_path"
}
if {![file exists $timing_tcl]} {
    fail "Timing script not found: $timing_tcl"
}

if {[catch {open_project $project_path} open_project_msg]} {
    fail "open_project failed: $open_project_msg"
}

set run_objs [get_runs -quiet $run_name]
if {[llength $run_objs] == 0} {
    fail "Implementation run '$run_name' does not exist."
}

set run_obj [lindex $run_objs 0]
set status [get_property STATUS $run_obj]
set progress [get_property PROGRESS $run_obj]
set needs_refresh ""
catch {set needs_refresh [get_property NEEDS_REFRESH $run_obj]}

puts "  Status  : $status"
puts "  Progress: $progress"
if {$needs_refresh ne "" && $needs_refresh ne "0"} {
    puts "  Warning : run is marked NEEDS_REFRESH; analyzing the existing result anyway."
}

if {![regexp -nocase {complete} $status] && $progress ne "100%"} {
    fail "Implementation has not completed. Run '$run_name' first, then rerun sta."
}

if {[catch {open_run $run_name} open_run_msg]} {
    fail "open_run $run_name failed. Existing implementation result is not available: $open_run_msg"
}

source $timing_tcl
close_project
EOF

echo ">>> Running timing analysis on existing ${RUN_NAME}"
echo ">>> Log: ${VIVADO_WORK}/sta.log"
vivado -mode batch \
    -log "${VIVADO_WORK}/sta.log" \
    -journal "${VIVADO_WORK}/sta.jou" \
    -source "${RUN_TCL}"

echo ">>> Timing report: ${SCRIPT_DIR}/stage_timing_report.txt"
