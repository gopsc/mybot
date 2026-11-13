# gen_const_check.cmake —— 从 Lua 源**抽取**硬件常量，生成 C 断言用的宏头（A2 收口）
#
# 背景（2026-09-20 审计 A2，严重）：`test_ioctl_nums.c` / `test_uart_consts.c`
# 声称把「HAL.lua 硬编码的编号」与系统头比对，实际却把那些数字**在 C 里又手抄了
# 一遍**，从不打开 Lua 源。于是 Lua 侧漂移完全不被发现。本脚本把链路接上：
# **Lua 源是唯一事实源**，构建期抽取为宏，再由 C 断言同时钉住「Lua 值 == 手抄的
# 预期值」（人写错/抽取失效会红）与「预期值 == 系统头」（内核/架构漂移会红）。
# 两侧都钉死，任一侧漂移构建即失败。
#
# 用法：cmake -DOUT=<生成的头文件> -DSRC=<仓库根> -P test/gen_const_check.cmake
#
# 2026-10-01 加固（P0 复发预防，2026-10-01 P0 的教训收口）：hal_backend_glibc.lua
# 的 consts 表改**执行期求值**（luajit 加载后端 → test/lib/dump_consts.lua 倒出
# M.consts 表），抽取契约从「正则模式 ↔ 书写风格」收窄为「后端导出 M.consts 表」
# 这一条既有接口契约——方案 A 下沉搬走常量时不再有隐式的书写风格耦合可断。
# hal/uart.lua 的波特率表保持纯文本抽取；抽取对**任何一方**失效都响亮失败
# （FATAL_ERROR），不静默降级。

if(NOT DEFINED OUT OR NOT DEFINED SRC)
  message(FATAL_ERROR "gen_const_check.cmake: 需要 -DOUT=<头文件> -DSRC=<仓库根>")
endif()

# require_const(<列表> <NAME>)：列表里必须有该 NAME，否则 FATAL_ERROR。
function(require_const lst name)
  foreach(entry IN LISTS lst)
    if(entry MATCHES "^${name}=")
      return()
    endif()
  endforeach()
  message(FATAL_ERROR
    "gen_const_check.cmake: 未能从 Lua 源抽取常量 '${name}' —— 常见成因："
    "源文件里的书写格式变了（本脚本按 `前缀<NAME> = <值>` 纯文本匹配），或该常量被删除/改名。"
    "抽取失效必须失败：静默生成空头会让常量自检退化为自证（A2 的原始缺陷形态）。")
endfunction()

set(SRC_MODULES "${SRC}/modules")

# 平台常量（ioctl 编号/termios/errno）的唯一事实源是后端 consts 表
# （hal_backend_glibc.lua 的 `local consts = { NAME = <值>, ... }`）；HAL.lua 自
# 方案 A 起只做 `HAL.X = _c.X` 重导出（26.2 按域拆分后 UART_* 那几项的重导出落在
# lib/hal/uart.lua，同样只是重导出），无字面量可抽。执行期求值（2026-10-01）：
# luajit 加载后端，dump_consts.lua 倒出 M.consts——抽取契约只剩「后端导出
# M.consts 表」，不再依赖表项书写风格。luajit 可执行文件是既有测试期依赖
# （test/lib/params.sh 的 LUACMD），CI 各 job 均已安装；README 依赖行同步。
find_program(MYBOT_LUAJIT_EXECUTABLE luajit PATHS ENV PATH)
if(NOT MYBOT_LUAJIT_EXECUTABLE)
  message(FATAL_ERROR
    "gen_const_check.cmake: 找不到 luajit 可执行文件——consts 表执行期抽取需要它"
    "（apt 侧为 'luajit' 包，与 libluajit-5.1-dev 分开装）。抽取失效必须失败："
    "静默生成空头会让常量自检退化为自证（A2 的原始缺陷形态）。")
endif()
execute_process(
  COMMAND "${MYBOT_LUAJIT_EXECUTABLE}" "${SRC}/test/lib/dump_consts.lua"
          "${SRC_MODULES}/lib/hal_backend_glibc.lua"
  RESULT_VARIABLE _const_dump_rc
  OUTPUT_VARIABLE _const_dump_out
  ERROR_VARIABLE _const_dump_err)
if(NOT _const_dump_rc EQUAL 0)
  message(FATAL_ERROR
    "gen_const_check.cmake: 执行期抽取 consts 表失败（rc=${_const_dump_rc}）：${_const_dump_err}"
    "——后端加载出错（语法/依赖/断言）或未导出 M.consts 表。")
endif()
# dump 输出形如「NAME=值」逐行——与 require_const/emit_defs 的列表格式同构。
string(REPLACE "\n" ";" HAL_ALL "${_const_dump_out}")

