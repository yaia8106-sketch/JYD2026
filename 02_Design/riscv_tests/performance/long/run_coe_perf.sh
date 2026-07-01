#!/bin/bash
# ============================================================
# run_coe_perf.sh - Run full contest COE programs with general and branch reports.
#
# Classification:
#   Performance / long-run / COE entry. Do not use this as a default smoke
#   gate unless the user explicitly asks for COE-level validation.
#
# Full COE runs always cover every contest program and run them in parallel,
# one simv process per program.  Each program must end by its real stop_pc.
# This script derives stop_pc from the entry fall-through self-loop
# (jal x0, 0 / 0000006f) after startup calls. By default it runs until stop_pc;
# --max-cycles can cap each program for sampled profiling.
#
# Default output is written to a timestamped run directory first.  The
# latest/coe pointer is updated only after the run is validated.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$RISCV_TESTS_DIR"

WORKSPACE="$(cd "$RISCV_TESTS_DIR/../.." && pwd)"
RTL_DIR="$WORKSPACE/02_Design/rtl"
COE_ROOT="${COE_ROOT:-$WORKSPACE/02_Design/coe/dual_issue}"
WORK_DIR="$RISCV_TESTS_DIR/work"
HEX_DIR="${HEX_DIR:-$WORK_DIR/coe_hex}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
source "$RISCV_TESTS_DIR/tools/perf_output.sh"
OUT_DIR=""
FINAL_OUT_DIR=""
UPDATE_LATEST=0
NO_COMPILE=0
VERBOSE=0
MAX_CYCLES="${MAX_CYCLES:-0}"
WATCHDOG_CYCLES="${WATCHDOG_CYCLES:-150000}"
PROGRESS_CYCLES="${PROGRESS_CYCLES:-0}"
SIM_GUARD_ARGS="${SIM_GUARD_ARGS:-+pc_guard}"
COE_STOP_ENTRY_BYTES="${COE_STOP_ENTRY_BYTES:-0x100}"
CONTEST_PROGRAMS=(current src0 src1 src2 new_without_Mext new_with_Mext)
REQUESTED_TESTS=()
TESTS=("${CONTEST_PROGRAMS[@]}")
ORIGINAL_ARGS=("$@")
RUN_ID="$(date +%Y%m%d_%H%M%S)"
START_TIMESTAMP="$(date -Iseconds)"
RUN_STATUS_FILE=""
RUN_RESULT="running"
SAMPLE_MODE=0
declare -A STOP_PC_BY_TEST

