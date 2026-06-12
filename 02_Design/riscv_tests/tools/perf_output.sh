#!/bin/bash

prepare_perf_output_dir() {
    local target="$1"
    local baseline="${2:-}"
    local target_abs
    local perf_root_abs
    local baseline_abs

    target_abs="$(realpath -m -- "$target")"
    perf_root_abs="$(realpath -m -- "$WORK_DIR/perf")"

    case "$target_abs" in
        /|"$RISCV_TESTS_DIR"|"$WORK_DIR"|"$perf_root_abs")
            echo "ERROR: refusing to replace unsafe output directory: $target"
            exit 1
            ;;
    esac

    if [ -n "$baseline" ]; then
        baseline_abs="$(realpath -m -- "$baseline")"
        case "$baseline_abs" in
            "$target_abs"|"$target_abs"/*)
                echo "ERROR: baseline is inside the output directory that will be replaced: $baseline"
                exit 1
                ;;
        esac
    fi

    if [ -e "$target" ] && [ ! -d "$target" ]; then
        echo "ERROR: output path exists but is not a directory: $target"
        exit 1
    fi

    if [ -d "$target" ]; then
        case "$target_abs" in
            "$perf_root_abs"/*)
                ;;
            *)
                if [ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ] &&
                   [ ! -f "$target/run_meta.env" ]; then
                    echo "ERROR: refusing to replace non-empty unmanaged output directory: $target"
                    exit 1
                fi
                ;;
        esac
        rm -rf -- "$target"
    fi

    mkdir -p -- "$target"
}
