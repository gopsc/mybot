#!/usr/bin/env bash
# 构建 mybot 3D 仿真器（sim/：GLFW/OpenGL 蜘蛛机器人可视化从端）。
# 刻意不碰根 CMake——根工程的五条 CI job（release/sanitizer/tsan/clang/musl）
# 都是 `cmake --build` 全 target 构建，而 CI 基础镜像没有任何 GL/X11 库、
# musl 静态构建也编不过 GLFW。这里比照 agent/（Rust）的模式做独立工程。
# sim/build/ 已被 .gitignore 的 build/ 规则覆盖。
#
# 用法：bash scripts/build_sim.sh [额外的 cmake configure 参数...]
#   缺省构建 Release，产物在 sim/build/mybot-sim，并跑 simcore 单测（sim_tests）
#
# 跑起来：
#   bash scripts/build_sim.sh
#   ./sim/build/mybot-sim                       # 监听 /tmp/mybot-sim.sock
#   socat - UNIX-CONNECT:/tmp/mybot-sim.sock    # 手测：敲 forward / stop
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

cmake -S "$root/sim" -B "$root/sim/build" -DCMAKE_BUILD_TYPE=Release "$@"
cmake --build "$root/sim/build" -j"$(nproc)"

# simcore 单测：无 GL 依赖，毫秒级，构建立即跑，别让坏核心逻辑过夜
ctest --test-dir "$root/sim/build" --output-on-failure

echo "产物: $root/sim/build/mybot-sim"