usage() {
    cat <<'EOF'
Usage:
  bash performance/long/run_coe_perf.sh [options]

Options:
  --out <dir>             Output directory. Default: work/perf/latest/coe.
                          Default latest is updated only after a validated run.
  --max-cycles <n>        Stop each program after n simulated cycles. Default: 0
                          means run until stop_pc / watchdog. Nonzero values
                          produce sampled, not full-run, data.
  --progress-cycles <n>   Print [PROGRESS] every n simulated cycles. Default: 0 (disabled).
                          Can also be set with PROGRESS_CYCLES=<n>.
  --parallel              Accepted for compatibility; COE programs always run in parallel.
  --no-compile            Reuse work/coe_perf_simv.
  --verbose               Print full [PERF] lines to the terminal.
  -h, --help              Show this help.

Programs always run as the full contest set:
  current src0 src1 src2 new_without_Mext new_with_Mext

Parallel jobs always equal the contest program count.

Normal completion is stop_pc unless --max-cycles is set. Watchdog is an
idle-progress guard, not a duration limit.

Outputs include the general summary plus branch-predictor-focused reports:
  summary.csv,json        All parsed performance counters.
  branch_summary.csv,json Branch prediction counters and derived metrics.
  branch_findings.md      Heuristic branch prediction diagnosis.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            [ $# -ge 2 ] || { echo "ERROR: --out needs a value"; exit 1; }
            OUT_DIR="$2"
            shift 2
            ;;
        --no-compile)
            NO_COMPILE=1
            shift
            ;;
        --parallel)
            shift
            ;;
        --max-cycles)
            [ $# -ge 2 ] || { echo "ERROR: --max-cycles needs a value"; exit 1; }
            MAX_CYCLES="$2"
            shift 2
            ;;
        --progress-cycles)
            [ $# -ge 2 ] || { echo "ERROR: --progress-cycles needs a value"; exit 1; }
            PROGRESS_CYCLES="$2"
            shift 2
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
            REQUESTED_TESTS+=("$1")
            shift
            ;;
    esac
done

if [ "${#REQUESTED_TESTS[@]}" -gt 0 ]; then
    echo "[WARN] coe-perf always runs all contest programs; ignoring explicit program list: ${REQUESTED_TESTS[*]}"
fi

if ! [[ "$PROGRESS_CYCLES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --progress-cycles / PROGRESS_CYCLES must be a non-negative integer"
    exit 1
fi
if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --max-cycles / MAX_CYCLES must be a non-negative integer"
    exit 1
fi
if [ "$MAX_CYCLES" -gt 0 ]; then
    SAMPLE_MODE=1
fi

mkdir -p "$WORK_DIR" "$HEX_DIR"

DEFAULT_OUT_DIR="$WORK_DIR/perf/latest/coe"
if [ -z "$OUT_DIR" ]; then
    FINAL_OUT_DIR="$DEFAULT_OUT_DIR"
    OUT_DIR="$WORK_DIR/perf/runs/coe/$RUN_ID"
    UPDATE_LATEST=1
elif [ "$(realpath -m -- "$OUT_DIR")" = "$(realpath -m -- "$DEFAULT_OUT_DIR")" ]; then
    FINAL_OUT_DIR="$DEFAULT_OUT_DIR"
    OUT_DIR="$WORK_DIR/perf/runs/coe/$RUN_ID"
    UPDATE_LATEST=1
else
    FINAL_OUT_DIR="$OUT_DIR"
    UPDATE_LATEST=0
    prepare_perf_output_dir "$OUT_DIR"
fi
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"

write_run_status() {
    local status="$1"
    local complete="$2"
    local exit_code="${3:-0}"

    [ -n "$RUN_STATUS_FILE" ] || return 0
    {
        printf "run_id=%s\n" "$RUN_ID"
        printf "start_timestamp=%s\n" "$START_TIMESTAMP"
        printf "end_timestamp=%s\n" "$(date -Iseconds)"
        printf "status=%s\n" "$status"
        printf "complete=%s\n" "$complete"
        printf "sampled=%s\n" "$SAMPLE_MODE"
        printf "exit_code=%s\n" "$exit_code"
        printf "out_dir=%s\n" "$OUT_DIR"
        printf "final_out_dir=%s\n" "$FINAL_OUT_DIR"
        printf "tests=%s\n" "${TESTS[*]}"
    } > "$RUN_STATUS_FILE"
}

on_exit() {
    local code=$?
    if [ "$RUN_RESULT" = "running" ]; then
        write_run_status "aborted" 0 "$code"
    fi
}
trap on_exit EXIT

RUN_STATUS_FILE="$OUT_DIR/run_status.env"
write_run_status "running" 0 0

publish_latest() {
    local latest_parent tmp_link target_rel

    [ "$UPDATE_LATEST" -eq 1 ] || return 0
    latest_parent="$(dirname "$FINAL_OUT_DIR")"
    mkdir -p "$latest_parent"
    tmp_link="$latest_parent/.coe_latest_${RUN_ID}_$$"
    target_rel="$(realpath --relative-to="$latest_parent" "$OUT_DIR" 2>/dev/null || realpath -m -- "$OUT_DIR")"
    ln -sfn "$target_rel" "$tmp_link"
    rm -rf -- "$FINAL_OUT_DIR"
    mv -Tf "$tmp_link" "$FINAL_OUT_DIR"
}

hash_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file"
    else
        shasum -a 256 "$file"
    fi
}

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

RTL_FILES="
    -F $RTL_DIR/filelists/cpu_blocks.f
    -F $RTL_DIR/filelists/dcache_bram.f
    $RTL_DIR/core/cpu_top.sv
    $RISCV_TESTS_DIR/work/dcache_data_ram.v
    $RISCV_TESTS_DIR/tb/perf_monitor.sv
    $RISCV_TESTS_DIR/tb/tb_riscv_tests.sv
"

{
    printf "run_id=%s\n" "$RUN_ID"
    printf "timestamp=%s\n" "$START_TIMESTAMP"
    printf "git_commit=%s\n" "$(git rev-parse HEAD 2>/dev/null || echo nogit)"
    if [ -n "$(git status --short 2>/dev/null)" ]; then
        printf "git_dirty=1\n"
    else
        printf "git_dirty=0\n"
    fi
    printf "coe_root=%s\n" "$COE_ROOT"
    printf "tests=%s\n" "${TESTS[*]}"
    printf "sampled=%s\n" "$SAMPLE_MODE"
    printf "stop_pc_source=entry_fallthrough_self_loop_0000006f\n"
    printf "stop_pc_entry_bytes=%s\n" "$COE_STOP_ENTRY_BYTES"
    if [ "$MAX_CYCLES" -gt 0 ]; then
        printf "cycle_timeout=%s\n" "$MAX_CYCLES"
    else
        printf "cycle_timeout=disabled\n"
    fi
    printf "watchdog_cycles=%s\n" "$WATCHDOG_CYCLES"
    printf "progress_cycles=%s\n" "$PROGRESS_CYCLES"
    printf "parallel=1\n"
    printf "parallel_jobs=%s\n" "${#TESTS[@]}"
    printf "sim_guard_args=%s\n" "$SIM_GUARD_ARGS"
    printf "simulator=vcs\n"
    printf "vcs_opts=%s\n" "$VCS_OPTS"
    printf "vcs_extra_opts=%s\n" "$VCS_EXTRA_OPTS"
    printf "vcs_env=%s\n" "$VCS_ENV"
    printf "verbose=%s\n" "$VERBOSE"
    printf "out_dir=%s\n" "$OUT_DIR"
    printf "final_out_dir=%s\n" "$FINAL_OUT_DIR"
} > "$OUT_DIR/run_meta.env"

printf "%s\n" "${TESTS[@]}" > "$OUT_DIR/expected_tests.txt"
git rev-parse HEAD > "$OUT_DIR/git_commit.txt" 2>/dev/null || true
git status --short > "$OUT_DIR/git_status.txt" 2>/dev/null || true
git diff --stat > "$OUT_DIR/git_diff_stat.txt" 2>/dev/null || true
git diff > "$OUT_DIR/git_diff.patch" 2>/dev/null || true
printf "%q " "$0" "${ORIGINAL_ARGS[@]}" > "$OUT_DIR/command.txt"
printf "\n" >> "$OUT_DIR/command.txt"

preflight_coe_inputs() {
    local test_name coe_dir slot0_coe slot1_coe dram_coe
    local slot0_hex slot1_hex dram_hex stop_pc
    local failures=0

    : > "$OUT_DIR/stop_pc.txt"
    : > "$OUT_DIR/coe_inputs.sha256"
    : > "$OUT_DIR/coe_inputs.stat"

    for test_name in "${TESTS[@]}"; do
        coe_dir="$COE_ROOT/$test_name"
        slot0_coe="$coe_dir/irom_slot0.coe"
        slot1_coe="$coe_dir/irom_slot1.coe"
        dram_coe="$coe_dir/dram.coe"
        slot0_hex="$HEX_DIR/$test_name.irom_slot0.hex"
        slot1_hex="$HEX_DIR/$test_name.irom_slot1.hex"
        dram_hex="$HEX_DIR/$test_name.dram.hex"

        if [ ! -f "$slot0_coe" ] || [ ! -f "$slot1_coe" ] || [ ! -f "$dram_coe" ]; then
            echo "[ERROR] $test_name COE not found"
            printf "%s missing\n" "$test_name" > "$LOG_DIR/$test_name.log"
            failures=1
            continue
        fi

        coe_to_hex "$slot0_coe" "$slot0_hex"
        coe_to_hex "$slot1_coe" "$slot1_hex"
        coe_to_hex "$dram_coe" "$dram_hex"

        if ! stop_pc="$(derive_stop_pc "$slot0_hex" "$slot1_hex")"; then
            echo "[ERROR] $test_name stop_pc derivation failed"
            printf "[FAIL] %s stop_pc derivation failed\n" "$test_name" > "$LOG_DIR/$test_name.log"
            failures=1
            continue
        fi

        STOP_PC_BY_TEST["$test_name"]="$stop_pc"
        printf "%s stop_pc=0x%s\n" "$test_name" "$stop_pc" >> "$OUT_DIR/stop_pc.txt"
        hash_file "$slot0_coe" >> "$OUT_DIR/coe_inputs.sha256"
        hash_file "$slot1_coe" >> "$OUT_DIR/coe_inputs.sha256"
        hash_file "$dram_coe" >> "$OUT_DIR/coe_inputs.sha256"
        stat --printf '%n size=%s mtime=%Y\n' "$slot0_coe" "$slot1_coe" "$dram_coe" >> "$OUT_DIR/coe_inputs.stat" 2>/dev/null || true
    done

    return "$failures"
}

echo "========================================================"
echo " full COE performance profiling"
echo "========================================================"
echo "[INFO] COE root:       $COE_ROOT"
echo "[INFO] Tests:          ${TESTS[*]}"
if [ "$MAX_CYCLES" -gt 0 ]; then
    echo "[INFO] Cycle timeout:  $MAX_CYCLES cycles"
else
    echo "[INFO] Cycle timeout:  disabled"
fi
echo "[INFO] Watchdog:       $WATCHDOG_CYCLES idle cycles"
if [ "$PROGRESS_CYCLES" -gt 0 ]; then
    echo "[INFO] Progress:       every $PROGRESS_CYCLES cycles"
else
    echo "[INFO] Progress:       disabled"
fi
echo "[INFO] Parallel:       enabled (${#TESTS[@]} sim jobs)"
echo "[INFO] Output dir:     $OUT_DIR"
if [ "$UPDATE_LATEST" -eq 1 ]; then
    echo "[INFO] Latest target:  $FINAL_OUT_DIR"
fi
echo ""

if ! preflight_coe_inputs; then
    write_run_status "input_error" 0 1
    RUN_RESULT="failed"
    exit 1
fi

SIM_BIN="$WORK_DIR/coe_perf_simv"
COMPILE_LOG="$OUT_DIR/coe_perf_vcs.log"
if [ "$NO_COMPILE" -eq 0 ]; then
    if ! command -v vcs >/dev/null 2>&1; then
        if [ -f "$VCS_ENV" ]; then
            # shellcheck disable=SC1090
            source "$VCS_ENV"
        fi
    fi
    if ! command -v vcs >/dev/null 2>&1; then
        echo "ERROR: vcs not found in PATH. Source Synopsys env or set VCS_ENV=<setup.sh>."
        write_run_status "compile_env_error" 0 1
        RUN_RESULT="failed"
        exit 1
    fi

    echo "[INFO] Compiling with VCS..."
    # shellcheck disable=SC2086
    if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_riscv_tests -Mdir="$WORK_DIR/coe_perf_vcs.csrc" -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
        echo "ERROR: VCS compilation failed"
        head -80 "$COMPILE_LOG"
        write_run_status "compile_failed" 0 1
        RUN_RESULT="failed"
        exit 1
    fi
    head -20 "$COMPILE_LOG"
    echo "[INFO] Compilation OK"
    echo ""
else
    if [ ! -f "$SIM_BIN" ]; then
        echo "ERROR: --no-compile requested but $SIM_BIN does not exist"
        write_run_status "missing_sim_binary" 0 1
        RUN_RESULT="failed"
        exit 1
    fi
    echo "[WARN] Reusing existing simulator binary with --no-compile: $SIM_BIN"
    echo ""
fi

{
    printf "sim_bin=%s\n" "$SIM_BIN"
    stat --printf 'sim_bin_size=%s\nsim_bin_mtime=%Y\n' "$SIM_BIN" 2>/dev/null || true
    if command -v sha256sum >/dev/null 2>&1; then
        printf "sim_bin_sha256=%s\n" "$(sha256sum "$SIM_BIN" | awk '{print $1}')"
    else
        printf "sim_bin_sha256=%s\n" "$(shasum -a 256 "$SIM_BIN" | awk '{print $1}')"
    fi
    printf "no_compile=%s\n" "$NO_COMPILE"
} > "$OUT_DIR/sim_binary.env"

read -r -a GUARD_ARGS <<< "$SIM_GUARD_ARGS"

run_one_test() {
    local test_name="$1"
    local coe_dir slot0_coe slot1_coe dram_coe
    local slot0_hex slot1_hex dram_hex log_file stop_pc
    local live_pattern sim_status

    coe_dir="$COE_ROOT/$test_name"
    slot0_coe="$coe_dir/irom_slot0.coe"
    slot1_coe="$coe_dir/irom_slot1.coe"
    dram_coe="$coe_dir/dram.coe"
    slot0_hex="$HEX_DIR/$test_name.irom_slot0.hex"
    slot1_hex="$HEX_DIR/$test_name.irom_slot1.hex"
    dram_hex="$HEX_DIR/$test_name.dram.hex"
    log_file="$LOG_DIR/$test_name.log"

    echo "========================================================"
    echo " COE Profiling: $test_name"
    echo "========================================================"

    stop_pc="${STOP_PC_BY_TEST[$test_name]:-}"
    if [ -z "$stop_pc" ]; then
        echo "[FAIL] $test_name stop_pc missing after preflight" | tee "$log_file"
        echo ""
        return 1
    fi

    echo "[INFO] stop_pc:      0x$stop_pc"

    RUN_ARGS=(
        "+irom_slot0=$slot0_hex"
        "+irom_slot1=$slot1_hex"
        "+dram=$dram_hex"
        "+test=$test_name"
        "+stop_pc=$stop_pc"
        +perf
    )
    if [ "$MAX_CYCLES" -gt 0 ]; then
        RUN_ARGS+=("+cycles=$MAX_CYCLES")
        RUN_ARGS+=(+cycle_limit_done)
    else
        RUN_ARGS+=(+no_cycle_timeout)
    fi
    if [ "$WATCHDOG_CYCLES" -gt 0 ]; then
        RUN_ARGS+=("+watchdog=$WATCHDOG_CYCLES")
    fi
    if [ "$PROGRESS_CYCLES" -gt 0 ]; then
        RUN_ARGS+=("+progress_cycles=$PROGRESS_CYCLES")
    fi
    RUN_ARGS+=("${GUARD_ARGS[@]}")

    set +e
    if [ "$PROGRESS_CYCLES" -gt 0 ]; then
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

    if [ "$PROGRESS_CYCLES" -eq 0 ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            grep -E "^\[(PASS|FAIL|TIMEOUT|DONE|SAMPLED|PERF)\]" "$log_file" || true
        else
            grep -E "^\[(PASS|FAIL|TIMEOUT|DONE|SAMPLED)\]" "$log_file" || true
        fi
    fi
    echo ""
    return "$sim_status"
}

RUN_FAILED=0
PIDS=()
for test_name in "${TESTS[@]}"; do
    run_one_test "$test_name" &
    PIDS+=("$!")
done
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        RUN_FAILED=1
    fi
done

PARSER_ARGS=(--run-dir "$OUT_DIR" --expected-tests-file "$OUT_DIR/expected_tests.txt")
if [ "$SAMPLE_MODE" -eq 0 ]; then
    PARSER_ARGS+=(--require-complete)
fi
if ! python3 "$RISCV_TESTS_DIR/tools/parse_perf.py" "${PARSER_ARGS[@]}"; then
    RUN_FAILED=1
fi

if [ -f "$OUT_DIR/summary.json" ]; then
    if ! python3 "$RISCV_TESTS_DIR/tools/branch_diag_report.py" \
        --summary "coe=$OUT_DIR/summary.json" \
        --out "$OUT_DIR"; then
        RUN_FAILED=1
    fi
else
    echo "ERROR: cannot generate branch report without $OUT_DIR/summary.json"
    RUN_FAILED=1
fi

echo ""
echo "[INFO] Summary CSV:       $OUT_DIR/summary.csv"
echo "[INFO] Summary JSON:      $OUT_DIR/summary.json"
echo "[INFO] Branch summary:    $OUT_DIR/branch_summary.csv"
echo "[INFO] Branch findings:   $OUT_DIR/branch_findings.md"
echo "[INFO] Manifest:          $OUT_DIR/manifest.json"
echo "[INFO] stop_pc map:       $OUT_DIR/stop_pc.txt"

if grep -R -E "^\[(FAIL|TIMEOUT|SKIP)\]" "$LOG_DIR" >/dev/null 2>&1; then
    RUN_FAILED=1
fi

if grep -R -E "^\[INFO\] sim_exit=([1-9][0-9]*)" "$LOG_DIR" >/dev/null 2>&1; then
    RUN_FAILED=1
fi

if [ "$RUN_FAILED" -ne 0 ]; then
    write_run_status "failed" 0 1
    RUN_RESULT="failed"
    exit 1
fi

if [ "$SAMPLE_MODE" -eq 1 ]; then
    write_run_status "sampled" 0 0
    RUN_RESULT="sampled"
else
    if ! publish_latest; then
        write_run_status "publish_failed" 0 1
        RUN_RESULT="failed"
        exit 1
    fi
    write_run_status "complete" 1 0
    RUN_RESULT="complete"
    if [ "$UPDATE_LATEST" -eq 1 ]; then
        echo "[INFO] Latest updated: $FINAL_OUT_DIR -> $OUT_DIR"
    fi
fi
