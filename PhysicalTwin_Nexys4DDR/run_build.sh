#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COE_SET="${1:-dual_issue/current}"
JOBS="${JOBS:-8}"

BIT_SRC="${PROJECT_DIR}/vivado/PhysicalTwin_Nexys4DDR.runs/impl_1/board_top.bit"

cd "${PROJECT_DIR}"
vivado -mode batch -source "${PROJECT_DIR}/tcl/build_project.tcl" -tclargs "${COE_SET}" "${JOBS}"

echo "Bitstream generated:"
echo "  ${BIT_SRC}"

