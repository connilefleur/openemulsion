# SPDX-License-Identifier: MPL-2.0

cmake_minimum_required(VERSION 3.20)
project(OpenEmulsion LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(WIN32)
    set(RESOLVE_OPENFX_DEFAULT "C:/ProgramData/Blackmagic Design/DaVinci Resolve/Support/Developer/OpenFX")
    set(OFX_BUNDLE_ARCH "Win64")
elseif(APPLE)
    set(RESOLVE_OPENFX_DEFAULT "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/OpenFX")
    set(OFX_BUNDLE_ARCH "MacOS")
else()
    set(RESOLVE_OPENFX_DEFAULT "/opt/resolve/Developer/OpenFX")
    set(OFX_BUNDLE_ARCH "Linux-x86-64")
endif()
set(RESOLVE_OPENFX_ROOT "${RESOLVE_OPENFX_DEFAULT}" CACHE PATH "DaVinci Resolve OpenFX developer directory")
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "OpenEmulsion supports 64-bit builds only.")
endif()
set(OFX_BUNDLE_BINARIES "${CMAKE_BINARY_DIR}/OpenEmulsion.ofx.bundle/Contents/${OFX_BUNDLE_ARCH}")

find_package(Threads REQUIRED)

set(OFX_SUPPORT "${RESOLVE_OPENFX_ROOT}/Support")
set(OFX_API "${RESOLVE_OPENFX_ROOT}/OpenFX-1.4")
foreach(required IN ITEMS
    "${OFX_API}/include/ofxCore.h"
    "${OFX_SUPPORT}/include/ofxsImageEffect.h"
    "${OFX_SUPPORT}/include/ofxsProcessing.h"
    "${OFX_SUPPORT}/Library/ofxsCore.cpp")
    if(NOT EXISTS "${required}")
        message(FATAL_ERROR "Resolve OpenFX developer files not found: ${required}\nSet RESOLVE_OPENFX_ROOT to the Developer/OpenFX directory.")
    endif()
endforeach()

set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/GrainMath.h")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/GrainMath.h" GRAIN_MATH_SOURCE)
configure_file(src/GrainOpenCL.h.in "${CMAKE_CURRENT_BINARY_DIR}/GrainOpenCL.h" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/ColorMath.h")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/ColorMath.h" COLOR_MATH_SOURCE)
configure_file(src/ColorOpenCL.h.in "${CMAKE_CURRENT_BINARY_DIR}/ColorOpenCL.h" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/FilmResponseMath.h")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/FilmResponseMath.h" FILM_RESPONSE_SOURCE)
configure_file(src/FilmResponseOpenCL.h.in "${CMAKE_CURRENT_BINARY_DIR}/FilmResponseOpenCL.h" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/HalationMath.h")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/HalationMath.h" HALATION_MATH_SOURCE)
configure_file(src/HalationOpenCL.h.in "${CMAKE_CURRENT_BINARY_DIR}/HalationOpenCL.h" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/BloomMath.h")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/BloomMath.h" BLOOM_MATH_SOURCE)
configure_file(src/BloomOpenCL.h.in "${CMAKE_CURRENT_BINARY_DIR}/BloomOpenCL.h" @ONLY)

add_library(OpenEmulsion SHARED
    src/OpenEmulsion.cpp
    src/OpenCLKernel.cpp
    "${OFX_SUPPORT}/Library/ofxsCore.cpp"
    "${OFX_SUPPORT}/Library/ofxsImageEffect.cpp"
    "${OFX_SUPPORT}/Library/ofxsInteract.cpp"
    "${OFX_SUPPORT}/Library/ofxsLog.cpp"
    "${OFX_SUPPORT}/Library/ofxsMultiThread.cpp"
    "${OFX_SUPPORT}/Library/ofxsParams.cpp"
    "${OFX_SUPPORT}/Library/ofxsProperty.cpp"
    "${OFX_SUPPORT}/Library/ofxsPropertyValidation.cpp"
)

target_include_directories(OpenEmulsion PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}"
    "${OFX_API}/include"
    "${OFX_SUPPORT}/include"
)

if(WIN32)
    target_compile_definitions(OpenEmulsion PRIVATE NOMINMAX)
    target_link_libraries(OpenEmulsion PRIVATE comdlg32)
