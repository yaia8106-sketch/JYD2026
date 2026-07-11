#!/usr/bin/env bash
# ================================================================
# 用法（在 /home/anokyai/Desktop/CPU_Workspace-master 下执行）：
#   ./03_Timing_Analysis/build.sh <并行core数量> <COE名称>
#
# 例子：
#   ./03_Timing_Analysis/build.sh 16 src0
#
# 生成结束后，从终端打开最终实现结果并在 Vivado GUI 查看时序：
#   vivado -mode gui 03_Timing_Analysis/results/postroute_physopt_pass2.dcp
#
# DCP 打开后，可在 GUI 的 Reports -> Timing -> Report Timing Summary 中
# 重新显示交互式时序报告；文本版流水级报告位于：
#   03_Timing_Analysis/stage_timing_report.txt
#
# 本脚本会完成：选择 IROM64/DRAM COE、干净综合、实现、两轮
# post-route Explore、更新时序报告，并默认生成 bitstream；不会连接 FPGA。
# ================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT}/03_Timing_Analysis"
FLOW_TCL="${SCRIPT_DIR}/run_synth_impl.tcl"
VIVADO_WORK="${SCRIPT_DIR}/vivado_work"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

if [[ $# -ne 2 ]]; then
    echo "用法: ./03_Timing_Analysis/build.sh <并行core数量> <COE名称>" >&2
    echo "示例: ./03_Timing_Analysis/build.sh 16 src0" >&2
    exit 2
fi

JOBS="$1"
COE_NAME="$2"

if [[ ! "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: 并行 core 数量必须是正整数，当前为 '${JOBS}'。" >&2
    exit 2
fi
if [[ ! "${COE_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: COE 名称只能包含字母、数字、点、下划线和连字符。" >&2
    exit 2
fi

COE_DIR="${ROOT}/02_Design/coe/irom64/${COE_NAME}"
if [[ ! -d "${COE_DIR}" ]]; then
    echo "ERROR: COE 不存在: ${COE_DIR}" >&2
    echo "可选 COE：" >&2
    find "${ROOT}/02_Design/coe/irom64" -mindepth 1 -maxdepth 1 -type d \
        -printf '  %f\n' | sort >&2
    exit 2
fi
if [[ ! -f "${COE_DIR}/irom64.coe" || ! -f "${COE_DIR}/dram.coe" ]]; then
    echo "ERROR: ${COE_DIR} 中必须同时存在 irom64.coe 和 dram.coe。" >&2
    exit 2
fi

BITSTREAM="${SCRIPT_DIR}/results/bitstreams/${COE_NAME}.bit"

if ! command -v vivado >/dev/null 2>&1; then
    if [[ -f /tools/Xilinx/Vivado/2024.1/settings64.sh ]]; then
        # shellcheck disable=SC1091
        source /tools/Xilinx/Vivado/2024.1/settings64.sh
    fi
fi
if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: 找不到 vivado，请先 source Vivado settings64.sh。" >&2
    exit 127
fi

mkdir -p "${VIVADO_WORK}/tmp" "$(dirname "${BITSTREAM}")"

echo ">>> 并行 core 数量 : ${JOBS}"
echo ">>> COE             : ${COE_NAME}"
echo ">>> IROM64          : ${COE_DIR}/irom64.coe"
echo ">>> DRAM            : ${COE_DIR}/dram.coe"
echo ">>> Bitstream       : ${BITSTREAM}"
echo ">>> Log             : ${VIVADO_WORK}/build_${COE_NAME}.log"

cd "${ROOT}"
exec vivado -mode batch -notrace \
    -log "${VIVADO_WORK}/build_${COE_NAME}.log" \
    -journal "${VIVADO_WORK}/build_${COE_NAME}.jou" \
    -tempDir "${VIVADO_WORK}/tmp" \
    -source "${FLOW_TCL}" \
    -tclargs --jobs "${JOBS}" --coe-dir "${COE_DIR}" \
        --bitstream-file "${BITSTREAM}"
