# CMakeLists
#
# MIT License
#
# Copyright (c) 2021, 2024 Matt Evans
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#
#
# 指定最低要求的 CMake 版本为 3.13
# 这确保了项目使用的 CMake 特性与该版本及以上兼容
cmake_minimum_required(VERSION 3.13)

# 以下是初始化构建目录时可以定义的选项
# 使用方式示例: "cmake .. -DOPTION=true"
# 这些选项允许用户在配置构建时自定义功能和硬件参数

# 定义一个名为 USE_SD 的构建选项，默认值为 OFF（不启用）
# 当设置为 ON 时，将在项目中包含 SD 卡支持的相关代码和配置
option(USE_SD "Build in SD support" OFF)
set(SD_TX 3 CACHE STRING "SD SPI TX pin")
set(SD_RX 4 CACHE STRING "SD SPI RX pin")
set(SD_SCK 2 CACHE STRING "SD SPI SCK pin")
set(SD_CS 5 CACHE STRING "SD SPI CS pin")
set(SD_MHZ 5 CACHE STRING "SD SPI speed in MHz")

# 定义一个名为 USE_VGA_RES 的构建选项，默认值为 OFF
# 当设置为 ON 时，视频输出将使用 VGA 分辨率（640x480）
option(USE_VGA_RES "Video uses VGA (640x480) resolution" ON)

# 定义视频输出的 GPIO 基础引脚
# 说明中提到该引脚后会依次跟随 VS（场同步）、CLK（时钟）、HS（行同步）引脚
set(VIDEO_PIN 18 CACHE STRING "Video GPIO base pin (followed by VS, CLK, HS)")

# 说明：可以通过 -DMEMSIZE=<KB数值> 来配置umac的内存大小，
# 此参数会覆盖默认的内存配置值
# See below, -DMEMSIZE=<size in KB> will configure umac's memory size,
# overriding defaults.

# 根据 PICO_SDK_PATH 环境变量初始化 Raspberry Pi Pico SDK
# 注意：这一步必须在 project() 命令之前执行，
# 因为SDK需要在项目创建前设置必要的编译环境和工具链
include(pico_sdk_import.cmake)

# 定义项目名称为 "firmware"，这将作为生成的固件文件的基础名称
# 同时会初始化CMake的项目环境，包括编译器设置等
project(firmware)

# 初始化 Raspberry Pi Pico SDK
# 该函数会设置SDK所需的各种编译选项、链接库和包含路径，
# 为Pico系列微控制器构建环境做准备
# initialize the Raspberry Pi Pico SDK
pico_sdk_init()


# 配置 TinyUSB 主机相关功能的设置

# 设置目标芯片系列为 rp2040（Raspberry Pi Pico 使用的芯片）
# 这是 TinyUSB 库需要的关键配置，用于适配特定硬件的 USB 功能
set(FAMILY rp2040)

# 指定目标开发板为 raspberry_pi_pico
# 开发板信息用于 TinyUSB 针对特定硬件布局进行配置（如引脚分配等）
set(BOARD raspberry_pi_pico)

# 设置 TinyUSB 库的路径
# 将其指向 Pico SDK 中内置的 TinyUSB 库目录，避免单独安装
# PICO_SDK_PATH 是 Pico SDK 安装路径的环境变量
set(TINYUSB_PATH ${PICO_SDK_PATH}/lib/tinyusb)

# umac subproject (and Musashi sub-subproject)
#set(UMAC_PATH ${CMAKE_CURRENT_SOURCE_DIR}/external/umac)
#set(UMAC_MUSASHI_PATH ${UMAC_PATH}/external/Musashi)
#set(UMAC_INCLUDE_PATHS ${UMAC_PATH}/include ${UMAC_MUSASHI_PATH})

# This isn't very nice, but hey it's Sunday :p
#set(UMAC_SOURCES
#  ${UMAC_PATH}/src/disc.c
#  ${UMAC_PATH}/src/main.c
#  ${UMAC_PATH}/src/rom.c
#  ${UMAC_PATH}/src/scc.c
#  ${UMAC_PATH}/src/via.c
#  ${UMAC_MUSASHI_PATH}/m68kcpu.c
#  ${UMAC_MUSASHI_PATH}/m68kdasm.c
#  ${UMAC_MUSASHI_PATH}/m68kops.c
#  ${UMAC_MUSASHI_PATH}/softfloat/softfloat.c
#  )

set(MEMSIZE 128 CACHE STRING "Memory size, in KB")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3 -DPICO -DMUSASHI_CNF=\\\"../include/m68kconf.h\\\" -DUMAC_MEMSIZE=${MEMSIZE}")

if (USE_SD)
   add_compile_definitions(USE_SD=1)
   set(FF_DISABLE_RTC ${PICO_RP2350})  # RP2350 doesn't have RTC, so disable it
   add_subdirectory(third_party/fatfs/FatFs_SPI build)
   set(EXTRA_SD_SRC src/sd_hw_config.c)
   set(EXTRA_SD_LIB FatFs_SPI)
   add_compile_definitions(SD_TX=${SD_TX} SD_RX=${SD_RX} SD_SCK=${SD_SCK} SD_CS=${SD_CS} SD_MHZ=${SD_MHZ})
