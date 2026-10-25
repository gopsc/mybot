# mybot 3D 仿真器：独立 CMake 工程，刻意不被仓库根 CMakeLists.txt 引用。
#
# 原因：根工程的五条 CI job（release/sanitizer/tsan/clang/musl）都是
# `cmake --build` 全 target 构建，而 CI 基础镜像没有任何 GL/X11 库、musl
# 静态构建也编不过 GLFW。挂进根工程会直接把这五条打红。这里比照 agent/
# （Rust）的模式：自带工程 + scripts/build_sim.sh 独立构建。
#
# 目标分两层：
#   simcore   —— GL 无关的核心逻辑（运动学 + 五座 AF_UNIX 桥），可单测、可上 CI
#   mybot-sim —— GLFW/OpenGL 可视化壳，链接 simcore
#   sim_tests —— simcore 单元测试（无 GL 依赖，纯逻辑 + 本机 socket 回环）
#
# 构建：bash scripts/build_sim.sh，或
#   cmake -S sim -B sim/build && cmake --build sim/build
cmake_minimum_required(VERSION 3.20)
project(mybot-sim LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(FetchContent)

set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

FetchContent_Declare(glfw
    URL https://github.com/glfw/glfw/archive/refs/tags/3.4.tar.gz
)
FetchContent_Declare(glm
    URL https://github.com/g-truc/glm/archive/refs/tags/1.0.1.tar.gz
)
FetchContent_MakeAvailable(glfw glm)

find_package(Threads REQUIRED)

add_library(glad STATIC external/glad/src/glad.c)
target_include_directories(glad PUBLIC external/glad/include)

# ---- 核心层：不 include 任何 GL 头，只依赖 glm 头与 POSIX socket ----
add_library(simcore STATIC
    src/robot.cpp
    src/obb2d.cpp
    src/world.cpp
    src/scene_io.cpp
    src/sim_engine.cpp
    src/sim_paths.cpp
    src/unix_line_server.cpp
    src/request_bridge.cpp
    src/action_table.cpp
    src/bridge.cpp
    src/capture.cpp
    src/sensor.cpp
    src/imu.cpp
    src/odom.cpp
)
target_include_directories(simcore PUBLIC src)
target_link_libraries(simcore PUBLIC glm::glm Threads::Threads)

# 仓库场景模板目录：编译期定死（源码树内），供 SimPaths::templateScene 播种地图用。
# 与 sim_tests 的 MYBOT_MODULES_DIR 同款先例；PUBLIC 让 mybot-sim / sim_tests 都拿到。
target_compile_definitions(simcore PUBLIC
    MYBOT_SIM_SCENES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/scenes")

# ---- 可视化壳 ----
add_executable(mybot-sim
    src/main.cpp
    src/shader.cpp
    src/camera.cpp
    src/mesh.cpp
    src/spider.cpp
    src/framegrab.cpp
)
# external/stb：public-domain stb_image_write.h（JPEG 编码），仅 framegrab.cpp
# 定义 STB_IMAGE_WRITE_IMPLEMENTATION 一处引入实现。标 SYSTEM 让 -Wall -Wextra
# 不去警告这份第三方头（它自带一堆 -Wmissing-field-initializers），只查本仓代码。
target_include_directories(mybot-sim PRIVATE src)
target_include_directories(mybot-sim SYSTEM PRIVATE external/stb)
target_link_libraries(mybot-sim PRIVATE simcore glfw glad)

# ---- 核心层单测（无 GL；纯逻辑断言 + 本机 AF_UNIX 回环） ----
# 按域拆成多个 TU：入口/名册在 main.cpp，共享底座在 harness.{h,cpp}，套件声明在
# suites.h，用例正文在 test_{robot,world,scene,bridges,contract,engine}.cpp。
add_executable(sim_tests
    tests/main.cpp
    tests/harness.cpp
    tests/test_robot.cpp
    tests/test_world.cpp
    tests/test_scene.cpp
    tests/test_bridges.cpp
    tests/test_contract.cpp
    tests/test_engine.cpp
)
target_link_libraries(sim_tests PRIVATE simcore)
# 一致性守门要读 modules/Sim.lua 交叉校验动作码，路径在编译期定死（源码树内）
target_compile_definitions(sim_tests
    PRIVATE MYBOT_MODULES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../modules")

# 编译期扩展性守门。-Wall -Wextra 保持代码整洁；-Werror=switch 专治本仓最痛的
# 漏改：新增了 SimCommand / SimEvent::Type 枚举值，却忘了在 commandToInput /
# applyEvent 的 switch 里补对应 case——这两处 switch 刻意不写 default，就是为了让
# -Wswitch 生效，把「新动作静默 no-op」从运行期的隐蔽 bug 变成编译不过。
# 只对本地三个 target 生效，不碰 FetchContent 拉来的 glfw/glm/glad。
foreach(sim_tgt simcore mybot-sim sim_tests)
    target_compile_options(${sim_tgt} PRIVATE
        $<$<OR:$<CXX_COMPILER_ID:GNU>,$<CXX_COMPILER_ID:Clang>>:-Wall;-Wextra;-Werror=switch>)
endforeach()

enable_testing()
add_test(NAME sim_core COMMAND sim_tests)
