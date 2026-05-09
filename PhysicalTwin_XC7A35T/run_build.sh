#!/usr/bin/env bash
set -euo pipefail

# Run from anywhere; all paths are resolved relative to this script.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"

# COE set under 02_Design/coe. Supported examples:
#   dual_issue/current
#   dual_issue/src1
# src0 is intentionally rejected by prepare_mem.py because it exceeds the
# physical DRAM working-set limit. src2 is capacity-limited/experimental.
COE_SET="${1:-dual_issue/current}"

# Vivado run parallelism. Override with: JOBS=20 ./PhysicalTwin_XC7A35T/run_build.sh
JOBS="${JOBS:-8}"

# English-only export directory for tools that cannot open the Chinese workspace path.
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/anokyai/CPU_Workspace_Artifacts/PhysicalTwin_XC7A35T}"
COE_TAG="${COE_SET//\//_}"
BIT_SRC="${PROJECT_DIR}/vivado/PhysicalTwin_XC7A35T.runs/impl_1/board_top.bit"
LTX_SRC="${PROJECT_DIR}/vivado/PhysicalTwin_XC7A35T.runs/impl_1/board_top.ltx"

cd "${PROJECT_DIR}"
vivado -mode batch -source "${PROJECT_DIR}/tcl/build_project.tcl" -tclargs "${COE_SET}" "${JOBS}"

mkdir -p "${ARTIFACT_DIR}"
cp -f "${BIT_SRC}" "${ARTIFACT_DIR}/board_top.bit"
cp -f "${BIT_SRC}" "${ARTIFACT_DIR}/board_top_${COE_TAG}.bit"

if [[ -f "${LTX_SRC}" ]]; then
  cp -f "${LTX_SRC}" "${ARTIFACT_DIR}/board_top.ltx"
  cp -f "${LTX_SRC}" "${ARTIFACT_DIR}/board_top_${COE_TAG}.ltx"
fi

echo "Exported bitstream:"
echo "  ${ARTIFACT_DIR}/board_top.bit"
echo "  ${ARTIFACT_DIR}/board_top_${COE_TAG}.bit"
