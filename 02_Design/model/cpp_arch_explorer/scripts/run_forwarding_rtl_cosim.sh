#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$MODEL_DIR/../../.." && pwd)"
RTL_DIR="$WORKSPACE_DIR/02_Design/rtl"
BUILD_DIR="${FORWARDING_COSIM_BUILD_DIR:-/tmp/forwarding_rtl_cosim}"

mkdir -p "$BUILD_DIR"

verilator \
    --cc \
    --exe \
    --build \
    -j 0 \
    -Wall \
    -Wno-fatal \
    --top-module forwarding \
    --Mdir "$BUILD_DIR" \
    -CFLAGS "-std=c++20 -I$MODEL_DIR/src" \
    "$RTL_DIR/core/decode/load_hazard_ctrl.sv" \
    "$RTL_DIR/core/decode/forwarding.sv" \
    "$MODEL_DIR/src/forwarding_rtl_cosim.cpp" \
    "$MODEL_DIR/src/forwarding_model.cpp"

"$BUILD_DIR/Vforwarding"

MUL_BUILD_DIR="$BUILD_DIR/mul"
mkdir -p "$MUL_BUILD_DIR"

verilator \
    --cc \
    --exe \
    --build \
    -j 0 \
    -Wall \
    -Wno-fatal \
    --top-module mul_operand_forwarding \
    --Mdir "$MUL_BUILD_DIR" \
    -CFLAGS "-std=c++20 -I$MODEL_DIR/src" \
    "$RTL_DIR/core/decode/load_hazard_ctrl.sv" \
    "$RTL_DIR/core/decode/forwarding.sv" \
    "$MODEL_DIR/src/mul_forwarding_rtl_cosim.cpp" \
    "$MODEL_DIR/src/forwarding_model.cpp"

"$MUL_BUILD_DIR/Vmul_operand_forwarding"
