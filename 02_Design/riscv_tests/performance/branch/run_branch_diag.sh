#!/bin/bash
# ============================================================
# run_branch_diag.sh - Branch predictor diagnosis.
#
# Classification:
#   Performance / diagnosis entry. This intentionally stays outside
#   functional/run_all.sh so correctness gate semantics remain unchanged.
#
# Direct-runner rule:
#   This script is a sibling of short-perf and coe-perf.  It compiles and runs
#   tb_riscv_tests directly; it does not wrap run_perf.sh or run_coe_perf.sh.
#
# Default:
#   bash performance/branch/run_branch_diag.sh
#       Runs focused microbenchmarks plus existing branch-oriented tests,
#       always runs every contest COE program in parallel, then emits
#       branch-only summaries and heuristic findings.
#
# The output directory is replaced at the start of each run, so it contains
# only the latest result.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$RISCV_TESTS_DIR"

WORKSPACE="$(cd "$RISCV_TESTS_DIR/../.." && pwd)"
RTL_DIR="$WORKSPACE/02_Design/rtl"
COE_ROOT="${COE_ROOT:-$WORKSPACE/02_Design/coe/dual_issue}"
WORK_DIR="$RISCV_TESTS_DIR/work"
RV_HEX_DIR="${HEX_DIR:-$RISCV_TESTS_DIR/work/hex}"
COE_HEX_DIR="${COE_HEX_DIR:-$WORK_DIR/coe_hex}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
source "$RISCV_TESTS_DIR/tools/perf_output.sh"
RV_GUARD_ARGS="${RV_GUARD_ARGS:-+pc_guard +watchdog=5000}"
COE_GUARD_ARGS="${COE_GUARD_ARGS:-+pc_guard}"

TEST_SET="standard"
MAX_CYCLES=200000
MAX_COMMITS=0
OUT_DIR=""
BASELINE=""
NO_COMPILE=0
VERBOSE=0
BUILD_FIRST=0
COE_MAX_CYCLES=0
COE_PROGRESS_CYCLES=0
COE_WATCHDOG_CYCLES="${COE_WATCHDOG_CYCLES:-150000}"
COE_STOP_ENTRY_BYTES="${COE_STOP_ENTRY_BYTES:-0x100}"
COE_PROGRAMS=(current src0 src1 src2 new_without_Mext new_with_Mext)
REQUESTED_COE_TESTS=""
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
                           Positional rv32ui tests override --suite.
  --max-cycles <n>         Cycle timeout for rv32ui tests. Default: 200000.
  --max-commits <n>        Optional commit-count stop for rv32ui tests. Default: 0.
  --out <dir>              Output directory. Default: work/perf/latest/branch_diag.
                           Existing contents are replaced before the run.
  --baseline <path>        Baseline run dir or summary for branch_compare.csv.
  --build                  Run utility/build_tests.sh before profiling.
  --no-compile             Reuse work/branch_diag_simv.
  --coe                    Accepted for compatibility; COE programs always run.
  --coe-tests "<list>"     Accepted for compatibility, but ignored. The full
                           contest set always runs: current src0 src1 src2
                           new_without_Mext new_with_Mext.
  --coe-max-cycles <n>     COE cycle cap. Default: 0 (run to stop_pc).
  --coe-progress-cycles <n> Print COE progress every n cycles. Default: 0.
  --coe-parallel           Accepted for compatibility; COE programs always run in parallel.
  --verbose                Print full [PERF] lines to the terminal.
  -h, --help               Show this help.

