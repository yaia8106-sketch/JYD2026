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

add_executable(direction_predictor_tests
    src/direction_predictor_tests.cpp
    src/direction_predictor.cpp
)
target_compile_features(direction_predictor_tests PRIVATE cxx_std_20)
target_compile_options(direction_predictor_tests PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    $<$<CONFIG:Release>:-O3>
)

include(CTest)
if(BUILD_TESTING)
    add_test(NAME direction_predictor_tests COMMAND direction_predictor_tests)
    add_test(
        NAME bp_explorer_smoke
        COMMAND bp_explorer
            --coe-root ${CMAKE_CURRENT_SOURCE_DIR}/../coe/single_issue
            --output-dir ${CMAKE_CURRENT_BINARY_DIR}/smoke_results
            --programs current
            --delays 0,6
            --max-instructions 100000
            --progress 0
    )
endif()