else()
    # The Support library only marks its entry points visible when the legacy
    # `linux` macro is set, which strict -std=c++17 does not define.
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set_source_files_properties("${OFX_SUPPORT}/Library/ofxsImageEffect.cpp"
            TARGET_DIRECTORY OpenEmulsion PROPERTIES COMPILE_DEFINITIONS "linux=1")
    endif()
    set_target_properties(OpenEmulsion PROPERTIES
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
        POSITION_INDEPENDENT_CODE ON)
    if(NOT APPLE)
        # Export only the OFX entry points.
        target_link_options(OpenEmulsion PRIVATE
            "LINKER:--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/OpenEmulsion.map"
            "LINKER:--no-undefined")
        set_property(TARGET OpenEmulsion APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/OpenEmulsion.map")
    endif()
endif()
target_link_libraries(OpenEmulsion PRIVATE Threads::Threads ${CMAKE_DL_LIBS})

# CUDA backend for hosts that pass CUDA buffers (Resolve's default on Linux/Windows
# NVIDIA systems). Optional: without a CUDA compiler the plugin keeps OpenCL + CPU.
option(OPENEMULSION_CUDA "Build the CUDA render backend when a CUDA compiler is available" ON)
# nvcc has no MinGW host compiler, so MinGW builds keep OpenCL + CPU.
if(OPENEMULSION_CUDA AND NOT APPLE AND NOT MINGW)
    include(CheckLanguage)
    check_language(CUDA)
    if(CMAKE_CUDA_COMPILER)
        if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
            # SASS for Turing/Ampere/Ada plus compute_89 PTX so newer GPUs can JIT instead of failing to launch.
            set(CMAKE_CUDA_ARCHITECTURES "75-real;86-real;89")
        endif()
        enable_language(CUDA)
        find_package(CUDAToolkit REQUIRED)
        target_sources(OpenEmulsion PRIVATE src/CudaKernel.cu)
        target_compile_definitions(OpenEmulsion PRIVATE OPENEMULSION_HAVE_CUDA)
        # Match the math headers' OpenCL FP_CONTRACT OFF so CUDA stays close to CPU/OpenCL output.
        target_compile_options(OpenEmulsion PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:-fmad=false>)
        set_target_properties(OpenEmulsion PROPERTIES
            CUDA_ARCHITECTURES "${CMAKE_CUDA_ARCHITECTURES}"
            CUDA_STANDARD 17
            CUDA_STANDARD_REQUIRED ON
            CUDA_SEPARABLE_COMPILATION OFF
            CUDA_RUNTIME_LIBRARY Static
            CUDA_VISIBILITY_PRESET hidden)
        target_link_libraries(OpenEmulsion PRIVATE CUDA::cudart_static)
        set(OPENEMULSION_CUDA_ENABLED ON)
        message(STATUS "OpenEmulsion CUDA backend enabled (architectures: ${CMAKE_CUDA_ARCHITECTURES})")
    else()
        message(STATUS "No CUDA compiler found; building without the CUDA backend.")
    endif()
endif()

if(MINGW)
    target_compile_options(OpenEmulsion PRIVATE -Wall -Wextra -Wno-unused-parameter)
    target_link_options(OpenEmulsion PRIVATE -static-libgcc -static-libstdc++ -static)
endif()

set_target_properties(OpenEmulsion PROPERTIES
    PREFIX ""
    SUFFIX ".ofx"
    RUNTIME_OUTPUT_DIRECTORY "${OFX_BUNDLE_BINARIES}"
    LIBRARY_OUTPUT_DIRECTORY "${OFX_BUNDLE_BINARIES}"
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

# Keep bundle layout stable with both single- and multi-configuration generators.
foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
    string(TOUPPER "${config}" config_upper)
    set_target_properties(OpenEmulsion PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY_${config_upper} "${OFX_BUNDLE_BINARIES}"
        LIBRARY_OUTPUT_DIRECTORY_${config_upper} "${OFX_BUNDLE_BINARIES}")
endforeach()

# Run even without a relink so resource-only edits reach both bundles.
set(PLUGIN_RESOURCES "${CMAKE_CURRENT_SOURCE_DIR}/resources")
set(BUNDLE_RESOURCES "${CMAKE_BINARY_DIR}/OpenEmulsion.ofx.bundle/Contents/Resources")
set(DIST_RESOURCES "${CMAKE_SOURCE_DIR}/../dist/OpenEmulsion.ofx.bundle/Contents/Resources")
add_custom_target(OpenEmulsionResources
    COMMAND ${CMAKE_COMMAND} -E make_directory "${BUNDLE_RESOURCES}" "${DIST_RESOURCES}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/../LICENSE" "${CMAKE_SOURCE_DIR}/../THIRD_PARTY_NOTICES.md"
        "${CMAKE_BINARY_DIR}/OpenEmulsion.ofx.bundle/Contents/"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/../LICENSE" "${CMAKE_SOURCE_DIR}/../THIRD_PARTY_NOTICES.md"
        "${CMAKE_SOURCE_DIR}/../dist/OpenEmulsion.ofx.bundle/Contents/"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/../licenses"
        "${CMAKE_BINARY_DIR}/OpenEmulsion.ofx.bundle/Contents/Licenses"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/../licenses"
        "${CMAKE_SOURCE_DIR}/../dist/OpenEmulsion.ofx.bundle/Contents/Licenses"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${PLUGIN_RESOURCES}/org.openemulsion.film.png"
        "${PLUGIN_RESOURCES}/org.openemulsion.film.svg"
        "${BUNDLE_RESOURCES}/"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${PLUGIN_RESOURCES}/org.openemulsion.film.png"
        "${PLUGIN_RESOURCES}/org.openemulsion.film.svg"
        "${DIST_RESOURCES}/"
    DEPENDS "${PLUGIN_RESOURCES}/org.openemulsion.film.png" "${PLUGIN_RESOURCES}/org.openemulsion.film.svg"
    VERBATIM
)
add_dependencies(OpenEmulsion OpenEmulsionResources)

add_custom_command(TARGET OpenEmulsion POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_SOURCE_DIR}/../dist"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/../LICENSE"
        "${CMAKE_SOURCE_DIR}/../THIRD_PARTY_NOTICES.md"
        "${CMAKE_BINARY_DIR}/OpenEmulsion.ofx.bundle/Contents/"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_BINARY_DIR}/OpenEmulsion.ofx.bundle"
        "${CMAKE_SOURCE_DIR}/../dist/OpenEmulsion.ofx.bundle"
)

