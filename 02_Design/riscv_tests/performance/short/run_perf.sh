#!/bin/bash
# ============================================================
# run_perf.sh - Run lightweight performance profiling.
#
# Classification:
#   Performance / profiling entry. Do not use this script as the functional
#   correctness smoke gate; use run_all.sh / AXI smoke scripts for that.
#
# Short default:
#   bash performance/short/run_perf.sh
#       Runs a small profiling sanity set only: simple dual_alu.
#
# Examples:
#   bash performance/short/run_perf.sh --set focused
#   bash performance/short/run_perf.sh --set branch --max-cycles 200000
#   bash performance/short/run_perf.sh --set branch_diag --max-cycles 200000
#   bash performance/short/run_perf.sh --out work/perf/my_run simple dual_alu
#   bash performance/short/run_perf.sh --baseline work/perf/baseline
#
# Outputs:
#   work/perf/latest/short/
#       logs/<test>.log
#       summary.csv
#       summary.json
#       run_meta.env
#       git_commit.txt
#       git_status.txt
#
# The output directory is replaced at the start of each run, so it contains
# only the latest result.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$RISCV_TESTS_DIR"

RTL_DIR="$(cd "$RISCV_TESTS_DIR/../rtl" && pwd)"
HEX_DIR="${HEX_DIR:-$RISCV_TESTS_DIR/work/hex}"
WORK_DIR="$RISCV_TESTS_DIR/work"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -timescale=1ns/1ps}"
VCS_EXTRA_OPTS="${VCS_EXTRA_OPTS:-}"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"
VCS_SHIM="$RISCV_TESTS_DIR/tools/vcs_pthread_yield.c"
source "$RISCV_TESTS_DIR/tools/perf_output.sh"

TEST_SET="smoke"
MAX_CYCLES=50000
MAX_COMMITS=0
OUT_DIR=""
NO_COMPILE=0
BASELINE=""
CUSTOM_TESTS=()
SIM_GUARD_ARGS="${SIM_GUARD_ARGS:-+pc_guard +watchdog=5000}"
ORIGINAL_ARGS=("$@")
VERBOSE=0

usage() {
    cat <<'EOF'
Usage:
  bash performance/short/run_perf.sh [options] [test ...]

Options:
  --set <name>         Profiling set: smoke, focused, branch, branch_diag,
                       cache, dual, all.
                       Default: smoke. This is a profiling sanity set, not the
                       functional correctness gate.
  --max-cycles <n>     Cycle timeout passed to the testbench. Default: 50000.
  --max-commits <n>    Optional commit-count stop. Default: 0 (disabled).
  --out <dir>          Output directory. Default: work/perf/latest/short.
                       Existing contents are replaced before the run.
  --baseline <path>    Baseline run directory or summary.csv for comparison.
  --no-compile         Reuse work/riscv_perf_simv.
  --verbose            Print full [PERF] lines to the terminal.
  -h, --help           Show this help.

Positional test names override --set.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --set)
            [ $# -ge 2 ] || { echo "ERROR: --set needs a value"; exit 1; }
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
        --no-compile)
            NO_COMPILE=1
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

set_tests_from_set() {
    case "$1" in
        smoke)
            TESTS=(simple dual_alu)
            ;;
        focused)
            TESTS=(bp_stress dcache_stress axi_backend_stress dcache_wna_edge counter_stress sb_stress)
            ;;
        branch)
            TESTS=(bp_stress bp_dual branch_dual_edge slot1_bp_update)
            ;;
        branch_diag)
            TESTS=(bp_s0_taken_loop
                   bp_s0_not_taken_loop
                   bp_s0_alternating
                   bp_btb_alias_pair
                   bp_wrongpath_pollution
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
                   ras_overflow)
            ;;
        cache)
            TESTS=(dcache_stress axi_backend_stress dcache_dual dcache_wna_edge counter_stress sb_stress)
            ;;
        dual)
            TESTS=(dual_alu raw_block loaduse_dual fwd_s1 slot1_load slot1_store)
            ;;
        all)
            TESTS=(simple
                   add addi sub
                   and andi or ori xor xori
                   sll slli srl srli sra srai
                   slt slti sltiu sltu
                   beq bne blt bge bltu bgeu
                   jal jalr
                   lui auipc
                   lb lbu lh lhu lw
                   sb sh sw
                   ld_st st_ld
                   dcache_stress axi_backend_stress counter_stress bp_stress
                   dual_alu raw_block branch_single branch_dual branch_dual_flush
                   branch_fwd_matrix branch_dual_edge slot1_branch waw loaduse_dual
                   inst_buffer fwd_s1 waw_fwd flush_instbuf pc_align loaduse_cross
                   slot1_load slot1_store slot1_jal lui_auipc_s1
                   dcache_dual dcache_wna_edge instbuf_stall bp_dual slot1_bp_update
                   sb_stress ras_overflow m_ext
                   zicsr_basic zicsr_edge csr_forwarding csr_trap_stall
                   trap_mret trap_slot1 trap_flush trap_nested)
            ;;
        *)
            echo "ERROR: unknown test set '$1'"
            echo "       Supported: smoke, focused, branch, branch_diag, cache, dual, all"
            exit 1
            ;;
    esac
}

