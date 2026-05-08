#!/usr/bin/env bash
set -euo pipefail

# Run from anywhere; all paths are resolved relative to this script.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"

# COE set under 02_Design/coe. Examples:
#   dual_issue/current
#   dual_issue/src0
#   dual_issue/src1
#   dual_issue/src2
COE_SET="${1:-dual_issue/current}"

# Vivado run parallelism. Override with: JOBS=20 ./PhysicalTwin_XC7A35T/run_build.sh
JOBS="${JOBS:-8}"

cd "${PROJECT_DIR}"
vivado -mode batch -source "${PROJECT_DIR}/tcl/build_project.tcl" -tclargs "${COE_SET}" "${JOBS}"
