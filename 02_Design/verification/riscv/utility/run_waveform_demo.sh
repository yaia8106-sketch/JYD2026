#!/bin/bash
# ============================================================
# run_waveform_demo.sh — 为报告生成 8 条代表指令的 VCD 波形
#
# 用法:
#   cd 02_Design/verification/riscv
#   bash utility/run_waveform_demo.sh
#
# 输出:
#   work/waveforms/  —— 每条指令一个 .vcd 文件
#   GTKWave / DVE 打开任意 .vcd 即可截图
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFICATION_DIR="$(cd "$RISCV_TESTS_DIR/.." && pwd)"
cd "$RISCV_TESTS_DIR"

RTL_DIR="$(cd "$VERIFICATION_DIR/../rtl" && pwd)"
HEX_DIR="${HEX_DIR:-$RISCV_TESTS_DIR/work/hex}"
WORK_DIR="$RISCV_TESTS_DIR/work"
WAVE_DIR="$WORK_DIR/waveforms"
VCS_ENV="${VCS_ENV:-/home/anokyai/synopsys/env.sh}"

SIM_BIN="$WORK_DIR/riscv_waveform_simv"
COMPILE_LOG="$WORK_DIR/riscv_waveform_vcs.log"

# 8 条代表指令，覆盖全部指令类型
# R-type: ADD        I-type: ADDI        S-type: SW / Store
# B-type: BEQ        U-type: LUI        J-type: JAL
# Load:  LW          AUIPC: AUIPC
TESTS="add addi lw sw beq jal lui auipc"

# ---- RTL 源文件（与 run_all.sh 一致） ----
RTL_FILES="
    -F $RTL_DIR/filelists/cpu_blocks.f
    -F $RTL_DIR/filelists/dcache_bram.f
    $RTL_DIR/core/cpu_top.sv
    $RISCV_TESTS_DIR/work/dcache_data_ram.v
    $RISCV_TESTS_DIR/tb/perf_monitor.sv
    $RISCV_TESTS_DIR/tb/tb_riscv_tests.sv
"

VCS_OPTS="-full64 -sverilog -timescale=1ns/1ps"
VCS_SHIM="$VERIFICATION_DIR/tools/vcs_pthread_yield.c"

# ============================================================
# 0. 检查前置条件
# ============================================================
echo "========================================================"
echo "  Waveform Demo — 8 Representative RISC-V Instructions"
echo "========================================================"

if ! command -v vcs >/dev/null 2>&1; then
    if [ -f "$VCS_ENV" ]; then
        source "$VCS_ENV"
    fi
fi
if ! command -v vcs >/dev/null 2>&1; then
    echo "ERROR: vcs not found. Source Synopsys env or set VCS_ENV."
    exit 1
fi

if [ ! -d "$HEX_DIR" ]; then
    echo "ERROR: hex directory not found: $HEX_DIR"
    echo "  Run: bash utility/build_tests.sh"
    exit 1
fi

for t in $TESTS; do
    if [ ! -f "$HEX_DIR/rv32ui-p-${t}.irom.hex" ]; then
        echo "ERROR: missing hex for $t"
        echo "  Run: bash utility/build_tests.sh"
        exit 1
    fi
done

mkdir -p "$WAVE_DIR"

# ============================================================
# 1. 编译（一次性）
# ============================================================
echo ""
echo "[1/2] Compiling with VCS..."
if ! vcs $VCS_OPTS -top tb_riscv_tests -Mdir="$WORK_DIR/riscv_waveform_vcs.csrc" -o "$SIM_BIN" $RTL_FILES "$VCS_SHIM" >"$COMPILE_LOG" 2>&1; then
    echo "ERROR: VCS compilation failed"
    head -60 "$COMPILE_LOG"
    exit 1
fi
echo "  Compilation OK"

# ============================================================
# 2. 逐条运行，生成 VCD
# ============================================================
echo ""
echo "[2/2] Running tests with VCD dump..."
echo ""

