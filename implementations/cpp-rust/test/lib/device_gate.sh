#!/bin/sh
# device_gate.sh —— 真机用例统一跳过门（2026-09-20 重构阶段 5.2）
#
# 背景：同一条「本机没有真机设备就跳过」的规则此前有两份实现、且口径不一致——
#   run_all.sh   用 bash grep 逐个标记写两条 if（i2c / video）
#   CMakeLists   按**文件名**特判 test_jit_warmup.lua，于是同样带
#                "-- requires: video" 的 test_camera_v4l2.lua 被裸注册，
#                无摄像头机器上 `ctest -R lua_test_camera_v4l2` 报 Failed
#                而不是 Skipped（同仓库两条入口结论相反）。
# 现在两条入口都走本脚本，标记解析只有一处。
#
# 用法：device_gate.sh <lua 文件> <解释器> <脚本> [参数...]
#   - 文件内声明 `-- requires: <dev>`（行首）且本机无 /dev/<dev>* → 退出 125
#     （ctest 侧由 SKIP_RETURN_CODE 125 记为跳过；run_all.sh 同语义按跳过计）
#   - 无标记 → 直接执行（等价此前的裸注册）
set -eu

lua_file="$1"; shift
luacmd="$1"; shift

# 标记形如 "-- requires: i2c"，按**整文件**锚定行首匹配：test_jit_warmup.lua
# 的标记在第 6 行（重构前 run_all.sh 的 grep 也是整文件口径，不能收窄成头几行，
# 否则该用例会从「跳过」变成「真的去开 i2c」）。
# 只认设备名（字母/数字/下划线），免得把说明文字吃进来。
req="$(sed -n 's/^-- requires: *\([A-Za-z0-9_]*\).*/\1/p' "$lua_file" | head -1)"

# 显式指定设备路径时以它为准：测试体自己读 BOT4CJ_TEST_VIDEO（把回归指向别的
# 设备/软链），但跳过门排在它之前——不在这里放行，文档承诺的逃生阀永远不可达
# （2026-09-20 审计 M3：docs/testing.md 写了该变量，实现却在门就退出 125）。
if [ "$req" = "video" ] && [ -n "${BOT4CJ_TEST_VIDEO:-}" ]; then
	if [ -e "$BOT4CJ_TEST_VIDEO" ]; then
		exec "$luacmd" "$@"
	fi
	echo "[SKIP] BOT4CJ_TEST_VIDEO=$BOT4CJ_TEST_VIDEO 不存在，跳过"
	exit 125
fi

if [ -n "$req" ] && ! ls /dev/"$req"* >/dev/null 2>&1; then
	echo "[SKIP] 需要 /dev/${req}* 真机设备（文件标记 -- requires: $req），本机无 ${req}，跳过"
	exit 125
fi

exec "$luacmd" "$@"
