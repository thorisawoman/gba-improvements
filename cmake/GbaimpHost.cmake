# GbaimpHost.cmake
#
# Shared build logic for host projects that combine a statically recompiled GBA
# game (gbarecomp) with gba-improvements. Every host used to repeat ~200 lines
# of CMake for the game executable and for its native unit-test executable;
# gbaimp_add_host() does all of it.
#
#   include("${GBAIMP_ROOT}/cmake/GbaimpHost.cmake")
#
#   gbaimp_add_host(MyGameRecomp
#       SYMBOL_PREFIX mygame
#       SOURCES src/main.cpp src/gbaimp_integration.cpp src/sdl_intercepts.cpp ...
#       TEST_TARGET mygame_unit_tests
#       TEST_SOURCES tests/test_all_modules.cpp src/gbaimp_integration.cpp ... src/scaffold_stub.cpp)
#
# Arguments
#   <exe>                  Name of the game executable target (also the file name
#                          copied to the source root after each build).
#   SYMBOL_PREFIX <p>      Host prefix for the recomp-ui symbol rename done on MSVC.
#                          The renamed function is `<p lowercase>_real_recomp_runtime_ui_create_standard`
#                          and the macro `<P UPPERCASE>_RENAME_RUNTIME_UI_CREATE_STANDARD=1` is
#                          defined on the executable and on the test target.
#   SOURCES <files...>     Game sources of the executable. Generated sources
#                          (GENERATED_DIR/*.c, *.cpp) are appended automatically when
#                          GENERATED_DIR/dispatch_table.cpp exists, otherwise SCAFFOLD_STUB.
#   TEST_TARGET <name>     Optional: also create the native unit-test executable.
#   TEST_SOURCES <files...>  Sources of the test executable (include your scaffold stub).
#   GENERATED_DIR <dir>    Default: ${CMAKE_CURRENT_SOURCE_DIR}/generated
#   SCAFFOLD_STUB <file>   Default: src/scaffold_stub.cpp (used while nothing is generated yet)
#   INCLUDE_DIRS <dirs...> Extra private include directories for both targets.
#   ENHANCED_IMGUI_SOURCE <file>
#                          Default: <gba-improvements>/optional/recomp_ui/runtime_ui_imgui_enhanced.cpp.
#                          The in-game menu renderer compiled in place of recomp-ui's stock
#                          runtime_ui_imgui.cpp (only when recomp-ui is present). Pass a host file to
#                          use a customised renderer instead of the shared one.
#   SDL2_DLL <file>        Default: ${CMAKE_CURRENT_SOURCE_DIR}/third_party/sdl2/lib/x64/SDL2.dll.
#                          Copied next to the exe and to the source root when it exists.
#
# Variables read from the caller (same ones every host already sets)
#   GBARECOMP_ROOT         gbarecomp checkout (required).
#   SDL2_INCLUDE_DIR       SDL2 include directory (optional).
#   RECOMP_UI_DIR          recomp-ui checkout (optional; enables the MSVC symbol rename).
#   GBARECOMP_GENERATED_BIOS_DIR  directory with generated BIOS sources (optional).
#
# Platform effects (identical to what the hosts did by hand)
#   * GNU ld (not MSVC): -Wl,--wrap for SDL_PollEvent, SDL_RenderPresent, SDL_UpdateTexture,
#     SDL_RenderCopy, SDL_QueueAudio and SDL_OpenAudioDevice, plus
#     recomp_runtime_ui_create_standard, on both targets.
#   * MSVC with recomp-ui: no link options (SDL is interposed at run time by
#     gbaimp::install_sdl_interposers()); recomp_runtime_ui_create_standard is renamed while
#     compiling recomp_runtime_settings.c, and <PREFIX>_RENAME_RUNTIME_UI_CREATE_STANDARD=1 is defined.
#   * Generated sources and BIOS sources are compiled with warnings off (/w or -w).
#   * Post build: the executable is copied to the source root; SDL2.dll to the exe
#     directory and to the source root (when present).
#   * The runtime stack is linked with target_link_gbarecomp_runtime_stack() when recomp-ui
#     provides it, otherwise with the gbarecomp static libraries (--start-group on GNU ld for the exe).

include_guard(GLOBAL)