Outputs:
  <out>/rv32ui/summary.csv,json      Raw rv32ui perf output.
  <out>/coe/summary.csv,json         Raw COE perf output for all contest programs.
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
            shift
            ;;
        --coe-tests)
            [ $# -ge 2 ] || { echo "ERROR: --coe-tests needs a value"; exit 1; }
            REQUESTED_COE_TESTS="$2"
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
if ! [[ "$COE_WATCHDOG_CYCLES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COE_WATCHDOG_CYCLES must be a non-negative integer"
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

if [ "$BUILD_FIRST" -eq 1 ]; then
    bash utility/build_tests.sh
fi

if [ ! -d "$RV_HEX_DIR" ] || [ -z "$(ls "$RV_HEX_DIR"/*.irom.hex 2>/dev/null)" ]; then
    echo "ERROR: rv32ui hex not found. Run: bash utility/build_tests.sh"
    exit 1
fi

mkdir -p "$WORK_DIR" "$COE_HEX_DIR"

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$WORK_DIR/perf/latest/branch_diag"
fi
prepare_perf_output_dir "$OUT_DIR" "$BASELINE"
RV_OUT="$OUT_DIR/rv32ui"
COE_OUT="$OUT_DIR/coe"
RV_LOG_DIR="$RV_OUT/logs"
COE_LOG_DIR="$COE_OUT/logs"
mkdir -p "$OUT_DIR" "$RV_LOG_DIR" "$COE_LOG_DIR"

RTL_FILES="
    $RTL_DIR/common/cpu_defs.sv
    $RTL_DIR/core/if_id_reg.sv
    $RTL_DIR/core/decoder.sv
    $RTL_DIR/core/imm_gen.sv
    $RTL_DIR/core/regfile.sv
    $RTL_DIR/core/forwarding.sv
    $RTL_DIR/core/alu_src_mux.sv
    $RTL_DIR/core/id_ex_reg.sv
    $RTL_DIR/core/id_ex_reg_s1.sv
    $RTL_DIR/core/alu.sv
    $RTL_DIR/core/branch_condition.sv
    $RTL_DIR/core/id_stage_derive.sv
    $RTL_DIR/core/ex_stage_ctrl.sv
    $RTL_DIR/core/branch_unit.sv
    $RTL_DIR/core/frontend_stage1_direction.sv
    $RTL_DIR/core/frontend_abtb.sv
    $RTL_DIR/core/frontend_ftq.sv
    $RTL_DIR/core/mem_interface.sv
    $RTL_DIR/core/redirect_ctrl.sv
    $RTL_DIR/core/csr_trap_unit.sv
    $RTL_DIR/core/memory_access_unit.sv
    $RTL_DIR/core/muldiv_unit.sv
    $RTL_DIR/core/dual_issue_counter.sv
    $RTL_DIR/core/ex_mem_reg.sv
    $RTL_DIR/core/ex_mem_reg_s1.sv
    $RTL_DIR/core/mem_wb_reg.sv
    $RTL_DIR/core/mem_wb_reg_s1.sv
    $RTL_DIR/core/wb_mux.sv
    $RTL_DIR/memory/dcache.sv
    $RTL_DIR/memory/backends/dcache_bram_backend.sv
    $RTL_DIR/core/cpu_top.sv
    $RISCV_TESTS_DIR/work/dcache_data_ram.v
    $RISCV_TESTS_DIR/tb/perf_monitor.sv
    $RISCV_TESTS_DIR/tb/tb_riscv_tests.sv
"

write_meta() {
    local path="$1"
    {
        printf "timestamp=%s\n" "$(date -Iseconds)"
        printf "git_commit=%s\n" "$(git rev-parse HEAD 2>/dev/null || echo nogit)"
        if [ -n "$(git status --short 2>/dev/null)" ]; then
            printf "git_dirty=1\n"
        else
            printf "git_dirty=0\n"
        fi
        printf "suite=%s\n" "$TEST_SET"
        printf "rv32ui_tests=%s\n" "${TESTS[*]}"
        printf "coe_tests=%s\n" "${COE_PROGRAMS[*]}"
        printf "coe_parallel_jobs=%s\n" "${#COE_PROGRAMS[@]}"
        printf "max_cycles=%s\n" "$MAX_CYCLES"
        printf "max_commits=%s\n" "$MAX_COMMITS"
        printf "coe_cycle_timeout=%s\n" "$COE_MAX_CYCLES"
        printf "coe_watchdog_cycles=%s\n" "$COE_WATCHDOG_CYCLES"
        printf "coe_progress_cycles=%s\n" "$COE_PROGRESS_CYCLES"
        printf "stop_pc_source=entry_fallthrough_self_loop_0000006f\n"
        printf "stop_pc_entry_bytes=%s\n" "$COE_STOP_ENTRY_BYTES"
        printf "rv_hex_dir=%s\n" "$RV_HEX_DIR"
        printf "coe_root=%s\n" "$COE_ROOT"
        printf "coe_hex_dir=%s\n" "$COE_HEX_DIR"
        printf "sim_guard_args=%s\n" "$RV_GUARD_ARGS"
        printf "coe_guard_args=%s\n" "$COE_GUARD_ARGS"
        printf "simulator=vcs\n"
        printf "vcs_opts=%s\n" "$VCS_OPTS"
        printf "vcs_extra_opts=%s\n" "$VCS_EXTRA_OPTS"
        printf "vcs_env=%s\n" "$VCS_ENV"
        printf "baseline=%s\n" "$BASELINE"
        printf "verbose=%s\n" "$VERBOSE"
        printf "requested_coe_tests=%s\n" "$REQUESTED_COE_TESTS"
        printf "%q " "$0" "${ORIGINAL_ARGS[@]}"
        printf "\n"
    } > "$path"
}

write_meta "$OUT_DIR/run_meta.env"
write_meta "$RV_OUT/run_meta.env"
write_meta "$COE_OUT/run_meta.env"
git rev-parse HEAD > "$OUT_DIR/git_commit.txt" 2>/dev/null || true
git status --short > "$OUT_DIR/git_status.txt" 2>/dev/null || true
printf "%q " "$0" "${ORIGINAL_ARGS[@]}" > "$OUT_DIR/command.txt"
printf "\n" >> "$OUT_DIR/command.txt"

echo "========================================================"
echo " branch predictor diagnosis"
echo "========================================================"
echo "[INFO] Suite:       $TEST_SET"
echo "[INFO] RV tests:    ${TESTS[*]}"
echo "[INFO] COE tests:   ${COE_PROGRAMS[*]} (${#COE_PROGRAMS[@]} parallel jobs)"
echo "[INFO] Max cycles:  $MAX_CYCLES"
echo "[INFO] Output dir:  $OUT_DIR"
echo ""

SIM_BIN="$WORK_DIR/branch_diag_simv"
COMPILE_LOG="$OUT_DIR/branch_diag_vcs.log"
if [ "$NO_COMPILE" -eq 0 ]; then
    if ! command -v vcs >/dev/null 2>&1; then
        if [ -f "$VCS_ENV" ]; then
            # shellcheck disable=SC1090
            source "$VCS_ENV"
        fi
    fi
    if ! command -v vcs >/dev/null 2>&1; then
        echo "ERROR: vcs not found in PATH. Source Synopsys env or set VCS_ENV=<setup.sh>."
        exit 1
    fi

    echo "[INFO] Compiling branch-diag TB with VCS..."
    # shellcheck disable=SC2086
    if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_riscv_tests -Mdir="$WORK_DIR/branch_diag_vcs.csrc" -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
        echo "ERROR: VCS compilation failed"
        head -80 "$COMPILE_LOG"
        exit 1
    fi
    head -20 "$COMPILE_LOG"
    echo "[INFO] Compilation OK"
    echo ""
else
    if [ ! -f "$SIM_BIN" ]; then
        echo "ERROR: --no-compile requested but $SIM_BIN does not exist"
        exit 1
    fi
    echo "[INFO] Reusing $SIM_BIN"
    echo ""
fi

coe_to_hex() {
    local in_file="$1"
    local out_file="$2"
    awk '
        BEGIN { in_vec = 0 }
        /memory_initialization_vector/ { in_vec = 1; next }
        in_vec {
            gsub(/[ \t\r]/, "")
            sub(/;.*/, "")
            gsub(/,/, "")
            if ($0 != "") print tolower($0)
        }
    ' "$in_file" > "$out_file"
}

derive_stop_pc() {
    local slot0_hex="$1"
    local slot1_hex="$2"
    python3 "$RISCV_TESTS_DIR/tools/derive_coe_stop_pc.py" \
        --slot0 "$slot0_hex" \
        --slot1 "$slot1_hex" \
        --entry-bytes "$COE_STOP_ENTRY_BYTES"
}

read -r -a RV_GUARD_ARRAY <<< "$RV_GUARD_ARGS"
RV_STATUS=0
for test_name in "${TESTS[@]}"; do
    irom_hex="$RV_HEX_DIR/rv32ui-p-${test_name}.irom.hex"
    dram_hex="$RV_HEX_DIR/rv32ui-p-${test_name}.dram.hex"
    log_file="$RV_LOG_DIR/${test_name}.log"

    echo "========================================================"
    echo " Branch RV32UI: $test_name"
    echo "========================================================"

    if [ ! -f "$irom_hex" ] || [ ! -f "$dram_hex" ]; then
        echo "[SKIP] $test_name hex not found" | tee "$log_file"
        echo ""
        continue
    fi

    RUN_ARGS=(
        "+irom=$irom_hex"
        "+dram=$dram_hex"
        "+test=$test_name"
        "+cycles=$MAX_CYCLES"
        +perf
    )
    if [ "$MAX_COMMITS" -gt 0 ]; then
        RUN_ARGS+=("+commits=$MAX_COMMITS")
    fi
    RUN_ARGS+=("${RV_GUARD_ARRAY[@]}")

    set +e
    "$SIM_BIN" "${RUN_ARGS[@]}" > "$log_file" 2>&1
    sim_status=$?
    set -e
    printf "[INFO] sim_exit=%s\n" "$sim_status" >> "$log_file"
    if [ "$sim_status" -ne 0 ]; then
        RV_STATUS=1
    fi

    if [ "$VERBOSE" -eq 1 ]; then
        grep -E "^\[(PASS|FAIL|TIMEOUT|DONE|PERF)\]" "$log_file" || true
    else
        grep -E "^\[(PASS|FAIL|TIMEOUT|DONE|SKIP)\]" "$log_file" || true
    fi
    echo ""
done

python3 "$RISCV_TESTS_DIR/tools/parse_perf.py" --run-dir "$RV_OUT"

read -r -a COE_GUARD_ARRAY <<< "$COE_GUARD_ARGS"
: > "$COE_OUT/stop_pc.txt"
if [ -n "$REQUESTED_COE_TESTS" ]; then
    echo "[WARN] branch-diag always runs all contest COE programs; ignoring --coe-tests '$REQUESTED_COE_TESTS'"
fi

run_one_coe() {
    local test_name="$1"
    local coe_dir slot0_coe slot1_coe dram_coe
    local slot0_hex slot1_hex dram_hex log_file stop_pc
    local live_pattern sim_status

    coe_dir="$COE_ROOT/$test_name"
    slot0_coe="$coe_dir/irom_slot0.coe"
    slot1_coe="$coe_dir/irom_slot1.coe"
    dram_coe="$coe_dir/dram.coe"
    slot0_hex="$COE_HEX_DIR/$test_name.irom_slot0.hex"
    slot1_hex="$COE_HEX_DIR/$test_name.irom_slot1.hex"
    dram_hex="$COE_HEX_DIR/$test_name.dram.hex"
    log_file="$COE_LOG_DIR/$test_name.log"

    echo "========================================================"
    echo " Branch COE: $test_name"
    echo "========================================================"

    if [ ! -f "$slot0_coe" ] || [ ! -f "$slot1_coe" ] || [ ! -f "$dram_coe" ]; then
        echo "[SKIP] $test_name COE not found" | tee "$log_file"
        echo ""
        return 0
    fi

    coe_to_hex "$slot0_coe" "$slot0_hex"
    coe_to_hex "$slot1_coe" "$slot1_hex"
    coe_to_hex "$dram_coe" "$dram_hex"

    if ! stop_pc="$(derive_stop_pc "$slot0_hex" "$slot1_hex")"; then
        echo "[FAIL] $test_name stop_pc derivation failed" | tee "$log_file"
        echo ""
        return 0
    fi

    printf "%s stop_pc=0x%s\n" "$test_name" "$stop_pc" >> "$COE_OUT/stop_pc.txt"
    echo "[INFO] stop_pc:      0x$stop_pc"

    RUN_ARGS=(
        "+irom_slot0=$slot0_hex"
        "+irom_slot1=$slot1_hex"
        "+dram=$dram_hex"
        "+test=$test_name"
        "+stop_pc=$stop_pc"
        +perf
    )
    if [ "$COE_MAX_CYCLES" -gt 0 ]; then
        RUN_ARGS+=("+cycles=$COE_MAX_CYCLES")
        RUN_ARGS+=(+cycle_limit_done)
    else
        RUN_ARGS+=(+no_cycle_timeout)
    fi
    if [ "$COE_WATCHDOG_CYCLES" -gt 0 ]; then
        RUN_ARGS+=("+watchdog=$COE_WATCHDOG_CYCLES")
    fi
    if [ "$COE_PROGRESS_CYCLES" -gt 0 ]; then
        RUN_ARGS+=("+progress_cycles=$COE_PROGRESS_CYCLES")
    fi
    RUN_ARGS+=("${COE_GUARD_ARRAY[@]}")

    set +e
    if [ "$COE_PROGRESS_CYCLES" -gt 0 ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            live_pattern="^\\[(PASS|FAIL|TIMEOUT|DONE|SAMPLED|PROGRESS|PERF)\\]"
        else
            live_pattern="^\\[(PASS|FAIL|TIMEOUT|DONE|SAMPLED|PROGRESS)\\]"
        fi
        "$SIM_BIN" "${RUN_ARGS[@]}" 2>&1 | tee "$log_file" | grep --line-buffered -E "$live_pattern"
        pipe_status=("${PIPESTATUS[@]}")
        sim_status=${pipe_status[0]}
    else
        "$SIM_BIN" "${RUN_ARGS[@]}" > "$log_file" 2>&1
        sim_status=$?
    fi
    set -e
    printf "[INFO] sim_exit=%s\n" "$sim_status" >> "$log_file"

    if [ "$COE_PROGRESS_CYCLES" -eq 0 ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            grep -E "^\[(PASS|FAIL|TIMEOUT|DONE|SAMPLED|PERF)\]" "$log_file" || true
        else
            grep -E "^\[(PASS|FAIL|TIMEOUT|DONE|SAMPLED|SKIP)\]" "$log_file" || true
        fi
    fi
    echo ""
    return "$sim_status"
}

COE_STATUS=0
PIDS=()
for test_name in "${COE_PROGRAMS[@]}"; do
    run_one_coe "$test_name" &
    PIDS+=("$!")
done
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        COE_STATUS=1
    fi
done

python3 "$RISCV_TESTS_DIR/tools/parse_perf.py" --run-dir "$COE_OUT"

REPORT_INPUTS=(--summary "rv32ui=$RV_OUT/summary.json" --summary "coe=$COE_OUT/summary.json")
REPORT_ARGS=("${REPORT_INPUTS[@]}" --out "$OUT_DIR")
if [ -n "$BASELINE" ]; then
    REPORT_ARGS+=(--baseline "$BASELINE")
fi
python3 "$RISCV_TESTS_DIR/tools/branch_diag_report.py" "${REPORT_ARGS[@]}"

echo ""
echo "[INFO] RV summary:       $RV_OUT/summary.csv"
echo "[INFO] COE summary:      $COE_OUT/summary.csv"
echo "[INFO] Branch summary:   $OUT_DIR/branch_summary.csv"
echo "[INFO] Branch findings:  $OUT_DIR/branch_findings.md"
if [ -f "$OUT_DIR/branch_compare.csv" ]; then
    echo "[INFO] Branch compare:   $OUT_DIR/branch_compare.csv"
fi

if grep -R -E "^\[(FAIL|TIMEOUT)\]" "$RV_LOG_DIR" "$COE_LOG_DIR" >/dev/null 2>&1; then
    exit 1
fi
if grep -R -E "^\[INFO\] sim_exit=([1-9][0-9]*)" "$RV_LOG_DIR" "$COE_LOG_DIR" >/dev/null 2>&1; then
    exit 1
fi
if [ "$RV_STATUS" -ne 0 ]; then
    exit "$RV_STATUS"
fi
if [ "$COE_STATUS" -ne 0 ]; then
    exit "$COE_STATUS"
fi
