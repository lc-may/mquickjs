cmake_minimum_required(VERSION 3.15)

find_package(bouffalo_sdk REQUIRED HINTS $ENV{BL_SDK_BASE})

sdk_add_include_directories(.)
sdk_add_compile_definitions(BFLB_SDK)

# Increase stack for JS VM task
sdk_add_compile_definitions(SHELL_EXEC_THREAD_STACK_SIZE=4096)

# Use boot2 API instead of MTD for LittleFS partition access
# This requires manually adding the boot2 include path
sdk_add_compile_definitions(CONFIG_LFS_USE_MTD=0)
sdk_add_include_directories($ENV{BL_SDK_BASE}/components/utils/bflb_mtd/include)

sdk_set_main_file(main.c)

# Core mquickjs sources (NO readline/readline_tty - uses signals)
# Note: Headers (mquickjs_atom.h, mqjs_stdlib.h) must be pre-generated on host
target_sources(app PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/mquickjs.c
    ${CMAKE_CURRENT_SOURCE_DIR}/cutils.c
    ${CMAKE_CURRENT_SOURCE_DIR}/dtoa.c
    ${CMAKE_CURRENT_SOURCE_DIR}/libm.c
    ${CMAKE_CURRENT_SOURCE_DIR}/bouffalo_mquickjs.c
)

project(mquickjs)
