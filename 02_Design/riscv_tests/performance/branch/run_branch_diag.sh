#!/bin/bash
# ============================================================
# run_branch_diag.sh - Branch predictor diagnosis wrapper.
#
# Classification:
#   Performance / diagnosis entry. This intentionally stays outside
#   functional/run_all.sh so correctness gate semantics remain unchanged.
#
# Default:
#   bash performance/branch/run_branch_diag.sh
#       Runs focused microbenchmarks plus existing branch-oriented tests,
#       then emits branch-only summaries and heuristic findings.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$RISCV_TESTS_DIR"

WORK_DIR="$RISCV_TESTS_DIR/work"
TEST_SET="standard"
MAX_CYCLES=200000
MAX_COMMITS=0
OUT_DIR=""
BASELINE=""
NO_COMPILE=0
VERBOSE=0
BUILD_FIRST=0
RUN_COE=0
COE_TESTS="current src0 src1 src2 new_without_Mext new_with_Mext"
COE_MAX_CYCLES=0
COE_PROGRESS_CYCLES=0
COE_PARALLEL=0
CUSTOM_TESTS=()
ORIGINAL_ARGS=("$@")

MICRO_TESTS=(
    bp_s0_taken_loop
    bp_s0_not_taken_loop
    bp_s0_alternating
    bp_btb_alias_pair
    bp_wrongpath_pollution
)

EXISTING_TESTS=(
    branch_single
    branch_dual
    branch_dual_flush
    branch_fwd_matrix
    branch_dual_edge
    slot1_branch
    slot1_bp_update
    slot1_jal
    pc_align
    instbuf_stall
    bp_dual
    bp_stress
    jalr
    ras_overflow
)

usage() {
    cat <<'EOF'
Usage:
  bash performance/branch/run_branch_diag.sh [options] [rv32ui-test ...]

Options:
  --suite <name>           Test suite: minimal, existing, standard. Default: standard.
                           Positional tests override --suite.
  --max-cycles <n>         Cycle timeout for rv32ui tests. Default: 200000.
  --max-commits <n>        Optional commit-count stop for rv32ui tests. Default: 0.
  --out <dir>              Output directory. Default: work/perf/branch_diag_<timestamp>_<git>.
  --baseline <path>        Baseline run dir or summary for branch_compare.csv.
  --build                  Run utility/build_tests.sh before profiling.
  --no-compile             Reuse work/riscv_perf_simv for rv32ui profiling.
  --coe                    Also run COE programs with performance/long/run_coe_perf.sh.
  --coe-tests "<list>"     COE program list. Default: current src0 src1 src2 new_without_Mext new_with_Mext.
  --coe-max-cycles <n>     COE cycle cap. Default: 0 (run to stop_pc).
  --coe-progress-cycles <n> Print COE progress every n cycles. Default: 0.
  --coe-parallel           Run selected COE programs concurrently.
  --verbose                Print full [PERF] lines from underlying scripts.
  -h, --help               Show this help.

Outputs:
  <out>/rv32ui/summary.csv,json      Raw parse_perf output from run_perf.sh.
  <out>/coe/summary.csv,json         Optional raw COE perf output.
  <out>/branch_summary.csv,json      Branch-only derived metrics.
  <out>/branch_findings.md           Heuristic issue classification.
  <out>/branch_compare.csv           Optional baseline comparison.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --suite)
            [ $# -ge 2 ] || { echo "ERROR: --suite needs a value"; exit 1; }
            TEST_SET="$2"
            shift 2
            ;;
        --max-cycles)
            [ $# -ge 2 ] || { echo "ERROR: --max-cycles needs a value"; exit 1; }
            MAX_CYCLES="$2"
            shift 2
            ;;
        --max-commits)
            [ $# -ge 2 ] || { echo "ERROR: --max-commits needs a value"; exit 1; }
            MAX_COMMITS="$2"
            shift 2
            ;;
        --out)
            [ $# -ge 2 ] || { echo "ERROR: --out needs a value"; exit 1; }
            OUT_DIR="$2"
            shift 2
            ;;
        --baseline)
            [ $# -ge 2 ] || { echo "ERROR: --baseline needs a value"; exit 1; }
            BASELINE="$2"
            shift 2
            ;;
        --build)
            BUILD_FIRST=1
            shift
            ;;
        --no-compile)
            NO_COMPILE=1
            shift
            ;;
        --coe)
            RUN_COE=1
            shift
            ;;
        --coe-tests)
            [ $# -ge 2 ] || { echo "ERROR: --coe-tests needs a value"; exit 1; }
            COE_TESTS="$2"
            shift 2
            ;;
        --coe-max-cycles)
            [ $# -ge 2 ] || { echo "ERROR: --coe-max-cycles needs a value"; exit 1; }
            COE_MAX_CYCLES="$2"
            shift 2
            ;;
        --coe-progress-cycles)
            [ $# -ge 2 ] || { echo "ERROR: --coe-progress-cycles needs a value"; exit 1; }
            COE_PROGRESS_CYCLES="$2"
            shift 2
            ;;
        --coe-parallel)
            COE_PARALLEL=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "ERROR: unknown option: $1"
            usage
            exit 1
            ;;
        *)
            CUSTOM_TESTS+=("$1")
            shift
            ;;
    esac
