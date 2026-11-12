# test/lib/params.sh —— 守门常量单点（F3-5 余部②③）
#
# 此前两处常量各有多份手抄：sanitizer 构建目录（run_san.sh ×2 ↔ .gitlab-ci.yml
# 的 gate:sanitizer）、单测超时（run_all.sh ↔ CMakeLists ctest TIMEOUT ↔
# docs/testing.md）。改一处忘一处就静默漂移。
#
# 格式约定：bash 环境优先默认 `: "${KEY:=v}"`——bash 侧直接 source（调用方
# 环境已设的值保留，params 只补默认）；CMake 侧 file(STRINGS) + 正则提取
# `:=` 之后的默认值。新增常量时三处消费方（bash / CMake / CI）同步，
# 并入 run_all_selftest.sh 的单点校验。

# Lua/C++ 单测超时秒数（run_all.sh 的 timeout 前缀；ctest TIMEOUT 同源）
: "${TEST_TIMEOUT:=60}"

# 加固段用例超时秒数（hardening 段各用例的 timeout 前缀）
: "${HARDENING_TIMEOUT:=20}"

# 大文件/长动用例超时秒数（action_toolarge/sql_toolarge/daemon 等）
: "${HEAVY_TIMEOUT:=30}"

# SIGTERM 到 SIGKILL 的击杀宽限秒数（run_all.sh 的 timeout -k；issue #40）。
# timeout 到点只发 SIGTERM 并无限等待——子进程忽略/屏蔽 TERM（卡在不可中断
# 调用、或引入了信号处理）时整条守门流水线永久挂死（实测：卡死的 mybot_tests
# 让 timeout 60 存活 4 分 05 秒不收尸）。-k 提供 SIGKILL 逃生口，预算本身不动。
: "${TEST_KILL_GRACE:=15}"

# sanitizer 构建目录（run_san.sh 第二跑产物路径；gate:sanitizer 构建路径同源）
: "${SAN_DIR:=build-asan}"
