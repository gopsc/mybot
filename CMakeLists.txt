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
   add_subdirectory(external/no-OS-FatFS-SD-SPI-RPi-Pico/FatFs_SPI build)
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
add_compile_definitions(GPIO_VID_BASE=${VIDEO_PIN})

if (TARGET tinyusb_device)
  add_executable(firmware
    src/main.c
    src/video.c
    src/chsf.c
    src/chsf32.c
    src/kbd.c
    src/hid.c
    src/cncc.c
    src/graph/basic.c
    #src/graph/bezier.c
    src/mathh/lagrange.c
    src/mathh/fft1.c
    #src/interpreter/try.c
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
    tinyusb_host
    tinyusb_board
    hardware_dma
    hardware_pio
    hardware_sync
    m
    ${EXTRA_SD_LIB}
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

