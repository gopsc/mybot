cmake_minimum_required(VERSION 3.16)
project(mybot LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# 静态分析（fix-plan 2026-09-20 阶段 D-3）：无条件导出 compile_commands.json，
# 供 clang-tidy 本地/CI 复用（对构建无副作用）。跑法见 docs/development.md 代码规范节。
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# LuaJIT：优先 pkg-config（linux 发行版已装 libluajit-5.1-dev 即有）
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(LUAJIT QUIET luajit)
endif()

if(LUAJIT_FOUND)
  message(STATUS "Found LuaJIT via pkg-config: ${LUAJIT_INCLUDE_DIRS}")
else()
  find_path(LUAJIT_INCLUDE_DIR
    NAMES lua.h lauxlib.h
    PATH_SUFFIXES luajit-2.1)
  find_library(LUAJIT_LIBRARY NAMES luajit-5.1 luajit)
  if(NOT LUAJIT_INCLUDE_DIR OR NOT LUAJIT_LIBRARY)
    message(FATAL_ERROR "LuaJIT not found. Install libluajit-5.1-dev (e.g. sudo apt install libluajit-5.1-dev)")
  endif()
  set(LUAJIT_INCLUDE_DIRS ${LUAJIT_INCLUDE_DIR})
  set(LUAJIT_LIBRARIES ${LUAJIT_LIBRARY})
endif()

# Sanitizer 开关（F-23）：随仓库分发、两个目标一致套用，避免各人手工拼
# CXX_FLAGS 造成「测试构建干净、主构建不干净」的错位。用法：
#   cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug \
#     -DMYBOT_SANITIZE=address,undefined
#   cmake -S . -B build-tsan -DCMAKE_BUILD_TYPE=Debug -DMYBOT_SANITIZE=thread
set(MYBOT_SANITIZE "" CACHE STRING
  "Sanitizer list applied to all targets (e.g. address,undefined or thread)")
if(MYBOT_SANITIZE)
  add_compile_options(-fsanitize=${MYBOT_SANITIZE} -fno-omit-frame-pointer -g)
  add_link_options(-fsanitize=${MYBOT_SANITIZE})
  # A1（2026-09-20 审计）：UBSan 缺省是 **recover** 模式——检出未定义行为只把
  # "runtime error: ..." 打到 stderr，**退出码仍是 0**。而 run_all.sh 只认
  # 退出码 / [FAIL] 行 / [DONE] 完成标记，于是 docs/testing.md 列为「硬门禁」
  # 的 gate:sanitizer 对 UBSan 类缺陷（有符号溢出、错位访问、非法移位/枚举）
  # 结构上不可能变红：实测 `int x=INT_MAX; x=x+1;` 用本工程同款标志编译，
  # 打印 runtime error 而 exit 0；加 -fno-sanitize-recover=all 后 exit 1。
  # 只对非 thread 组合施加：TSan 的 halt_on_error 由 gate:tsan 经 TSAN_OPTIONS
  # 单独控制（见 .gitlab-ci.yml），此处不重复。指名 undefined 而非 ${MYBOT_SANITIZE}：
  # ASan 本身即 fail-fast（且 run_san.sh 已带 halt_on_error），需要被强制终止的
  # 只有 recover 语义的 UBSan；这样 -DMYBOT_SANITIZE=address 单独用时也不会
  # 因指定一个未启用的 sanitizer 而报错。
  if(NOT MYBOT_SANITIZE STREQUAL "thread")
    add_compile_options(-fno-sanitize-recover=undefined)
  endif()
  # 2026-09-25：sanitizer 构建里**不**做 PR_SET_DUMPABLE=0 进程自护（src/main.cpp
  # hardenAgainstInspection）。LeakSanitizer 退出时 fork 一个 tracer 子进程
  # ptrace 回父进程做 StopTheWorld；父进程 non-dumpable 后同 UID 的 tracer 被内核
  # 拒绝 attach，LSan 直接失败——gate:sanitizer 会因此假红。sanitizer 产物本就
  # 只在开发/CI 用，不是部署形态。
  add_compile_definitions(MYBOT_SANITIZE_BUILD=1)
endif()

# ======================================================================
# agent 模式：--mcp-backend 让大模型工具循环成为主执行流程（工具后端半边），
# 机器人结构脚本加载后硬件常驻内存。
#
# 模型调用**不引入任何链接期依赖**：它由独立的 Rust 二进制 mybot-agent 直连
# provider（reqwest + rustls；2026-09-25 #8 起 Lua 协议驱动轨道整条删除，此前
# 经 LuaJIT ffi 运行期加载 libcurl 的那条路径已不复存在）。因此本工程的
# 「零第三方 C++ 依赖（仅 LuaJIT + pthread + dl）」承诺依旧成立。
# ======================================================================

# 被测主体（不含入口 main.cpp）：mybot 与 mybot_tests 共用同一份，
# 保证单测编译的正是发布二进制里的那套实现，而不是第二份拷贝。
#
# 2026-10-04 分组：此前 50 个文件平铺，领域边界只存在于文件名里。现按编译单元
# 所属领域分段——**只重排、不增删**（下方 B8 自检判据因此一字不变，段内亦保持
# 原相对次序）。段序自下而上：语言/序列化基元（JSON/配置/矩阵/Lua）→ 领域层
# （硬件/装配执行/机器人门面/热插）→ 装配面（通道与 CLI/agent/MCP）→ 应用编排。
set(MYBOT_CORE_SOURCES
  # ---- JSON 层：词法/语法解析、序列化、配置文件读取 ----
  src/json.cpp
  src/jsonparse.cpp
  src/jsonconfig.cpp
  # ---- 配置层：模型接入参数（CLI 与配置文件两路归一） ----
  src/llmconfig.cpp
  # ---- 矩阵/表达式/脚本语法层：.mt 与结构 SQL 的解析基元 ----
  src/matrix.cpp
  src/expr.cpp
  src/sqlparse.cpp
  src/structure.cpp          # ScriptLoader：SQL 事件 → MatrixObject
  src/mtmerge_core.cpp       # .mt 归并核心（mtinclude 运行端展开 + test_mtmerge 白盒）
  src/mtinclude.cpp          # @Include 展开
  # ---- Lua 层：桥接、沙箱与执行预算 ----
  src/luabridge.cpp
  src/luasandbox.cpp
  src/luaexec.cpp
  # ---- 硬件域：变量基类、Lua/Daemon 变量、注册表与元数据 ----
  src/hardware.cpp
  src/luavar.cpp
  src/daemonvar.cpp
  src/daemon_registry.cpp
  src/daemonconf.cpp
  src/hw_registry.cpp
  src/meta_provider.cpp
  src/meta_registry.cpp
  # ---- 硬件装配与动作执行：矩阵表 → 变量，@Action 派发与重放 ----
  src/hw_factory.cpp
  src/action_runner.cpp
  # ---- 机器人门面：生命周期/动作/驱动注入/热 SQL 四个 TU（robot.hpp 门面） ----
  src/robot_lifecycle.cpp
  src/robot_actions.cpp
  src/robot_driver.cpp
  src/robot_hotsql.cpp
  # ---- 热插域：只读计划层与提交服务 ----
  src/hotsql_plan.cpp
  src/hotsql_service.cpp
  # ---- 输入通道与 CLI 解析（--input/stdin/TCP 与选项表） ----
  src/actionsource.cpp
  src/cliargs.cpp
  src/cliargs_help.cpp
  # ---- agent 域：进程自护、帧协议、工具、视图、提示词、审计、策略与模式 ----
  src/agent_subprocess.cpp
  src/agent_envscrub.cpp
  src/agent_fdguard.cpp
  src/agentproto.cpp
  src/agenttools.cpp
  src/agenttools_wait.cpp
  src/agentview.cpp
  src/agentimage.cpp
  src/agenttools_fs.cpp
  src/agentdispatch.cpp
  src/agentprompt.cpp
  src/agentmode.cpp
  src/agentaudit.cpp
  src/agentpolicy.cpp
  # ---- MCP 后端：帧通道、监听、工具后端与 context.get 素材 ----
  src/mcpbackend.cpp
  src/mcplisten.cpp
  src/mcptransport.cpp
  src/context_service.cpp
  # ---- 应用编排：把上面各域串成 --input/stdin/TCP/agent 四条运行路径 ----
  src/robot_application.cpp
  src/wsproto.cpp
  src/webterm.cpp
  src/webshell.cpp
)

# 两个目标的公共配置：零告警基线 + 头文件路径，一处声明一致套用，
# 避免「测试构建干净、主构建不干净」的错位（原先两份拷贝靠人工同步）。
#
# MYBOT_WERROR（2026-09-20 重构阶段 5.3）：把「零告警」从约定升级为门禁。
# 为什么不无条件加 -Werror：本项目要在**未预跑的编译器版本**上也能构建成功
#（CI 基线 debian:bookworm 的 g++12、树莓派发行版编译器都可能报出别家前端
# 才有的告警），无条件 -Werror 会把「换台机器就构建不过」引进来。故做成开关：
# 本地缺省 OFF（保持原取向），CI 的 build:release 显式 -DMYBOT_WERROR=ON——
# 门禁落在「有基线、可复现」的那台机器上。
option(MYBOT_WERROR "Treat -Wall/-Wextra/-Wpedantic warnings as errors" OFF)

add_library(mybot_warnings INTERFACE)
target_compile_options(mybot_warnings INTERFACE -Wall -Wextra -Wpedantic)
if(MYBOT_WERROR)
  target_compile_options(mybot_warnings INTERFACE -Werror)
endif()
target_include_directories(mybot_warnings INTERFACE src ${LUAJIT_INCLUDE_DIRS})

# Lua 运行时链接（仅 mybot / mybot_tests）
add_library(mybot_common INTERFACE)
target_link_libraries(mybot_common INTERFACE
  mybot_warnings
  ${LUAJIT_LIBRARIES}
  pthread
  dl
  m
  util
)

add_executable(mybot
  src/main.cpp
  ${MYBOT_CORE_SOURCES}
)

# README 声称的零告警基线由此处强制执行（此前构建未启用任何告警标志，
# 基线只能靠人工手工传标志核查）。不加 -Werror：避免在未测试的编译器版本上直接构建失败。
target_link_libraries(mybot PRIVATE mybot_common)

# ======================================================================
# C++ 层单元测试（test/cpp/）：零第三方框架，harness.hpp 自带断言与注册。
# 与被测程序共用同一套源文件（除 main.cpp），因此不需要 mybot 变成库目标。
# ======================================================================
add_executable(mybot_tests
  test/cpp/main.cpp
  test/cpp/test_json.cpp
  test/cpp/test_jsonparse.cpp
  test/cpp/test_llmconfig.cpp
  test/cpp/test_llmconfig_assembly.cpp
  test/cpp/test_llmconfig_surface.cpp
  test/cpp/test_matrix.cpp
  test/cpp/test_expr.cpp
  test/cpp/test_sqlparse.cpp
  test/cpp/test_sqlparse_query.cpp
  test/cpp/test_util.cpp
  test/cpp/test_cliargs.cpp
  test/cpp/test_hardware.cpp
  test/cpp/test_hw_registry.cpp
  test/cpp/test_meta_registry.cpp
  test/cpp/test_structure_store.cpp
  test/cpp/test_robot.cpp
  test/cpp/test_robot_dispatch.cpp
  test/cpp/test_action_if.cpp
  test/cpp/test_action_while.cpp
  test/cpp/test_action_nesting.cpp
  test/cpp/test_action_capture.cpp
  test/cpp/test_robot_lifecycle.cpp
  test/cpp/test_robot_hotsql_plan.cpp
  test/cpp/test_robot_hotinsert.cpp
  test/cpp/test_robot_hotdelete.cpp
  test/cpp/test_robot_hotupdate.cpp
  test/cpp/test_luaend.cpp
  test/cpp/test_luavar.cpp
  test/cpp/test_actionsource.cpp
  test/cpp/test_daemon.cpp
  test/cpp/test_daemon_concurrency.cpp
  test/cpp/test_mtmerge.cpp
  test/cpp/test_mtinclude.cpp
  test/cpp/test_agentproto.cpp
  test/cpp/test_agenttools.cpp
  test/cpp/test_agenttools_wait.cpp
  test/cpp/test_agenttools_sql.cpp
  test/cpp/test_agenttools_image.cpp
  test/cpp/test_agenttools_runcommand.cpp
  test/cpp/test_agenttools_subproc.cpp
  test/cpp/test_agenttools_fs.cpp
  test/cpp/test_agentaudit.cpp
  test/cpp/test_agentpolicy.cpp
  test/cpp/test_mcpbackend.cpp
  test/cpp/test_mcptransport.cpp
  test/cpp/test_mcplisten.cpp
  test/cpp/test_agenttools_sandbox.cpp
  test/cpp/test_wsproto.cpp
  test/cpp/test_webterm.cpp
  test/cpp/test_webshell.cpp
  src/mtmerge_core.cpp
  ${MYBOT_CORE_SOURCES}
)

target_include_directories(mybot_tests PRIVATE test/cpp)
# 源码根路径：让单测能锚定 docs/ 与仓库夹具（--help 黄金测试据此比对
# docs/reference.md 的选项表），不依赖运行期 CWD。
target_compile_definitions(mybot_tests PRIVATE MYBOT_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
# A6：子进程路径自报探针（AG-11，读 BOT4CJ_TRACE_FDS 并 open 该路径）只在测试构建
# 里存在。MYBOT_CORE_SOURCES 被 mybot 与 mybot_tests **各自编译一份**（见上方注释），
# 所以 per-target 定义能真正做到「生产二进制里没有这条代码路径」。
target_compile_definitions(mybot_tests PRIVATE MYBOT_TEST_TRACE_FDS)
target_link_libraries(mybot_tests PRIVATE mybot_common)

# ======================================================================
# 测试骨架自证（2026-09-21 审计 AG-5）：harness.hpp 的「零断言即失败 / TH_SKIP
# 不算失败 / 断言后跳过算失败」三条判据，用一份独立的 th 状态自证。独立二进制
# 的理由见文件头（元数据例句故意含失败形态，不能混进 mybot_tests 的计数）。
# ======================================================================
add_executable(harness_selftest test/cpp/harness_selftest.cpp)
target_include_directories(harness_selftest PRIVATE test/cpp)
add_test(NAME cpp_harness_selftest COMMAND harness_selftest)

enable_testing()
add_test(NAME cpp_unit COMMAND mybot_tests)
# 用例以相对路径（./modules/...、robots/test/...）读 fixtures，必须以仓库根为工作目录
set_tests_properties(cpp_unit PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})

# ======================================================================
# 常量一致性自检（F-24）：把 Lua 源里硬编码的 ioctl/termios/V4L2 编号
# 与系统头文件编译期比对——换内核/换架构导致常量漂移时构建即失败；三个二进制
# 再由 run_all.sh 在执行期跑一遍（构建期断言之外的双保险）。
#
# A2（2026-09-20 审计）：此前自检把 Lua 里的数字**在 C 里又手抄一遍**，
# 从不读 Lua 源，于是「Lua 侧漂移」这一半完全不被发现（实测改
# HAL.SPI_IOC_WR_MODE 后全部目标仍绿）。现在配置期先用
# test/gen_const_check.cmake 从 modules/lib/hal_backend_glibc.lua（consts 表，
# 2026-09-30 方案 A 下沉后的唯一事实源）、modules/lib/hal/uart.lua（两套波特率
# 映射表，26.2 按域拆分前在 HAL.lua 的 uart 段）、modules/Camera.lua 抽取真实值生成
# const_lua.h，断言对**两侧**各钉一次：
# Lua 抽取值 == 手抄预期值（抽取生效 + Lua 未漂移）+ 预期值 == 系统头。
# consts 表走**执行期求值**（luajit + test/lib/dump_consts.lua，2026-10-01 加固：
# 2026-10-01 P0 的教训「抽取模式与被抽文件的书写风格是同一份契约」由此收口——
# 契约只剩「后端导出 M.consts 表」）；Camera.lua 仍为纯文本抽取（其顶层会执行
# 整套 HAL 加载，不宜在配置期跑）。抽不到/执行失败即 FATAL_ERROR（静默生成
# 空头会让断言退化成自证，正是 A2 的原始缺陷形态）。
# 2026-09-25 #8：llm_http.lua 的 CURLOPT 抽取与 test_curl_consts 随 Lua 协议
# 驱动轨道整条删除——libcurl 已无任何代码使用，该自检无对象。
# ======================================================================
set(MYBOT_CONST_LUA_H "${CMAKE_BINARY_DIR}/const_lua.h")
execute_process(
  COMMAND ${CMAKE_COMMAND}
    -DOUT=${MYBOT_CONST_LUA_H}
    -DSRC=${CMAKE_SOURCE_DIR}
    -P ${CMAKE_SOURCE_DIR}/test/gen_const_check.cmake
  RESULT_VARIABLE _const_gen_rc
  ERROR_VARIABLE _const_gen_err)
if(NOT _const_gen_rc EQUAL 0)
  message(FATAL_ERROR "常量抽取失败（test/gen_const_check.cmake）：\n${_const_gen_err}")
endif()

add_executable(test_ioctl_nums test/test_ioctl_nums.c)
add_executable(test_uart_consts test/test_uart_consts.c)
add_executable(test_v4l2_consts test/test_v4l2_consts.c)
foreach(_const_target test_ioctl_nums test_uart_consts test_v4l2_consts)
  target_include_directories(${_const_target} PRIVATE ${CMAKE_BINARY_DIR})
endforeach()
add_test(NAME const_ioctl COMMAND test_ioctl_nums)
add_test(NAME const_uart COMMAND test_uart_consts)
add_test(NAME const_v4l2 COMMAND test_v4l2_consts)

# ======================================================================
# Lua 离线回归逐用例注册（run_all.sh 保持主编排入口不变）：
# 每个 test_*.lua 都是 `luajit test/xxx.lua` 可单跑的独立用例（HAL 依赖 ffi
# 必须 LuaJIT）。真机用例（文件头 "-- requires: i2c" / "video"）经
# test/lib/device_gate.sh 包装：本机无对应 /dev/<dev>* 时以 125 退出，
# 由 SKIP_RETURN_CODE 记为跳过——**不再按文件名特判**（阶段 5.2 前只特判
# test_jit_warmup.lua，导致同样带 video 标记的 test_camera_v4l2.lua 被裸注册，
# 无摄像头机器上 ctest 报 Failed 而不是 Skipped）。标记解析与 run_all.sh 同源。
# 收益：ctest -R lua_ 获得逐用例粒度与超时，不必整段跑完 run_all.sh 守门脚本。
# ======================================================================
file(GLOB MYBOT_LUA_TESTS CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/test/test_*.lua)
find_program(LUAJIT_EXECUTABLE NAMES luajit)
# F3-5 余部③：单测超时唯一来源 test/lib/params.sh（run_all.sh 的 timeout 前缀
# 与 docs/testing.md 同源）。bash 侧直接 source；这里 file(STRINGS) + 正则提取
# `: "${TEST_TIMEOUT:=N}"` 的默认值。单点被破坏（条目缺失/格式漂移）即 configure
# 失败——比静默回落某个手抄值诚实。
file(STRINGS "${CMAKE_SOURCE_DIR}/test/lib/params.sh" MYBOT_PARAMS_LINES)
set(MYBOT_LUA_TEST_TIMEOUT "")
foreach(_p IN LISTS MYBOT_PARAMS_LINES)
	if(_p MATCHES "^: \"\\$\\{TEST_TIMEOUT:=([0-9]+)\\}\"")
		set(MYBOT_LUA_TEST_TIMEOUT "${CMAKE_MATCH_1}")
	endif()
endforeach()
if(MYBOT_LUA_TEST_TIMEOUT STREQUAL "")
	message(FATAL_ERROR "test/lib/params.sh 缺 TEST_TIMEOUT 默认值（守门常量单点被破坏，F3-5）")
endif()
if(LUAJIT_EXECUTABLE)
	foreach(lua_test IN LISTS MYBOT_LUA_TESTS)
		get_filename_component(lua_name "${lua_test}" NAME)
		add_test(NAME lua_${lua_name}
			COMMAND ${CMAKE_SOURCE_DIR}/test/lib/device_gate.sh
				"${lua_test}" ${LUAJIT_EXECUTABLE} "${lua_test}")
		set_tests_properties(lua_${lua_name} PROPERTIES
			WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
			TIMEOUT ${MYBOT_LUA_TEST_TIMEOUT}
			SKIP_RETURN_CODE 125
			ENVIRONMENT "LUACMD=${LUAJIT_EXECUTABLE}")
	endforeach()
else()
	# C2（2026-09-20 审计 / 2026-09-21 落地）：luajit 缺失时**不得静默注册 0 个
	# Lua 用例**——否则 docs/testing.md 声称的 Lua 离线回归在无 luajit 机器上
	# 退化成「没跑却全绿」，与真机用例跳过同属静默变薄。显式 WARNING（构建
	# 日志可见）+ 注册一个 125=SKIP 的守卫测试，让 `ctest -R lua_` 仍能反映出
	# 「本环境无 luajit」而非「什么都没发生」。
	message(WARNING
		"luajit not found in PATH: test/test_*.lua Lua regression tests are NOT "
		"registered (docs/testing.md 声称的 Lua 离线回归在本机静默降级为空跑). "
		"Install luajit (apt install luajit) to enable them. "
		"lua_registration_guard 以 SKIP 标记暴露此状态。")
	add_test(NAME lua_registration_guard
		COMMAND sh -c "exit 125")
	set_tests_properties(lua_registration_guard PROPERTIES
		WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
		SKIP_RETURN_CODE 125)
endif()

# ======================================================================
# C3（2026-09-20 审计 / 2026-09-21 落地；2026-10-04 收敛掉第三份清单）：
# C++ 单测清单一致性自检。新 test/cpp/test_*.cpp 若不进上方 mybot_tests 的
# add_executable 显式清单，它会**永不编译**（静默）且守门照绿。
# 判据：磁盘上的 test/cpp/test_*.cpp 集合 == mybot_tests 实际编进去的那部分
# （双向；main.cpp 是测试入口，不在此列），不一致即 FATAL_ERROR。
# 此前中间还手抄了一份 MYBOT_CPP_TEST_REGISTERED 裸名清单、只校验 glob ⊆ 它——
# 那是第三份事实源，且方向单一（add_executable 漏写、清单里留旧名都不红）。
# 现在直接问 target 要 SOURCES，两份清单合成一份。
# ======================================================================
file(GLOB MYBOT_CPP_TEST_SRCS CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/test/cpp/test_*.cpp)
get_target_property(_mybot_tests_srcs mybot_tests SOURCES)
set(_compiled_test_names)
foreach(_s IN LISTS _mybot_tests_srcs)
  if("${_s}" MATCHES "(^|/)test/cpp/test_[^/]+\\.cpp$")
    get_filename_component(_n "${_s}" NAME_WE)
    list(APPEND _compiled_test_names "${_n}")
  endif()
endforeach()
set(_disk_test_names)
foreach(_t IN LISTS MYBOT_CPP_TEST_SRCS)
  get_filename_component(_n "${_t}" NAME_WE)
  list(APPEND _disk_test_names "${_n}")
endforeach()
set(_missing_registered)
foreach(_n IN LISTS _disk_test_names)
  if(NOT _n IN_LIST _compiled_test_names)
    list(APPEND _missing_registered "${_n}")
  endif()
endforeach()
if(_missing_registered)
  message(FATAL_ERROR
    "未登记的 C++ 测试（不会编译/守门将漏跑，须在 mybot_tests 的 add_executable 补上）："
    "${_missing_registered}")
endif()
set(_stale_registered)
foreach(_n IN LISTS _compiled_test_names)
  if(NOT _n IN_LIST _disk_test_names)
    list(APPEND _stale_registered "${_n}")
  endif()
endforeach()
if(_stale_registered)
  message(FATAL_ERROR
    "mybot_tests 的 add_executable 里有磁盘上不存在的 test/cpp/test_*.cpp"
    "（删了或改名了没同步清单）：" "${_stale_registered}")
endif()

# ======================================================================
# B8（2026-09-21 落地）：src/*.cpp 与 target 源集合一致性自检。
# 与上面的 test/cpp 自检同族：src/ 下新增一个 .cpp 却忘了写进任何 target，
# 它就永不编译——若该文件只被 include 或被误当成"已经在编"，构建与守门照绿。
# 判据：src/*.cpp 必须恰好被「MYBOT_CORE_SOURCES ∪ 各 target 的入口源」覆盖
# （main.cpp 属 mybot，不在 core 清单里）。
# ======================================================================
file(GLOB MYBOT_ALL_SRC CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/src/*.cpp)
set(MYBOT_REGISTERED_SRC ${MYBOT_CORE_SOURCES} src/main.cpp)
set(_reg_names)
foreach(_r IN LISTS MYBOT_REGISTERED_SRC)
  get_filename_component(_rn "${_r}" NAME)
  list(APPEND _reg_names "${_rn}")
endforeach()
set(_missing_src)
foreach(_s IN LISTS MYBOT_ALL_SRC)
  get_filename_component(_sn "${_s}" NAME)
  if(NOT _sn IN_LIST _reg_names)
    list(APPEND _missing_src "${_sn}")
  endif()
endforeach()
if(_missing_src)
  message(FATAL_ERROR
    "未登记的 src 源文件（不进任何 target，构建与守门都会漏掉它；"
    "请加入 MYBOT_CORE_SOURCES 或对应 target）：" "${_missing_src}")
endif()

# 安装产物：mybot 直跑 ./build/mybot（bot4cj 原 _run.sh 的等价物，见 test/run_all.sh）
install(TARGETS mybot RUNTIME DESTINATION bin)