cmake_minimum_required(VERSION 3.10)
project(quickjs_nif C)

# Output directory
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/../priv)

# Find Erlang
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CMAKE_SOURCE_DIR}/CMake)
find_package(Erlang REQUIRED)

# Platform-specific settings
if(APPLE)
    set(CMAKE_SHARED_MODULE_CREATE_C_FLAGS
        "${CMAKE_SHARED_MODULE_CREATE_C_FLAGS} -flat_namespace -undefined dynamic_lookup")
    if(EXISTS "/opt/homebrew")
        include_directories(/opt/homebrew/include)
        link_directories(/opt/homebrew/lib)
    elseif(EXISTS "/usr/local/opt")
        include_directories(/usr/local/include)
        link_directories(/usr/local/lib)
    endif()
endif()

# C standard - quickjs-ng needs C11
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Compiler flags
if(MSVC)
    add_compile_options(/W3)
else()
    add_compile_options(-Wall -Wextra)
    add_compile_options(-Wno-unused-parameter -Wno-unused-but-set-variable -Wno-sign-compare -Wno-implicit-fallthrough)
endif()

add_compile_definitions(_GNU_SOURCE)
if(WIN32)
    add_compile_definitions(WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0601)
endif()

# Erlang headers
include_directories(${ERLANG_EI_INCLUDE_PATH})
include_directories(${ERLANG_ERTS_INCLUDE_PATH})
link_directories(${ERLANG_EI_LIBRARY_PATH})

# quickjs-ng headers
include_directories(${CMAKE_SOURCE_DIR}/quickjs-ng)

# quickjs-ng core sources (mirrors upstream qjs_sources without quickjs-libc.c)
set(QUICKJS_SOURCES
    quickjs-ng/dtoa.c
    quickjs-ng/libregexp.c
    quickjs-ng/libunicode.c
    quickjs-ng/quickjs.c
)

# NIF sources
set(QUICKJS_NIF_SOURCES
    quickjs_nif.c
    ${QUICKJS_SOURCES}
)

add_library(quickjs MODULE ${QUICKJS_NIF_SOURCES})
set_target_properties(quickjs PROPERTIES PREFIX "")

# Hide quickjs-ng symbols inside the NIF so multiple JS engines can coexist in a release.
if(NOT WIN32)
    set_target_properties(quickjs PROPERTIES C_VISIBILITY_PRESET hidden)
endif()

# Link
if(WIN32)
    target_link_libraries(quickjs ei)
elseif(APPLE)
    target_link_libraries(quickjs m)
else()
    target_link_libraries(quickjs ei pthread m dl)
endif()
