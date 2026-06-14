#!/bin/bash
# Full VCS functional regression with ABTB direct J/CALL steering enabled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ABTB_DIRECT_STEERING=1

if [ "$#" -eq 0 ]; then
    exec bash "$SCRIPT_DIR/run_all.sh" vcs
fi
exec bash "$SCRIPT_DIR/run_all.sh" "$@"
