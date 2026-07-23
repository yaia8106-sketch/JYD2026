cmake_minimum_required(VERSION 3.20)
project(cpp_arch_explorer LANGUAGES CXX)

add_executable(bp_explorer
    src/main.cpp
    src/predictor.cpp
    src/rv32_sim.cpp
)

target_compile_features(bp_explorer PRIVATE cxx_std_20)
target_compile_options(bp_explorer PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<CONFIG:Release>:-O3>
)

add_executable(direction_study
    src/direction_main.cpp
    src/direction_predictor.cpp
    src/rv32_sim.cpp
)
target_compile_features(direction_study PRIVATE cxx_std_20)
target_compile_options(direction_study PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<CONFIG:Release>:-O3>
)

add_executable(frontend_study
    src/frontend_main.cpp
    src/frontend_model.cpp
    src/direction_predictor.cpp
    src/rv32_sim.cpp
)
target_compile_features(frontend_study PRIVATE cxx_std_20)
target_compile_options(frontend_study PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<CONFIG:Release>:-O3>
)

add_executable(fdq_study
    src/fdq_main.cpp
    src/fdq_model.cpp
    src/frontend_model.cpp
    src/direction_predictor.cpp
    src/rv32_sim.cpp
)
target_compile_features(fdq_study PRIVATE cxx_std_20)
target_compile_options(fdq_study PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<CONFIG:Release>:-O3>
)

add_executable(backend_iq_study
    src/backend_main.cpp
    src/backend_model.cpp
    src/rv32_sim.cpp
)
target_compile_features(backend_iq_study PRIVATE cxx_std_20)
target_compile_options(backend_iq_study PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<CONFIG:Release>:-O3>
)

add_executable(forwarding_study
    src/forwarding_main.cpp
    src/forwarding_model.cpp
    src/rv32_sim.cpp
)
target_compile_features(forwarding_study PRIVATE cxx_std_20)
target_compile_options(forwarding_study PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<CONFIG:Release>:-O3>
)

add_executable(direction_predictor_tests
    src/direction_predictor_tests.cpp
    src/direction_predictor.cpp
)

add_executable(frontend_model_tests
    src/frontend_model_tests.cpp
    src/frontend_model.cpp
    src/direction_predictor.cpp
)
add_executable(fdq_model_tests
    src/fdq_model_tests.cpp
    src/fdq_model.cpp
    src/frontend_model.cpp
    src/direction_predictor.cpp
)
add_executable(backend_model_tests
    src/backend_model_tests.cpp
    src/backend_model.cpp
)
add_executable(forwarding_model_tests
    src/forwarding_model_tests.cpp
    src/forwarding_model.cpp
)
target_compile_features(frontend_model_tests PRIVATE cxx_std_20)
target_compile_options(frontend_model_tests PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -UNDEBUG
    $<$<CONFIG:Release>:-O3>
)
target_compile_features(direction_predictor_tests PRIVATE cxx_std_20)
target_compile_options(direction_predictor_tests PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -UNDEBUG
    $<$<CONFIG:Release>:-O3>
)
target_compile_features(fdq_model_tests PRIVATE cxx_std_20)
target_compile_options(fdq_model_tests PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -UNDEBUG
    $<$<CONFIG:Release>:-O3>
)
target_compile_features(backend_model_tests PRIVATE cxx_std_20)
target_compile_options(backend_model_tests PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -UNDEBUG
    $<$<CONFIG:Release>:-O3>
)
target_compile_features(forwarding_model_tests PRIVATE cxx_std_20)
target_compile_options(forwarding_model_tests PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -UNDEBUG
    $<$<CONFIG:Release>:-O3>
)

include(CTest)
if(BUILD_TESTING)
    add_test(NAME direction_predictor_tests COMMAND direction_predictor_tests)
    add_test(NAME frontend_model_tests COMMAND frontend_model_tests)
    add_test(NAME fdq_model_tests COMMAND fdq_model_tests)
    add_test(NAME backend_model_tests COMMAND backend_model_tests)
    add_test(NAME forwarding_model_tests COMMAND forwarding_model_tests)
    add_test(
        NAME bp_explorer_smoke
        COMMAND bp_explorer
            --coe-root ${CMAKE_CURRENT_SOURCE_DIR}/../../verification/riscv/coe/single_issue
            --output-dir ${CMAKE_CURRENT_BINARY_DIR}/smoke_results
            --programs current
            --delays 0,6
            --max-instructions 100000
            --progress 0
    )
    add_test(
        NAME frontend_study_smoke
        COMMAND frontend_study
            --coe-root ${CMAKE_CURRENT_SOURCE_DIR}/../../verification/riscv/coe/single_issue
            --output-dir ${CMAKE_CURRENT_BINARY_DIR}/frontend_smoke_results
            --programs current
            --delays 6
            --configs CURRENT_GSHARE,GSHARE_F0_JAL_ONLY,BIMODAL_TAGE2_OLDEST,BIMODAL_TAGE2_OLDEST_STRONG,BIMODAL_TAGE2_OLDEST_NO_BARRIER,BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_ALT,BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_ALT_STRONG_OR_USEFUL
            --max-instructions 100000
            --progress 0
    )
    add_test(
        NAME fdq_study_smoke
        COMMAND fdq_study
            --coe-root ${CMAKE_CURRENT_SOURCE_DIR}/../../verification/riscv/coe/single_issue
            --rtl-log-dir ${CMAKE_CURRENT_SOURCE_DIR}/../../verification/riscv/work/perf/runs/coe/20260704_125720/logs
            --output-dir ${CMAKE_CURRENT_BINARY_DIR}/fdq_smoke_results
            --programs current
            --delays 6,10
            --configs CURRENT_GSHARE,BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_ALT_STRONG_OR_USEFUL
            --scenarios D8_RTLPAIR_F1R1_B6_DIR_CAL_EVEN,D8_RTLPAIR_F1R2_B6_DIR_CAL_EVEN
            --max-instructions 100000
            --progress 0
    )
    add_test(
        NAME backend_iq_study_smoke
        COMMAND backend_iq_study
            --coe-root ${CMAKE_CURRENT_SOURCE_DIR}/../../verification/riscv/coe/single_issue
            --output-dir ${CMAKE_CURRENT_BINARY_DIR}/backend_iq_smoke_results
            --programs current
            --configs 4:6:2,8:6:2
            --branch-mode gshare
            --max-instructions 100000
            --progress 0
            --jobs 1
    )
    add_test(
        NAME forwarding_study_smoke
        COMMAND forwarding_study
            --coe-root ${CMAKE_CURRENT_SOURCE_DIR}/../../verification/riscv/coe/single_issue
            --output-dir ${CMAKE_CURRENT_BINARY_DIR}/forwarding_smoke_results
            --programs current
            --max-instructions 100000
            --progress 0
            --jobs 1
    )
    add_test(
        NAME forwarding_chain_baseline_only_smoke
        COMMAND forwarding_study
            --coe-root ${CMAKE_CURRENT_SOURCE_DIR}/../../verification/riscv/coe/single_issue
            --output-dir ${CMAKE_CURRENT_BINARY_DIR}/forwarding_chain_smoke_results
            --programs current
            --max-instructions 100000
            --progress 0
            --jobs 1
            --baseline-only
    )
endif()
