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

BIT_SRC="${PROJECT_DIR}/vivado/PhysicalTwin_XC7A35T.runs/impl_1/board_top.bit"

cd "${PROJECT_DIR}"
vivado -mode batch -source "${PROJECT_DIR}/tcl/build_project.tcl" -tclargs "${COE_SET}" "${JOBS}"

echo "Bitstream generated:"
echo "  ${BIT_SRC}"
