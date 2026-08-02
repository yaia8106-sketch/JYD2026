#!/usr/bin/env bash
# NSCSCC/LoongArch RTL correctness gate. This complements, but does not replace,
# the Chiplab official func/perf program runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NSCSCC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$NSCSCC_DIR/../.." && pwd)"
COMMON_CORE_DIR="$VERIFICATION_DIR/common/core"
LOONGARCH_FUNC_DIR="$VERIFICATION_DIR/loongarch/functional"

passed=0
regression_start=$(date +%s)

run_case() {
    local name="$1"
    local script="$2"
    local case_start
    local elapsed

    case_start=$(date +%s)
    echo
    echo "================================================================"
    echo "[NSCSCC REGRESSION] $name"
    echo "================================================================"
    bash "$script"
    elapsed=$(( $(date +%s) - case_start ))
    passed=$((passed + 1))
    echo "[NSCSCC REGRESSION PASS] $name (${elapsed}s)"
}

# Exact competition top/filelist contract, both debug commit configurations.
run_case "core_top elaboration" "$SCRIPT_DIR/run_core_compile.sh"

# Timing-sensitive backend changes and their semantic reference models.
run_case "split ALU semantic/equivalence matrix" \
    "$COMMON_CORE_DIR/run_alu_split_equivalence.sh"
run_case "forwarding, repair and priority matrix" \
    "$COMMON_CORE_DIR/run_forwarding.sh"
run_case "MulDiv directed/random arithmetic" \
    "$COMMON_CORE_DIR/run_muldiv.sh"
run_case "EX redirect source/flush selection" \
    "$COMMON_CORE_DIR/run_ex_stage_redirect.sh"

# LoongArch decode, dual issue, real cpu_top streams and precise state.
# run_decode_contract also invokes the LoongArch FTQ and cpu_top smoke gates.
run_case "LA32R decode, FTQ and cpu_top execution" \
    "$LOONGARCH_FUNC_DIR/run_decode_contract.sh"
run_case "BL fixed-latency sequence" \
    "$LOONGARCH_FUNC_DIR/run_bl_sequence.sh"
run_case "BL under variable IROM latency" \
    "$LOONGARCH_FUNC_DIR/run_bl_variable_irom.sh"
run_case "interrupt boundary and return" \
    "$LOONGARCH_FUNC_DIR/run_interrupt.sh"
run_case "CSR/SYSCALL/ERTN under MEM backpressure" \
    "$LOONGARCH_FUNC_DIR/run_privileged.sh"
run_case "privileged commit/alignment/flush boundaries" \
    "$LOONGARCH_FUNC_DIR/run_priv_commit_boundaries.sh"

# NSCSCC cache and AXI protocol boundaries.
run_case "variable-latency IROM and stale-response kill" \
    "$SCRIPT_DIR/run_variable_irom.sh"
run_case "ICache shortened-tag/class metadata boundaries" \
    "$SCRIPT_DIR/run_icache_metadata.sh"
run_case "DCache uncached single-beat path" \
    "$SCRIPT_DIR/run_dcache_uncached.sh"
run_case "DCache WB+WA refill/evict/RAW/flush" \
    "$SCRIPT_DIR/run_dcache_writeback.sh"
run_case "I/D Cache AXI WRAP/outstanding/backpressure" \
    "$SCRIPT_DIR/run_axi_bridge.sh"

total_elapsed=$(( $(date +%s) - regression_start ))
echo
echo "================================================================"
echo "[PASS] NSCSCC RTL regression: ${passed}/${passed} gates (${total_elapsed}s)"
echo "================================================================"