include(CTest)
option(BUILD_COLOR_BENCH "Build optional offline color and full-frame preview tools" OFF)
if(BUILD_COLOR_BENCH)
    add_library(ColorBench SHARED tools/ColorBench.cpp)
    add_executable(FullFrameBench tools/FullFrameBench.cpp src/OpenCLKernel.cpp)
    target_include_directories(FullFrameBench PRIVATE src "${CMAKE_CURRENT_BINARY_DIR}")
    if(WIN32)
        target_compile_definitions(FullFrameBench PRIVATE NOMINMAX)
    endif()
    target_link_libraries(FullFrameBench PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
    if(MINGW)
        target_link_options(FullFrameBench PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    set_target_properties(FullFrameBench PROPERTIES PREFIX "" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bench")
    foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
        string(TOUPPER "${config}" config_upper)
        set_target_properties(FullFrameBench PROPERTIES RUNTIME_OUTPUT_DIRECTORY_${config_upper} "${CMAKE_BINARY_DIR}/bench")
    endforeach()
    target_include_directories(ColorBench PRIVATE src)
    if(MINGW)
        target_link_options(ColorBench PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    set_target_properties(ColorBench PROPERTIES PREFIX "" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bench")
    foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
        string(TOUPPER "${config}" config_upper)
        set_target_properties(ColorBench PROPERTIES RUNTIME_OUTPUT_DIRECTORY_${config_upper} "${CMAKE_BINARY_DIR}/bench")
    endforeach()
    if(BUILD_TESTING)
        add_executable(ColorBenchTests tests/ColorBenchTests.cpp)
        target_include_directories(ColorBenchTests PRIVATE src)
        target_link_libraries(ColorBenchTests PRIVATE ColorBench)
        if(MINGW)
            target_link_options(ColorBenchTests PRIVATE -static-libgcc -static-libstdc++ -static)
        endif()
        set_target_properties(ColorBenchTests PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bench")
        foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
            string(TOUPPER "${config}" config_upper)
            set_target_properties(ColorBenchTests PROPERTIES RUNTIME_OUTPUT_DIRECTORY_${config_upper} "${CMAKE_BINARY_DIR}/bench")
        endforeach()
        add_test(NAME ColorBenchRegression COMMAND ColorBenchTests)
    endif()
endif()
if(BUILD_TESTING)
    find_program(POWERSHELL_EXECUTABLE NAMES pwsh powershell)
    if(POWERSHELL_EXECUTABLE)
        add_test(NAME VersionTrackingRegression COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -ExecutionPolicy Bypass
            -File "${CMAKE_SOURCE_DIR}/../tools/test_plugin_version.ps1")
    else()
        message(STATUS "PowerShell not found; skipping VersionTrackingRegression")
    endif()
    add_executable(PluginStartupTests tests/PluginStartupTests.cpp)
    target_include_directories(PluginStartupTests PRIVATE src "${OFX_API}/include")
    if(WIN32)
        target_compile_definitions(PluginStartupTests PRIVATE NOMINMAX)
    endif()
    target_link_libraries(PluginStartupTests PRIVATE ${CMAKE_DL_LIBS})
    if(MINGW)
        target_link_options(PluginStartupTests PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    add_dependencies(PluginStartupTests OpenEmulsion)
    add_test(NAME PluginStartupRegression COMMAND PluginStartupTests "$<TARGET_FILE:OpenEmulsion>")
    add_test(NAME PluginIconPackaging
        COMMAND ${CMAKE_COMMAND}
            "-DSOURCE_ROOT=${CMAKE_CURRENT_SOURCE_DIR}"
            "-DBUILD_ROOT=${CMAKE_BINARY_DIR}"
            "-DDIST_ROOT=${CMAKE_SOURCE_DIR}/../dist"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/tests/PluginIconTests.cmake")
    add_executable(HalationTests tests/HalationTests.cpp src/OpenCLKernel.cpp)
    target_include_directories(HalationTests PRIVATE src "${CMAKE_CURRENT_BINARY_DIR}")
    if(WIN32)
        target_compile_definitions(HalationTests PRIVATE NOMINMAX)
    endif()
    target_link_libraries(HalationTests PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
    if(OPENEMULSION_CUDA_ENABLED)
        # Run the same CPU parity sweeps against the CUDA backend; skipped at runtime without a CUDA device.
        target_sources(HalationTests PRIVATE src/CudaKernel.cu)
        target_compile_definitions(HalationTests PRIVATE OPENEMULSION_HAVE_CUDA)
        target_compile_options(HalationTests PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:-fmad=false>)
        set_target_properties(HalationTests PROPERTIES
            CUDA_ARCHITECTURES "${CMAKE_CUDA_ARCHITECTURES}"
            CUDA_STANDARD 17
            CUDA_STANDARD_REQUIRED ON
            CUDA_SEPARABLE_COMPILATION OFF
            CUDA_RUNTIME_LIBRARY Static)
        target_link_libraries(HalationTests PRIVATE CUDA::cudart_static)
    endif()
    if(MINGW)
        target_link_options(HalationTests PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    add_test(NAME HalationRegression COMMAND HalationTests)
    add_executable(ModuleControlStateTests tests/ModuleControlStateTests.cpp)
    target_include_directories(ModuleControlStateTests PRIVATE src)
    if(MINGW)
        target_link_options(ModuleControlStateTests PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    add_test(NAME ModuleControlStateRegression COMMAND ModuleControlStateTests)
    add_executable(LookPresetTests tests/LookPresetTests.cpp)
    target_include_directories(LookPresetTests PRIVATE src)
    if(MINGW)
        target_link_options(LookPresetTests PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    add_test(NAME LookPresetRegression COMMAND LookPresetTests)
    add_executable(SliderTuningTests tests/SliderTuningTests.cpp)
    target_include_directories(SliderTuningTests PRIVATE src)
    if(MINGW)
        target_link_options(SliderTuningTests PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    add_test(NAME SliderTuningRegression COMMAND SliderTuningTests)
    add_executable(UserPresetTests tests/UserPresetTests.cpp)
    target_include_directories(UserPresetTests PRIVATE src)
    if(WIN32)
        target_compile_definitions(UserPresetTests PRIVATE NOMINMAX)
        target_link_libraries(UserPresetTests PRIVATE comdlg32)
    endif()
    if(MINGW)
        target_link_options(UserPresetTests PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    add_test(NAME UserPresetRegression COMMAND UserPresetTests)
    add_executable(DisplayRenderingTests tests/DisplayRenderingTests.cpp)
    target_include_directories(DisplayRenderingTests PRIVATE src)
    if(MINGW)
        target_link_options(DisplayRenderingTests PRIVATE -static-libgcc -static-libstdc++ -static)
    endif()
    add_test(NAME DisplayRenderingRegression COMMAND DisplayRenderingTests)
endif()