if [ "${#CUSTOM_TESTS[@]}" -gt 0 ]; then
    TEST_SET="custom"
    TESTS=("${CUSTOM_TESTS[@]}")
else
    set_tests_from_set "$TEST_SET"
fi

if [ ! -d "$HEX_DIR" ] || [ -z "$(ls "$HEX_DIR"/*.irom.hex 2>/dev/null)" ]; then
    echo "ERROR: hex not found. Run: bash utility/build_tests.sh"
    exit 1
fi

mkdir -p "$WORK_DIR"

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$WORK_DIR/perf/latest/short"
fi
prepare_perf_output_dir "$OUT_DIR" "$BASELINE"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"

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

{
    printf "timestamp=%s\n" "$(date -Iseconds)"
    printf "git_commit=%s\n" "$(git rev-parse HEAD 2>/dev/null || echo nogit)"
    if [ -n "$(git status --short 2>/dev/null)" ]; then
        printf "git_dirty=1\n"
    else
        printf "git_dirty=0\n"
    fi
    printf "test_set=%s\n" "$TEST_SET"
    printf "tests=%s\n" "${TESTS[*]}"
    printf "max_cycles=%s\n" "$MAX_CYCLES"
    printf "max_commits=%s\n" "$MAX_COMMITS"
    printf "sim_guard_args=%s\n" "$SIM_GUARD_ARGS"
    printf "simulator=vcs\n"
    printf "vcs_opts=%s\n" "$VCS_OPTS"
    printf "vcs_extra_opts=%s\n" "$VCS_EXTRA_OPTS"
    printf "vcs_env=%s\n" "$VCS_ENV"
    printf "baseline=%s\n" "$BASELINE"
    printf "verbose=%s\n" "$VERBOSE"
} > "$OUT_DIR/run_meta.env"

git rev-parse HEAD > "$OUT_DIR/git_commit.txt" 2>/dev/null || true
git status --short > "$OUT_DIR/git_status.txt" 2>/dev/null || true
printf "%q " "$0" "${ORIGINAL_ARGS[@]}" > "$OUT_DIR/command.txt"
printf "\n" >> "$OUT_DIR/command.txt"

echo "========================================================"
echo " riscv-tests performance profiling"
echo "========================================================"
echo "[INFO] Test set:     $TEST_SET"
echo "[INFO] Tests:        ${TESTS[*]}"
echo "[INFO] Max cycles:   $MAX_CYCLES"
echo "[INFO] Max commits:  $MAX_COMMITS"
echo "[INFO] Output dir:   $OUT_DIR"
echo ""

SIM_BIN="$WORK_DIR/riscv_perf_simv"
COMPILE_LOG="$OUT_DIR/riscv_perf_vcs.log"
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
    if ! vcs $VCS_OPTS $VCS_EXTRA_OPTS -top tb_riscv_tests -Mdir="$WORK_DIR/riscv_perf_vcs.csrc" -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
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

for test_name in "${TESTS[@]}"; do
    irom_hex="$HEX_DIR/rv32ui-p-${test_name}.irom.hex"
    dram_hex="$HEX_DIR/rv32ui-p-${test_name}.dram.hex"
    log_file="$LOG_DIR/${test_name}.log"

    echo "========================================================"
    echo " Profiling: $test_name"
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
    RUN_ARGS+=("${GUARD_ARGS[@]}")

    set +e
    "$SIM_BIN" "${RUN_ARGS[@]}" > "$log_file" 2>&1
    sim_status=$?
    set -e
    printf "[INFO] sim_exit=%s\n" "$sim_status" >> "$log_file"

    if [ "$VERBOSE" -eq 1 ]; then
        grep -E "^\[(PASS|FAIL|TIMEOUT|DONE|PERF)\]" "$log_file" || true
    else
        grep -E "^\[(PASS|FAIL|TIMEOUT|DONE)\]" "$log_file" || true
    fi
    echo ""
done

PARSER_ARGS=(--run-dir "$OUT_DIR")
if [ -n "$BASELINE" ]; then
    PARSER_ARGS+=(--baseline "$BASELINE")
fi

python3 "$RISCV_TESTS_DIR/tools/parse_perf.py" "${PARSER_ARGS[@]}"

echo ""
echo "[INFO] Summary CSV:  $OUT_DIR/summary.csv"
echo "[INFO] Summary JSON: $OUT_DIR/summary.json"
if [ -f "$OUT_DIR/compare.csv" ]; then
    echo "[INFO] Compare CSV:  $OUT_DIR/compare.csv"
fi

if grep -R -E "^\[(FAIL|TIMEOUT)\]" "$LOG_DIR" >/dev/null 2>&1; then
    exit 1
fi

if grep -R -E "^\[INFO\] sim_exit=([1-9][0-9]*)" "$LOG_DIR" >/dev/null 2>&1; then
    exit 1
fi
