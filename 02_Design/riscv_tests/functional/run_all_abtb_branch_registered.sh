#!/bin/bash
# Full VCS regression with branch steering and registered BP1 correction.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ABTB_DIRECT_STEERING=1
export ABTB_BRANCH_STEERING=1
export ABTB_BRANCH_REGISTERED_BP1_REDIRECT=1

if [ "$#" -eq 0 ]; then
    exec bash "$SCRIPT_DIR/run_all.sh" vcs
fi
exec bash "$SCRIPT_DIR/run_all.sh" "$@"