# Root of the gba-improvements checkout this file belongs to (resolved here because
# CMAKE_CURRENT_LIST_DIR inside a function would be the caller's directory).
get_filename_component(_GBAIMP_KIT_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(GBAIMP_ENHANCED_IMGUI_SOURCE_DEFAULT
    "${_GBAIMP_KIT_ROOT}/optional/recomp_ui/runtime_ui_imgui_enhanced.cpp"
    CACHE INTERNAL "Shared enhanced recomp-ui menu renderer")

# Runtime-stack and platform settings shared by the executable and the test target.
function(_gbaimp_host_configure_target tgt is_test prefix_lower)
    set(_inc src "${_GBAIMP_HOST_GENERATED_DIR}"
        "${GBARECOMP_ROOT}/src" "${GBARECOMP_ROOT}/src/runtime" "${GBARECOMP_ROOT}/src/gba")
    if(NOT is_test)
        list(APPEND _inc "${GBARECOMP_ROOT}/src/armv4t")
    endif()
    if(SDL2_INCLUDE_DIR)
        list(APPEND _inc "${SDL2_INCLUDE_DIR}")
    endif()
    target_include_directories(${tgt} PRIVATE ${_inc} ${_GBAIMP_HOST_INCLUDE_DIRS})
    target_link_libraries(${tgt} PRIVATE gbaimp::gba_improvements)

    # recomp-ui launcher: swap the stock imgui front end for the enhanced one.
    # (The source lives in the library: optional/recomp_ui/, not in the host.)
    if(COMMAND recomp_target_launcher_ui)
        recomp_target_launcher_ui(${tgt} CONSOLE gba)
        get_target_property(_srcs ${tgt} SOURCES)
        list(FILTER _srcs EXCLUDE REGEX "runtime_ui_imgui\\.cpp$")
        set_target_properties(${tgt} PROPERTIES SOURCES "${_srcs}")
        if(NOT EXISTS "${_GBAIMP_HOST_ENHANCED_IMGUI}")
            message(FATAL_ERROR "gbaimp_add_host: enhanced imgui source not found: ${_GBAIMP_HOST_ENHANCED_IMGUI}")
        endif()
        target_sources(${tgt} PRIVATE "${_GBAIMP_HOST_ENHANCED_IMGUI}")
    endif()

    if(COMMAND target_link_gbarecomp_runtime_stack)
        target_link_gbarecomp_runtime_stack(${tgt})
    elseif(NOT is_test AND NOT (APPLE OR MSVC))
        target_link_libraries(${tgt} PRIVATE
            -Wl,--start-group
            gbarecomp_armv4t gbarecomp_gba gbarecomp_runtime gbarecomp_debug
            -Wl,--end-group)
    else()
        target_link_libraries(${tgt} PRIVATE
            gbarecomp_armv4t gbarecomp_gba gbarecomp_runtime gbarecomp_debug)
    endif()
    if(ANDROID)
        target_link_libraries(${tgt} PRIVATE dl m)   # pthreads are part of Android's libc
    elseif(UNIX AND NOT APPLE)
        target_link_libraries(${tgt} PRIVATE pthread dl m)
    endif()

    if(NOT MSVC AND NOT APPLE)  # Apple: compile-time renames in the host instead
        set(_wraps
            "-Wl,--wrap=SDL_PollEvent"
            "-Wl,--wrap=SDL_RenderPresent"
            "-Wl,--wrap=SDL_UpdateTexture"
            "-Wl,--wrap=SDL_RenderCopy"
            "-Wl,--wrap=SDL_QueueAudio"
            "-Wl,--wrap=SDL_OpenAudioDevice")
        # The menu constructor is wrapped on both targets: the host's runtime_ui_standard.cpp (which
        # defines __wrap_recomp_runtime_ui_create_standard) is compiled into the unit-test executable
        # too, and without the flag its __real_ reference cannot be resolved at link time.
        list(APPEND _wraps "-Wl,--wrap=recomp_runtime_ui_create_standard")
        target_link_options(${tgt} PRIVATE ${_wraps})
    endif()
    set_target_properties(${tgt} PROPERTIES CXX_SCAN_FOR_MODULES OFF)

    # MSVC has no --wrap: recomp_runtime_ui_create_standard is renamed while compiling the
    # one recomp-ui translation unit that defines it (the third-party source is untouched).
    if(MSVC AND COMMAND recomp_target_launcher_ui AND _GBAIMP_HOST_RUI_SETTINGS_C)
        string(TOUPPER "${prefix_lower}" _upper)
        target_compile_definitions(${tgt} PRIVATE ${_upper}_RENAME_RUNTIME_UI_CREATE_STANDARD=1)
    endif()
endfunction()

function(gbaimp_add_host exe)
    cmake_parse_arguments(PARSE_ARGV 1 H
        ""
        "SYMBOL_PREFIX;TEST_TARGET;GENERATED_DIR;SCAFFOLD_STUB;SDL2_DLL;ENHANCED_IMGUI_SOURCE"
        "SOURCES;TEST_SOURCES;INCLUDE_DIRS")
    if(H_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "gbaimp_add_host: unknown arguments: ${H_UNPARSED_ARGUMENTS}")
    endif()
    if(NOT H_SYMBOL_PREFIX)
        message(FATAL_ERROR "gbaimp_add_host(${exe}): SYMBOL_PREFIX is required")
    endif()
    if(NOT H_SOURCES)
        message(FATAL_ERROR "gbaimp_add_host(${exe}): SOURCES is required")
    endif()
    if(NOT GBARECOMP_ROOT)
        message(FATAL_ERROR "gbaimp_add_host(${exe}): GBARECOMP_ROOT is not set")
    endif()
    if(H_TEST_TARGET AND NOT H_TEST_SOURCES)
        message(FATAL_ERROR "gbaimp_add_host(${exe}): TEST_TARGET needs TEST_SOURCES")
    endif()
    if(NOT TARGET gbaimp::gba_improvements)
        message(FATAL_ERROR "gbaimp_add_host(${exe}): add_subdirectory() the gba-improvements library first")
    endif()
    if(NOT H_GENERATED_DIR)
        set(H_GENERATED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated")
    endif()
    if(NOT H_SCAFFOLD_STUB)
        set(H_SCAFFOLD_STUB src/scaffold_stub.cpp)
    endif()
    if(NOT H_SDL2_DLL)
        set(H_SDL2_DLL "${CMAKE_CURRENT_SOURCE_DIR}/third_party/sdl2/lib/x64/SDL2.dll")
    endif()
    string(TOLOWER "${H_SYMBOL_PREFIX}" _prefix_lower)

    # Passed to the helper (functions share no state otherwise).
    set(_GBAIMP_HOST_GENERATED_DIR "${H_GENERATED_DIR}")
    set(_GBAIMP_HOST_INCLUDE_DIRS "${H_INCLUDE_DIRS}")
    if(H_ENHANCED_IMGUI_SOURCE)
        set(_GBAIMP_HOST_ENHANCED_IMGUI "${H_ENHANCED_IMGUI_SOURCE}")
    else()
        set(_GBAIMP_HOST_ENHANCED_IMGUI "${GBAIMP_ENHANCED_IMGUI_SOURCE_DEFAULT}")
    endif()
    set(_GBAIMP_HOST_RUI_SETTINGS_C "")
    if(RECOMP_UI_DIR AND EXISTS "${RECOMP_UI_DIR}/src/common/recomp_runtime_settings.c")
        set(_GBAIMP_HOST_RUI_SETTINGS_C "${RECOMP_UI_DIR}/src/common/recomp_runtime_settings.c")
    endif()

    # Generated sources, or the scaffold stub while nothing has been generated.
    file(GLOB _generated CONFIGURE_DEPENDS "${H_GENERATED_DIR}/*.c" "${H_GENERATED_DIR}/*.cpp")
    set(_sources ${H_SOURCES})
    if(EXISTS "${H_GENERATED_DIR}/dispatch_table.cpp")
        list(APPEND _sources ${_generated})
    else()
        list(APPEND _sources ${H_SCAFFOLD_STUB})
    endif()

    # Machine-generated translation units: no warnings.
    set(_suppress "")
    if(MSVC)
        set(_suppress "/w")
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        set(_suppress "-w")
    endif()
    if(_suppress)
        if(_generated)
            set_source_files_properties(${_generated} PROPERTIES COMPILE_OPTIONS "${_suppress}")
        endif()
        if(TARGET gbarecomp_runtime AND GBARECOMP_GENERATED_BIOS_DIR)
            set_source_files_properties(
                "${GBARECOMP_GENERATED_BIOS_DIR}/bios_dispatch_table.cpp"
                "${GBARECOMP_GENERATED_BIOS_DIR}/bios_recompiled.cpp"
                TARGET_DIRECTORY gbarecomp_runtime
                PROPERTIES COMPILE_OPTIONS "${_suppress}")
        endif()
    endif()

    if(_GBAIMP_HOST_RUI_SETTINGS_C AND MSVC AND COMMAND recomp_target_launcher_ui)
        set_source_files_properties("${_GBAIMP_HOST_RUI_SETTINGS_C}" PROPERTIES
            COMPILE_DEFINITIONS
            "recomp_runtime_ui_create_standard=${_prefix_lower}_real_recomp_runtime_ui_create_standard")
    endif()

    # ---- game executable ----
    add_executable(${exe} ${_sources})
    _gbaimp_host_configure_target(${exe} FALSE ${_prefix_lower})

    add_custom_command(TARGET ${exe} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:${exe}> "${CMAKE_CURRENT_SOURCE_DIR}/${exe}${CMAKE_EXECUTABLE_SUFFIX}")
    if(EXISTS "${H_SDL2_DLL}")
        # SDL2.dll next to the built exe and next to the deployed copy in the source root.
        add_custom_command(TARGET ${exe} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "${H_SDL2_DLL}" $<TARGET_FILE_DIR:${exe}>
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "${H_SDL2_DLL}" "${CMAKE_CURRENT_SOURCE_DIR}")
    endif()

    # ---- native unit-test executable ----
    if(H_TEST_TARGET)
        add_executable(${H_TEST_TARGET} ${H_TEST_SOURCES})
        _gbaimp_host_configure_target(${H_TEST_TARGET} TRUE ${_prefix_lower})
    endif()
endfunction()