done

if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --max-cycles must be a non-negative integer"
    exit 1
fi
if ! [[ "$MAX_COMMITS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --max-commits must be a non-negative integer"
    exit 1
fi
if ! [[ "$COE_MAX_CYCLES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --coe-max-cycles must be a non-negative integer"
    exit 1
fi
if ! [[ "$COE_PROGRESS_CYCLES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --coe-progress-cycles must be a non-negative integer"
    exit 1
fi

if [ "${#CUSTOM_TESTS[@]}" -gt 0 ]; then
    TESTS=("${CUSTOM_TESTS[@]}")
    TEST_SET="custom"
else
    case "$TEST_SET" in
        minimal)
            TESTS=("${MICRO_TESTS[@]}")
            ;;
        existing)
            TESTS=("${EXISTING_TESTS[@]}")
            ;;
        standard)
            TESTS=("${MICRO_TESTS[@]}" "${EXISTING_TESTS[@]}")
            ;;
        *)
            echo "ERROR: unknown suite '$TEST_SET'"
            echo "       Supported: minimal, existing, standard"
            exit 1
            ;;
    esac
fi

mkdir -p "$WORK_DIR"
GIT_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$WORK_DIR/perf/branch_diag_${TIMESTAMP}_${GIT_SHORT}"
fi
RV_OUT="$OUT_DIR/rv32ui"
COE_OUT="$OUT_DIR/coe"
mkdir -p "$OUT_DIR"

{
    printf "timestamp=%s\n" "$(date -Iseconds)"
    printf "git_commit=%s\n" "$(git rev-parse HEAD 2>/dev/null || echo nogit)"
    if [ -n "$(git status --short 2>/dev/null)" ]; then
        printf "git_dirty=1\n"
    else
        printf "git_dirty=0\n"
    fi
    printf "suite=%s\n" "$TEST_SET"
    printf "tests=%s\n" "${TESTS[*]}"
    printf "max_cycles=%s\n" "$MAX_CYCLES"
    printf "max_commits=%s\n" "$MAX_COMMITS"
    printf "baseline=%s\n" "$BASELINE"
    printf "run_coe=%s\n" "$RUN_COE"
    printf "coe_tests=%s\n" "$COE_TESTS"
    printf "%q " "$0" "${ORIGINAL_ARGS[@]}"
    printf "\n"
} > "$OUT_DIR/run_meta.env"

if [ "$BUILD_FIRST" -eq 1 ]; then
    bash utility/build_tests.sh
fi

echo "========================================================"
echo " branch predictor diagnosis"
echo "========================================================"
echo "[INFO] Suite:       $TEST_SET"
echo "[INFO] Tests:       ${TESTS[*]}"
echo "[INFO] Max cycles:  $MAX_CYCLES"
echo "[INFO] Output dir:  $OUT_DIR"
echo ""

PERF_ARGS=(
    --out "$RV_OUT"
    --max-cycles "$MAX_CYCLES"
)
if [ "$MAX_COMMITS" -gt 0 ]; then
    PERF_ARGS+=(--max-commits "$MAX_COMMITS")
fi
if [ "$NO_COMPILE" -eq 1 ]; then
    PERF_ARGS+=(--no-compile)
fi
if [ "$VERBOSE" -eq 1 ]; then
    PERF_ARGS+=(--verbose)
fi
if [ -n "$BASELINE" ]; then
    if [ -f "$BASELINE" ]; then
        PERF_ARGS+=(--baseline "$BASELINE")
    elif [ -f "$BASELINE/summary.csv" ]; then
        PERF_ARGS+=(--baseline "$BASELINE")
    elif [ -f "$BASELINE/rv32ui/summary.csv" ]; then
        PERF_ARGS+=(--baseline "$BASELINE/rv32ui/summary.csv")
    fi
fi
PERF_ARGS+=("${TESTS[@]}")

set +e
bash performance/short/run_perf.sh "${PERF_ARGS[@]}"
RV_STATUS=$?
set -e

REPORT_INPUTS=(--summary "rv32ui=$RV_OUT/summary.json")

COE_STATUS=0
if [ "$RUN_COE" -eq 1 ]; then
    read -r -a COE_ARRAY <<< "$COE_TESTS"
    COE_ARGS=(--out "$COE_OUT")
    if [ "$COE_MAX_CYCLES" -gt 0 ]; then
        COE_ARGS+=(--max-cycles "$COE_MAX_CYCLES")
    fi
    if [ "$COE_PROGRESS_CYCLES" -gt 0 ]; then
        COE_ARGS+=(--progress-cycles "$COE_PROGRESS_CYCLES")
    fi
    if [ "$COE_PARALLEL" -eq 1 ]; then
        COE_ARGS+=(--parallel)
    fi
    if [ "$NO_COMPILE" -eq 1 ]; then
        COE_ARGS+=(--no-compile)
    fi
    if [ "$VERBOSE" -eq 1 ]; then
        COE_ARGS+=(--verbose)
    fi
    COE_ARGS+=("${COE_ARRAY[@]}")

    set +e
    bash performance/long/run_coe_perf.sh "${COE_ARGS[@]}"
    COE_STATUS=$?
    set -e

    if [ -f "$COE_OUT/summary.json" ]; then
        REPORT_INPUTS+=(--summary "coe=$COE_OUT/summary.json")
    fi
fi

REPORT_ARGS=("${REPORT_INPUTS[@]}" --out "$OUT_DIR")
if [ -n "$BASELINE" ]; then
    REPORT_ARGS+=(--baseline "$BASELINE")
fi

if [ -f "$RV_OUT/summary.json" ]; then
    python3 tools/branch_diag_report.py "${REPORT_ARGS[@]}"
else
    echo "ERROR: rv32ui summary not found: $RV_OUT/summary.json"
    exit 1
fi

echo ""
echo "[INFO] Branch summary:  $OUT_DIR/branch_summary.csv"
echo "[INFO] Branch findings: $OUT_DIR/branch_findings.md"
if [ -f "$OUT_DIR/branch_compare.csv" ]; then
    echo "[INFO] Branch compare:  $OUT_DIR/branch_compare.csv"
fi

if [ "$RV_STATUS" -ne 0 ]; then
    exit "$RV_STATUS"
fi
if [ "$COE_STATUS" -ne 0 ]; then
    exit "$COE_STATUS"
fi
