# Copyright 2024 Matt Evans
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation files
# (the "Software"), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software,
# and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
# ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# mybot-lite headless firmware
#
# 当前版本只构建 UART 控制台 + 机器人运行时，不包含 VGA/PIO/键鼠/USB HID。

cmake_minimum_required(VERSION 3.13)

set(SD_TX 3 CACHE STRING "SD SPI TX pin")
set(SD_RX 4 CACHE STRING "SD SPI RX pin")
set(SD_SCK 2 CACHE STRING "SD SPI SCK pin")
set(SD_CS 5 CACHE STRING "SD SPI CS pin")
set(SD_MHZ 5 CACHE STRING "SD SPI speed in MHz")

include(pico_sdk_import.cmake)
project(firmware)
pico_sdk_init()

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3")

# SD 是固定功能，不再提供无 SD 构建。
set(FF_DISABLE_RTC ${PICO_RP2350})
add_subdirectory(third_party/fatfs/FatFs_SPI build)
set(EXTRA_SD_SRC src/sd_hw_config.c)
set(EXTRA_SD_LIB FatFs_SPI)
add_compile_definitions(
  SD_TX=${SD_TX} SD_RX=${SD_RX} SD_SCK=${SD_SCK} SD_CS=${SD_CS} SD_MHZ=${SD_MHZ})

# ---------------------------------------------------------------------------
# Lua 5.1.5（vendored）：驱动运行时。
# LuaJIT 在 Cortex-M0+ 上不可用；Lua 5.1 保留 getfenv/setfenv，最接近现有
# modules/*.lua 的 LuaJIT 5.1 语法。只编译核心与标准库。
# ---------------------------------------------------------------------------
set(LUA_SRC_DIR ${CMAKE_CURRENT_LIST_DIR}/third_party/lua/src)
file(GLOB LUA_SOURCES ${LUA_SRC_DIR}/*.c)
list(REMOVE_ITEM LUA_SOURCES
  ${LUA_SRC_DIR}/lua.c
  ${LUA_SRC_DIR}/luac.c
  ${LUA_SRC_DIR}/print.c
  ${LUA_SRC_DIR}/liolib.c
  ${LUA_SRC_DIR}/loslib.c
  ${LUA_SRC_DIR}/linit.c
  )
add_library(lua51 STATIC ${LUA_SOURCES})
target_include_directories(lua51 PUBLIC ${LUA_SRC_DIR})
target_compile_options(lua51 PRIVATE -Wno-unused-parameter -Wno-sign-compare)

add_executable(firmware
  src/main.c
  src/console.c
  src/robot.c
  ${EXTRA_SD_SRC}
  )

pico_set_float_implementation(firmware default)
pico_set_double_implementation(firmware default)

target_link_libraries(firmware
  pico_stdlib
  pico_multicore
  pico_float
  pico_double
  pico_util
  hardware_sync
  hardware_i2c
  hardware_spi
  hardware_uart
  lua51
  m
  ${EXTRA_SD_LIB}
  )

# core0 栈 4KB；core1 的 16KB 栈由 robot.c 放在 BSS，并通过
# multicore_launch_core1_with_stack() 启动。
target_compile_definitions(firmware PRIVATE
  PICO_CORE1_STACK_SIZE=0
  PICO_STACK_SIZE=0x1000
  )

target_include_directories(firmware PRIVATE
  ${CMAKE_CURRENT_LIST_DIR}/include
  )

# 只使用硬件 UART0；USB 口不再承担 CDC/HID。
pico_enable_stdio_uart(firmware 1)
pico_enable_stdio_usb(firmware 0)

pico_add_extra_outputs(firmware)