endif()

# ！！
if (USE_VGA_RES)
   add_compile_definitions(USE_VGA_RES=1)
   add_compile_definitions(DISP_WIDTH=640)
   add_compile_definitions(DISP_HEIGHT=480)
else()
   add_compile_definitions(DISP_WIDTH=512)
   add_compile_definitions(DISP_HEIGHT=342)
endif()

# P0 允许完全关掉 VGA/console，只通过串口观察 Lua 与机器人日志。
# 关闭后不初始化 video/PIO/DMA，不分配 framebuffer；适合没有显示器时验证
# Lua 驱动和后续的 I2C/SPI/UART。
option(USE_VGA "Build VGA output and framebuffer console" ON)
if (USE_VGA)
   add_compile_definitions(USE_VGA=1)
else()
   add_compile_definitions(USE_VGA=0)
endif()
add_compile_definitions(GPIO_VID_BASE=${VIDEO_PIN})

# ---------------------------------------------------------------------------
# Lua 5.1.5（vendored）：P0 的驱动运行时。
# LuaJIT 在 Cortex-M0+ 上不可用；Lua 5.1 保留 getfenv/setfenv，最接近现有
# modules/*.lua 的 LuaJIT 5.1 语法。只编译核心与标准库，lua.c/luac.c 是宿主
# 解释器入口，不参与固件。
# ---------------------------------------------------------------------------
set(LUA_SRC_DIR ${CMAKE_CURRENT_LIST_DIR}/third_party/lua/src)
file(GLOB LUA_SOURCES ${LUA_SRC_DIR}/*.c)
list(REMOVE_ITEM LUA_SOURCES
  ${LUA_SRC_DIR}/lua.c
  ${LUA_SRC_DIR}/luac.c
  ${LUA_SRC_DIR}/print.c
  # 裸机没有 POSIX 文件/进程系统调用；io/os 库会把 newlib 的
  # _link/_unlink 等未实现符号拖进链接。P0 只开 base/table/string/math/
  # debug/package，os.getenv/os.time 由 robot.c 提供最小实现。
  ${LUA_SRC_DIR}/liolib.c
  ${LUA_SRC_DIR}/loslib.c
  ${LUA_SRC_DIR}/linit.c
  )
add_library(lua51 STATIC ${LUA_SOURCES})
target_include_directories(lua51 PUBLIC ${LUA_SRC_DIR})
# Lua 源码是 C89 风格，不必继承 C++ 的告警策略；避免第三方源码噪声。
target_compile_options(lua51 PRIVATE -Wno-unused-parameter -Wno-sign-compare)

if (TARGET tinyusb_device)
  add_executable(firmware
    src/main.c
    src/video.c
    src/chsf.c
    src/chsf32.c
    src/kbd.c
    src/hid.c
    src/cncc.c
    src/console.c
    src/robot.c
    src/graph/basic.c
    #src/graph/bezier.c
    src/mathh/lagrange.c
    src/mathh/fft1.c
    src/interpreter/try.c
    ${EXTRA_SD_SRC}

    ${UMAC_SOURCES}
    )

  # The umac sources need to prepare Musashi (some sources are generated):
  #add_custom_command(OUTPUT ${UMAC_MUSASHI_PATH}/m68kops.c
  #  COMMAND echo "*** Preparing umac source ***"
  #  COMMAND make -C ${UMAC_PATH} prepare
  #  )
  #add_custom_target(prepare_umac
  #  DEPENDS ${UMAC_MUSASHI_PATH}/m68kops.c
  #  )
  #add_dependencies(firmware prepare_umac)

# 启用浮点运算
pico_set_float_implementation( firmware default)
pico_set_double_implementation(firmware default)

  target_link_libraries(firmware
    pico_stdlib
    pico_multicore
    pico_float
    pico_double
    pico_util
    tinyusb_host
    tinyusb_board
    hardware_dma
    hardware_pio
    hardware_sync
    lua51
    m
    ${EXTRA_SD_LIB}
    )

  # Lua/P0 的 C 调用链比旧控制台深；core0 栈放在 SCRATCH_Y（4KB）。
  # core1 栈不能继续放在 SCRATCH_X：16KB 会溢出，改由 robot.c 在 BSS 里
  # 提供 16KB 栈并调用 multicore_launch_core1_with_stack()。
  target_compile_definitions(firmware PRIVATE
    PICO_CORE1_STACK_SIZE=0
    PICO_STACK_SIZE=0x1000
    )

  target_include_directories(firmware PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/include
    ${TINYUSB_PATH}/hw
    ${TINYUSB_PATH}/src
    ${UMAC_INCLUDE_PATHS}
    incbin
    )

  pico_generate_pio_header(firmware ${CMAKE_CURRENT_LIST_DIR}/src/pio_video.pio)

  pico_enable_stdio_uart(firmware 1)

  # Needed for UF2:
  pico_add_extra_outputs(firmware)

elseif(PICO_ON_DEVICE)
   message(WARNING "not building firmware because TinyUSB submodule is not initialized in the SDK")
endif()