PASSED=0
FAILED=0

# GTKWave 信号列表（对齐报告模板 4.2 节 7 类信号 + 双发射补充）
# 模板要求: clk / rst / CurrentPC / NextPC / Instruction / regfiles / DataMem
GTKW_SIGNALS=(
    # ---- 1. clk ----
    "tb_riscv_tests.clk"
    # ---- 2. rst ----
    "tb_riscv_tests.rst_n"
    # ---- 3. CurrentPC ----
    "tb_riscv_tests.u_cpu.pc"
    # ---- 4. Next PC（双发射: pc+8，若仅发射1条则 pc+4）----
    "tb_riscv_tests.u_cpu.pc_plus8"
    # ---- 5. Instruction（双发射: id_inst 槽0 + id_inst1 槽1）----
    "tb_riscv_tests.u_cpu.id_inst"
    "tb_riscv_tests.u_cpu.id_inst1"
    # ---- 6. regfiles[31:0]（寄存器堆全部 32 个寄存器）----
    "tb_riscv_tests.u_cpu.u_regfile.regs[0:31]"
    # ---- 7. DataMem（数据存储器，65536 太大截前 32 项）----
    "tb_riscv_tests.dram[0:31]"
    # ---- 双发射关键控制信号（辅助分析）----
    "tb_riscv_tests.u_cpu.ex_alu_result"
    "tb_riscv_tests.u_cpu.wb_valid"
    "tb_riscv_tests.u_cpu.wb_s1_valid"
    "tb_riscv_tests.cache_addr"
    "tb_riscv_tests.cache_rdata"
    "tb_riscv_tests.cache_ready"
)

for test_name in $TESTS; do
    irom_hex="$HEX_DIR/rv32ui-p-${test_name}.irom.hex"
    dram_hex="$HEX_DIR/rv32ui-p-${test_name}.dram.hex"
    vcd_file="$WAVE_DIR/${test_name}.vcd"

    printf "  %-8s → %s ... " "$test_name" "$(basename "$vcd_file")"

    result=$("$SIM_BIN" \
        "+irom=$irom_hex" "+dram=$dram_hex" \
        "+test=$test_name" "+cycles=50000" "+pc_guard" "+watchdog=5000" \
        "+dump" "+dump_file=$vcd_file" \
        2>&1 | grep -E "^\[(PASS|FAIL|VCD)\]" | head -3)

    if echo "$result" | grep -q "\[PASS\]"; then
        echo "PASS"
        PASSED=$((PASSED + 1))
        # 自动生成 GTKWave Tcl 脚本（-S 加载，格式可靠）
        {
            for sig in "${GTKW_SIGNALS[@]}"; do
                echo "gtkwave::addSignalsFromList {$sig}"
            done
            echo "gtkwave::/Time/Zoom/Zoom_Full"
        } > "$WAVE_DIR/${test_name}.tcl"
    else
        echo "FAIL"
        FAILED=$((FAILED + 1))
        echo "    Output: $result"
    fi
done

echo ""
echo "========================================================"
echo " Results: $PASSED/$((PASSED + FAILED)) passed"
echo " Files: $WAVE_DIR/"
ls -lhS "$WAVE_DIR"/*.vcd 2>/dev/null | awk '{printf "   %s  %s\n", $5, $NF}'
echo ""
echo " 一键打开（信号已预加载）:"
echo "   gtkwave $WAVE_DIR/add.vcd -S $WAVE_DIR/add.tcl &"
echo "   gtkwave $WAVE_DIR/lw.vcd  -S $WAVE_DIR/lw.tcl &"
echo "   ..."
echo ""
echo " GTKWave 截图建议:"
echo "   1. File → Write Save File As → (选路径).png → 勾选 'Page Rectangle'"
echo "   2. 或终端截图: gnome-screenshot -w -f waveform.png"
echo "   3. 波形默认十进制显示; regs 如显示十六进制右键 → Data Format → Decimal"
echo "========================================================"