# 必须存在的常量（少一个就失败）——覆盖两个自检文件当前使用的全部编号/布局常量。
foreach(n IN ITEMS
    O_CLOEXEC
    I2C_RDWR I2C_M_RD
    SPI_IOC_WR_MODE SPI_IOC_WR_BITS_PER_WORD SPI_IOC_WR_MAX_SPEED_HZ SPI_IOC_MESSAGE_1
    GPIO_GET_LINEHANDLE GPIOHANDLE_GET_LINE_VALUES GPIOHANDLE_SET_LINE_VALUES
    UART_O_FLAGS UART_TCSANOW UART_TCIFLUSH UART_VMIN_IDX UART_VTIME_IDX UART_CREAD_CLOCAL)
  require_const("${HAL_ALL}" "${n}")
endforeach()

# UART 波特率映射表：`[<hz>] = <const>`（本地表，非 HAL. 字段）。两套表都要抽：
# 旧 ABI 编码（glibc < 2.42）与字面 Hz 编码（glibc >= 2.42），由 test_uart_consts.c
# 各自断言——两套都正确才说明 HAL 的运行时二选一逻辑两侧都有依据。
function(read_baud_table path varname out_var)
  file(READ "${path}" content)
  string(REGEX REPLACE "--[^\n]*" "" content "${content}")
  # 截取 `local UART_B_CONST_<varname> = {` 到下一个 `}` 之间的块
  string(REGEX MATCH "UART_B_CONST_${varname}[ \t]*=[ \t]*\\{([^}]*)\\}" block "${content}")
  if(block STREQUAL "")
    message(FATAL_ERROR "gen_const_check.cmake: 未找到 UART_B_CONST_${varname} 表块")
  endif()
  set(acc "")
  # 逐个 `[<hz>] = <值>` 取对；同一行多个条目也能覆盖（全局匹配）。
  string(REGEX MATCHALL "\\[([0-9]+)\\][ \t]*=[ \t]*([0-9A-Fa-fxX]+)" pairs "${block}")
  foreach(p IN LISTS pairs)
    string(REGEX MATCH "\\[([0-9]+)\\][ \t]*=[ \t]*([0-9A-Fa-fxX]+)" _ "${p}")
    list(APPEND acc "${CMAKE_MATCH_1}=${CMAKE_MATCH_2}")
  endforeach()
  list(LENGTH acc n)
  if(n LESS 13)
    message(FATAL_ERROR
      "gen_const_check.cmake: UART_B_CONST_${varname} 只抽到 ${n} 个条目（期望 13）")
  endif()
  set(${out_var} "${acc}" PARENT_SCOPE)
endfunction()

# 26.2 按域拆分：波特率表随 UART 段搬到 lib/hal/uart.lua（原在 HAL.lua）。
# 本脚本的抽取路径与被抽文件的落点是同一份契约，搬迁必须连这里一起改——
# 正是上面 2026-10-01 P0 记下的那条教训（抽取失效会 FATAL_ERROR，不静默）。
read_baud_table("${SRC_MODULES}/lib/hal/uart.lua" "LEGACY" BAUD_LEGACY)
read_baud_table("${SRC_MODULES}/lib/hal/uart.lua" "HZ" BAUD_HZ)

# ---- 生成头文件 ----
set(hdr "/* 本文件由 test/gen_const_check.cmake 在 cmake 配置期生成，请勿手工编辑。\n")
string(APPEND hdr " * 事实源：modules/lib/hal_backend_glibc.lua（consts 表，执行期求值）与 modules/lib/hal/uart.lua（纯文本抽取）。\n")
string(APPEND hdr " * 常量自检（test_ioctl_nums.c / test_uart_consts.c）\n")
string(APPEND hdr " * 用它把 Lua 值钉进 C 断言——A2：此前 C 里手抄数字，Lua 漂移无人发现。 */\n")
string(APPEND hdr "#pragma once\n\n")

function(emit_defs hdr_var prefix lst)
  set(buf "")
  foreach(entry IN LISTS lst)
    string(REGEX MATCH "^([^=]+)=(.*)$" _ "${entry}")
    set(name "${CMAKE_MATCH_1}")
    set(val "${CMAKE_MATCH_2}")
    string(APPEND buf "#define ${prefix}${name} (${val})\n")
  endforeach()
  set(${hdr_var} "${${hdr_var}}${buf}" PARENT_SCOPE)
endfunction()

emit_defs(hdr "HAL_CONST_" "${HAL_ALL}")
string(APPEND hdr "\n")
foreach(entry IN LISTS BAUD_LEGACY)
  string(REGEX MATCH "^([0-9]+)=(.*)$" _ "${entry}")
  string(APPEND hdr "#define HAL_BAUD_LEGACY_${CMAKE_MATCH_1} (${CMAKE_MATCH_2})\n")
endforeach()
string(APPEND hdr "\n")
foreach(entry IN LISTS BAUD_HZ)
  string(REGEX MATCH "^([0-9]+)=(.*)$" _ "${entry}")
  string(APPEND hdr "#define HAL_BAUD_HZ_${CMAKE_MATCH_1} (${CMAKE_MATCH_2})\n")
endforeach()

file(WRITE "${OUT}" "${hdr}")
message(STATUS "gen_const_check: 已从 Lua 源抽取常量 -> ${OUT}")
