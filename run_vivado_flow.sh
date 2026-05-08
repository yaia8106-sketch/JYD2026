#!/usr/bin/env bash
set -euo pipefail

# Common usage:
#   ./run_vivado_flow.sh
#       Use current COE, 20 Vivado jobs.
#
#   ./run_vivado_flow.sh src0
#   ./run_vivado_flow.sh src1
#   ./run_vivado_flow.sh src2
#       Switch to one contest COE program and run the full timing flow.
#
#   ./run_vivado_flow.sh src0 8
#       Use src0 COE and limit Vivado to 8 parallel jobs.
#
#   JOBS=12 ./run_vivado_flow.sh src1
#       Same as passing jobs as the second argument.
#
#   VIVADO_BIN=/tools/Xilinx/Vivado/2024.1/bin/vivado ./run_vivado_flow.sh src2
#       Use an explicit Vivado binary when vivado is not in PATH.
#
# Output:
#   03_Timing_Analysis/stage_timing_report.txt
#
# Workspace root and the Vivado TCL driver used by this wrapper.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_SCRIPT="${ROOT_DIR}/03_Timing_Analysis/run_vivado_flow.tcl"
VIVADO_WORK_DIR="${VIVADO_WORK_DIR:-${ROOT_DIR}/03_Timing_Analysis/vivado_work}"

# Args:
#   $1 / COE_NAME : COE program name, e.g. current/src0/src1/src2
#   $2 / JOBS     : Vivado parallel jobs for synth_1 and impl_1
COE_NAME="${1:-${COE_NAME:-current}}"
JOBS="${2:-${JOBS:-20}}"

# Vivado lookup order:
#   1. Explicit VIVADO_BIN env var
#   2. vivado in PATH
#   3. The lab machine's default Vivado 2024.1 install path
if [[ -n "${VIVADO_BIN:-}" ]]; then
    VIVADO="${VIVADO_BIN}"
elif command -v vivado >/dev/null 2>&1; then
    VIVADO="$(command -v vivado)"
elif [[ -x /tools/Xilinx/Vivado/2024.1/bin/vivado ]]; then
    VIVADO="/tools/Xilinx/Vivado/2024.1/bin/vivado"
else
    echo "ERROR: Vivado not found. Set VIVADO_BIN=/path/to/vivado" >&2
    exit 1
fi

cat <<EOF
========================================================
 Vivado flow
========================================================
  workspace : ${ROOT_DIR}
  project   : JYD2025_Contest-rv32i/digital_twin.xpr
  coe       : ${COE_NAME}
  jobs      : ${JOBS}
  vivado    : ${VIVADO}
  work dir  : ${VIVADO_WORK_DIR}
  flow      : COE/IP -> synth_1 -> impl_1 -> timing report
========================================================
EOF

mkdir -p "${VIVADO_WORK_DIR}"

# Tcl flow:
#   update COE/IP -> synth_1 -> impl_1 (no bitstream)
#   -> open_run impl_1 -> source report_stage_timing.tcl
cd "${VIVADO_WORK_DIR}"
exec "${VIVADO}" -mode tcl \
    -journal "${VIVADO_WORK_DIR}/vivado.jou" \
    -log "${VIVADO_WORK_DIR}/vivado.log" \
    -source "${TCL_SCRIPT}" \
    -tclargs "${ROOT_DIR}" "${COE_NAME}" "${JOBS}"
