#!/bin/bash
# ============================================================
# run_coe_perf.sh - Run full contest COE programs with perf counters.
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
HEX_DIR="${HEX_DIR:-$WORK_DIR/coe_hex}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
source "$RISCV_TESTS_DIR/tools/perf_output.sh"
OUT_DIR=""
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

usage() {
    cat <<'EOF'
Usage:
  bash performance/long/run_coe_perf.sh [options]

Options:
  --out <dir>             Output directory. Default: work/perf/latest/coe.
                          Existing contents are replaced before the run.
  --max-cycles <n>        Stop each program after n simulated cycles. Default: 0
                          means run until stop_pc / watchdog.
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

mkdir -p "$WORK_DIR" "$HEX_DIR"

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$WORK_DIR/perf/latest/coe"
fi
prepare_perf_output_dir "$OUT_DIR"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"

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
    $RTL_DIR/core/branch_predictor.sv
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

{
    printf "timestamp=%s\n" "$(date -Iseconds)"
    printf "git_commit=%s\n" "$(git rev-parse HEAD 2>/dev/null || echo nogit)"
    if [ -n "$(git status --short 2>/dev/null)" ]; then
        printf "git_dirty=1\n"
    else
        printf "git_dirty=0\n"
    fi
    printf "coe_root=%s\n" "$COE_ROOT"
    printf "tests=%s\n" "${TESTS[*]}"
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
} > "$OUT_DIR/run_meta.env"

git rev-parse HEAD > "$OUT_DIR/git_commit.txt" 2>/dev/null || true
git status --short > "$OUT_DIR/git_status.txt" 2>/dev/null || true
printf "%q " "$0" "${ORIGINAL_ARGS[@]}" > "$OUT_DIR/command.txt"
printf "\n" >> "$OUT_DIR/command.txt"

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
echo ""

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
        exit 1
    fi

    echo "[INFO] Compiling with VCS..."
    # shellcheck disable=SC2086
    if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_riscv_tests -Mdir="$WORK_DIR/coe_perf_vcs.csrc" -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
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

read -r -a GUARD_ARGS <<< "$SIM_GUARD_ARGS"
: > "$OUT_DIR/stop_pc.txt"

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

    printf "%s stop_pc=0x%s\n" "$test_name" "$stop_pc" >> "$OUT_DIR/stop_pc.txt"
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
            live_pattern="^\\[(PASS|FAIL|TIMEOUT|DONE|PROGRESS|PERF)\\]"
        else
            live_pattern="^\\[(PASS|FAIL|TIMEOUT|DONE|PROGRESS)\\]"
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
            grep -E "^\[(PASS|FAIL|TIMEOUT|DONE|PERF)\]" "$log_file" || true
        else
            grep -E "^\[(PASS|FAIL|TIMEOUT|DONE)\]" "$log_file" || true
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

python3 "$RISCV_TESTS_DIR/tools/parse_perf.py" --run-dir "$OUT_DIR"

echo ""
echo "[INFO] Summary CSV:  $OUT_DIR/summary.csv"
echo "[INFO] Summary JSON: $OUT_DIR/summary.json"
echo "[INFO] stop_pc map:  $OUT_DIR/stop_pc.txt"

if grep -R -E "^\[(FAIL|TIMEOUT)\]" "$LOG_DIR" >/dev/null 2>&1; then
    exit 1
fi

if grep -R -E "^\[INFO\] sim_exit=([1-9][0-9]*)" "$LOG_DIR" >/dev/null 2>&1; then
    exit 1
fi

if [ "$RUN_FAILED" -ne 0 ]; then
    exit 1
fi
