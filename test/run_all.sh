#!/bin/bash
# bot4cj Lua 离线测试统一入口
# 用法: bash test/run_all.sh [测试名过滤]
#   例: bash test/run_all.sh                # 跑全部
#       bash test/run_all.sh pca9685       # 只跑文件名含 pca9685 的
#       bash test/run_all.sh agent-all     # agent 全表面（见顶部 filter_* 映射）：
#                                          #   Lua test_llm_*.lua + agent E2E +
#                                          #   C++ 作用域 agent: + agent 负路径
#   注意：裸 agent / agent: 各只覆盖一半表面（子串 vs 作用域 vs 分段门不同），
#   要「agent 全跑」请用 agent-all（AG-23）。agent-all 的覆盖由 filter_* 映射与
#   agent_lua_roster **自证**：roster 里的文件必须存在且真的会跑到，反向漏登记
#   也判失败（SAN-2——此前映射指向一个从未存在的 test_agent*.lua，Lua 段实跑 0 个文件）。
# 说明：
#   - 统一用 luajit 运行（HAL 依赖 ffi）；可用环境变量 LUACMD 覆盖解释器
#   - 单测超时 TEST_TIMEOUT 秒（默认取 test/lib/params.sh 单点，需 coreutils
#     timeout；缺失则不限时）——防单个用例死循环挂死整个入口
#   - test_jit_warmup.lua 是真机 ABI 回归（需 /dev/i2c-*）、test_camera_v4l2.lua 是
#     真机摄像头回归（需 /dev/video*）：文件首行标记 -- requires: i2c / video，无设备自动跳过
#   - 守门完整性：编译产物（mybot / mybot_tests）缺失的分段**判失败**而非静默跳过——
#     否则整段 C++ 守门可以在不构建的情况下消失而汇总仍报「0 失败」。
#     仅两类例外按跳过计（汇总里以「N 跳过 + 未执行清单」显式可见）：
#     真机 i2c 用例（本机无 /dev/i2c-*）、TCP/agent 段缺 python3（README 声明的
#     软依赖）。agent 端到端不依赖 libcurl：Lua 协议驱动轨道已删（2026-09-25 #8），
#     模型调用由 Rust mybot-agent 直连（reqwest + rustls）。
#     只想跑 Lua 段的逃生口：ALLOW_SKIP=1 bash test/run_all.sh
#     （显式给了 BOT=/BOT_TESTS= 却指向不存在的文件，一律判失败，ALLOW_SKIP 也不放行）
#   - test_ioctl_nums.c 为 C 编译期常量自检，不在本入口范围
# 本文件绝对路径：下面 cd 之后相对 $0 不再可解析，而 count_calls 靠它数用例
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

LUACMD="${LUACMD:-luajit}"
if ! command -v "$LUACMD" >/dev/null 2>&1; then
	echo "未找到解释器：$LUACMD"	
	echo "HAL 依赖 ffi，请安装 LuaJIT：sudo apt install luajit"
	echo "（或 LUACMD=lua5.4 只跑纯 Lua 用例，HAL 相关用例会失败）"
	exit 1
fi

# 守门常量单点（F3-5 余部）：TEST_TIMEOUT 唯一来源 test/lib/params.sh——
# ctest 的 TIMEOUT（CMakeLists 正则提取同一文件）与 docs/testing.md 同源；
# 环境已设的 TEST_TIMEOUT 优先于 params 默认。
. test/lib/params.sh || { echo "params 单点缺失：test/lib/params.sh" >&2; exit 1; }
if ! [ "${TEST_TIMEOUT:-}" -gt 0 ] 2>/dev/null; then
	echo "params 单点失效：TEST_TIMEOUT 非正整数（test/lib/params.sh）" >&2
	exit 1
fi
if ! [ "${TEST_KILL_GRACE:-}" -gt 0 ] 2>/dev/null; then
	echo "params 单点失效：TEST_KILL_GRACE 非正整数（test/lib/params.sh）" >&2
	exit 1
fi
timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
	# -k（宽限见 params.sh TEST_KILL_GRACE，issue #40）：到点 TERM 之后
	# 子进程若无视（屏蔽/卡死），SIGKILL 兜底——否则 timeout 自身会无限
	# 等待，整条守门流水线挂死（实测复现过）。
	timeout_cmd="timeout -k $TEST_KILL_GRACE $TEST_TIMEOUT"
fi

# mybot-agent 产物新鲜度判据单点（取材面见该文件头注）：守门的 agent-rust-e2e /
# ica-e2e 两段与 scripts/git-hooks/pre-push 共用同一份，别在调用处再手抄一遍 find。
. test/lib/agent_stale.sh || { echo "判据单点缺失：test/lib/agent_stale.sh" >&2; exit 1; }

filter="${1:-}"
# ---- 分段过滤器（AG-23，2026-09-21 第三轮审计）----
# 一个 raw 过滤器要在四类分段上用**不同形态**匹配，此前没做区分，于是
# `agent` 与 `agent:` 各只覆盖一半表面：
#   * `bash test/run_all.sh agent`  -> 0 个 Lua 用例（test_*.lua 文件名里没有
#     agent）、C++ 走**子串**只命中 89 例（作用域里那 15 条 agentconfig_/
#     agentmode_ 因名字不含 "agent" 被漏掉）、agent 的 CLI 负路径也跑不到；
#   * `bash test/run_all.sh agent:` -> 反过来：加固段比的是 "agent" 与 "agent:"
#     （不相等）=> **跳过 agent 端到端**；C++ 侧确实是作用域匹配，但两侧口径不统一。
# 现在把「哪个分段该拿哪种过滤器」收敛成单点，并给出覆盖全表面的入口：
#   agent-all -> Lua 段与端到端拿 "agent"，C++ 拿作用域 "agent:"，加固段拿 "agent_"
# 裸 agent / agent: 的语义保持不变（不破坏既有用法），只是文档不再把它们当作
# 「agent 全表面」的推荐入口。
filter_lua="$filter"		# test/test_*.lua 的文件名子串
filter_e2e="$filter"		# scripts/agent_e2e.sh 等端到端分段
filter_hardening="$filter"	# 加固负路径（agent 子块单独设门，见文件后段）
filter_cpp="$filter"		# mybot_tests 的过滤器（支持 scope: 语法）
if [ "$filter" = "agent-all" ]; then
	# SAN-2（2026-09-22）：这里原写 filter_lua="agent"（注释称 test_agent*.lua），
	# 但**该文件模式从未存在**（git log --all 零命中），于是"agent 全表面"入口的
	# Lua 段静默跑了 0 个文件——而循环对"命中 0"是合法状态，不报错也不计入汇总。
	# 真正覆盖 agent 协议面的是 test_llm_*.lua 的报文整形与响应映射用例
	# （PL-3 数组形态 content、PL-6 tool_calls 形态非法都在这一层），
	# 也就是 SAN-3 改动的那三个文件所在的那一层。
	# 2026-09-25 #8：Lua 协议驱动轨道整条删除（模块 + 库 + 两个 test_llm_*.lua），
	# agent 的协议面现由 Rust mybot-agent 直连承担，报文的假模型回归在 e2e 段
	# （R12/R13 多协议）。2026-10-01：Lua 段对 agent-all 的贡献不再是空表——
	# 摄像头协议面 test_camera.lua 经 agent_lua_roster 精确清单纳入（子串过滤器
	# 会连带真机的 test_camera_v4l2.lua，故改走 roster，见 Lua 段循环处注释）。
	filter_lua="llm"	# test_llm_*.lua：已删尽；Lua 段实际由 roster 驱动
	filter_e2e="agent"
	filter_hardening="agent_"
	filter_cpp="agent:"
fi

# 某分段是否应在当前过滤器下执行（$1=分段名，$2=该分段使用的过滤器）
filter_matches() {
	[ -z "$2" ] || [[ "$1" == *"$2"* ]]
}

# 某**单条**用例（名字 $1）是否应在当前过滤器下执行。段门只决定「本段进不进」，
# 段内若不做这层判断，`bash test/run_all.sh agent_missing_key` 会把同段 4 条全跑
# 一遍——段门一旦放行，段内就没有第二道判据。agent-all / hardening 按整段进。
case_matches() {
	[ -z "$filter" ] || [[ "hardening" == *"$filter"* ]] || [ "$filter" = "agent-all" ] \
		|| [[ "$1" == *"$filter"* ]]
}

# agent-all 的映射**自证**：上面那张表就是「覆盖全表面」这句承诺的实现，而它
# 此前正是靠四个分散的 if 各写一遍判断、才漏掉了一半的分段。
#
# SAN-2（2026-09-22）：自证从「过滤器变量非空 + e2e/cpp 认得这个输入」升级为
# **按 roster 核对真实文件**。旧判据只检查映射本身，检查不到"映射指向的文件
# 存不存在"——`filter_lua="agent"` 命中 0 个文件时它照样通过，于是"覆盖全表面"
# 这个结论在没有人跑过一条 Lua 用例的情况下成立了很久（实测汇总 11 条、Lua 段 0 条）。
# 判据是「roster 里每个文件必须存在，且在本过滤器下真的会被跑到」——
# 检查的是**被映射到的文件**，不是映射的形状。
# 2026-09-25 #8：Lua 协议驱动轨道整条删除，agent 协议面不再有 test_llm_*.lua，
# roster 因此为空——第 ② 步反向检查（test_llm_*.lua 必须全部登记）对空 glob
# 自然通过，将来若新增协议面 Lua 用例而漏登记，这一步仍会红（机制保留不拆）。
agent_lua_roster="test/test_camera.lua"
# 2026-10-01：agent 表面的摄像头协议面（capture_image 依赖的仿真取帧/base64/
# 错误路径）经 roster 精确清单纳入 agent-all——真机的 test_camera_v4l2.lua 因
# 同名子串刻意**不在**清单里（理由见 Lua 段循环处的 roster 注释）。
if [ "$filter" = "agent-all" ]; then
	_agentall_bad=""
	[ -n "$filter_lua" ] || _agentall_bad="$_agentall_bad lua(空值=跑全部文件)"
	filter_matches "agent" "$filter_e2e" || _agentall_bad="$_agentall_bad e2e"
	filter_matches "agent:" "$filter_cpp" || _agentall_bad="$_agentall_bad cpp"
	# ① roster 里的文件必须存在，且在 agent-all 下会被跑到
	for _f in $agent_lua_roster; do
		# Lua 段对 agent-all 走 roster 精确清单（见循环处），故只查存在性，
		# 不再与子串过滤器对账（子串判据已不是 agent-all 的执行依据）。
		[ -f "$_f" ] || _agentall_bad="$_agentall_bad $_f(roster 声明的文件不存在)"
	done
	# ② 反向：agent 协议面的用例文件必须全部登记（漏登记即红）——
	#    与 C++ 侧 test_util.cpp 的「非 agent 面 roster 带理由登记」同一条纪律。
	#    2026-09-25 #8 起该 glob 无文件（协议面用例随 Lua 轨道删除），空转通过。
	for _f in test/test_llm_*.lua; do
		[ -f "$_f" ] || continue
		case " $agent_lua_roster " in
			*" $_f "*) ;;
			*) _agentall_bad="$_agentall_bad $_f(未登记进 agent_lua_roster)" ;;
		esac
	done
	# 摄像头协议面（仿真）已入 agent 表面：文件在而漏登记即红（与 test_llm_*
	# 同一条「agent 面用例必须登记」纪律）。真机 v4l2 用例不在此列。
	if [ -f "test/test_camera.lua" ]; then
		case " $agent_lua_roster " in
			*" test/test_camera.lua "*) ;;
			*) _agentall_bad="$_agentall_bad test/test_camera.lua(未登记进 agent_lua_roster)" ;;
		esac
	fi
	if [ -n "$_agentall_bad" ]; then
		echo "错误：agent-all 的分段过滤器映射失效，以下分段/文件不会执行：$_agentall_bad" >&2
		echo "（见 test/run_all.sh 顶部的 filter_* 映射与 agent_lua_roster。本自证防的就是" >&2
		echo "  AG-23/SAN-2 那种「号称覆盖全表面、实际一个文件都没跑」的静默退化）" >&2
		exit 2
	fi
	unset _agentall_bad _f
fi
pass=0
fail=0
failed=""
skip=0
hardening_reported=""
skipped_list=""

# ---- 记账单点（N-31）----
# 11 个 runner 原各写一遍「if ok; then pass++; else fail++; failed+=…」三行，
# 加一段就再抄一遍、改口径（如新增「跳过」类别或改汇总措辞）要全文件找。
# 收敛为三个函数：通过只计数；失败/跳过额外把可读标签写进汇总清单。

# 某 runner 的声明用例数：数本文件里的调用点，让「加用例忘改数字」的消息漂移
# 无从发生（artifact_missing 的条数文案一律由此推导）。
# F3-4（2026-09-21）：单/双引号调用点都认——旧实现只认单引号，改一处写法即静默少算。

# F3-7（2026-09-21）：中断也留下显式痕迹。守门日志常被人工/CI 中途读取，
# 「还没跑到汇总」与「判失败」在日志里长相不同却都不含汇总行——中断时打印
# 一行明确的中途态标记（并把退出码固定为 130），读日志的人不必猜。
trap 'echo "守门被中断：汇总未产生（中途态，非失败）" >&2; exit 130' INT TERM

# ---- 编译产物（全局解析，供各分段共用）----
# 缺省路径可被 BOT / BOT_TESTS 覆盖；是否「显式指定」决定下面的降级策略。
bin="${BOT:-./build/mybot}"
tests_bin="${BOT_TESTS:-./build/mybot_tests}"
# 与 mybot_tests 同目录、由 test/cpp/harness_selftest.cpp 单独编出来的骨架自证二进制。
# 路径只在这里派生一次（tail_checks.sh 的 run_harness_selftest 直接用它）。
selftest_bin="$(dirname "$tests_bin")/harness_selftest"
bot_explicit=0
[ -n "${BOT:-}" ] && bot_explicit=1
tests_explicit=0
[ -n "${BOT_TESTS:-}" ] && tests_explicit=1

# ---- 产物陈旧判据（2026-09-21 第七轮审计）----
# 守门此前只判「产物存在」、不判新旧：改完源码直接 `bash test/run_all.sh`，跑的是
# **上一轮的二进制**，汇总照样给出一个像样的「N 通过, 0 失败」（本轮亲历：445 通过
# /1 失败，而 445+1 恰好等于改动前的用例数——那条失败还是"旧二进制 + 新 docs"的
# 组合产物）。这类假绿比缺产物更危险：缺产物有 artifact_missing 兜住并计入失败，
# 陈旧产物则不留任何痕迹。
# 判据只看**编译期输入**，且每个产物配**自己那份**：mybot 只由 src/ 编出来，
# mybot_tests 与 harness_selftest 才吃 test/cpp/。此前三个产物共用一份最大集合
# （src/ + test/cpp/ + CMakeLists.txt），后果是「只改了一条用例」时这道门永远过不去
# ——cmake 不会为 test/cpp/ 的改动重链 mybot，`cmake --build` 修不好它，唯一出路是
# BOT_ALLOW_STALE=1。一道天天狼来了的门，教会大家的正是怎么绕过它（2026-10-06 实测
# 踩到：反向验证动过 test/cpp 后，重建到 100% 仍被拒）。
# CMakeLists.txt 也已移出取材面（同日第二次踩到，同一类误报）：它不是产物的编译期
# 输入，而是**构建描述**——描述变了要不要重链，cmake/make 自己会算。把它当输入就等于
# 要求「产物比构建描述新」，而 make 对一个输入未变的目标只回一句「Built target」不重链，
# 于是这道门**重建也修不好**。实测：build-asan/harness_selftest 停在 2026-10-01、
# CMakeLists.txt 已走到 2026-10-04，`cmake --build build-asan` 报「[1%] Built target
# harness_selftest」而不重链 → gate 恒以 2 拒绝，run_san.sh 的第二跑整条进不去。
# 移出后少挡的那类（改了 CMakeLists 却从没跑过 cmake）仍被挡住：新增源文件本身就在
# src/ 或 test/cpp/ 里、比产物新；纯改编译开关则由 `cmake --build` 的自动 reconfigure
# 兜住，不该由本判据冒充。
# docs/、modules/、robots/ 是运行期读取的，改了它们不需要重编，纳入只会造成误报。
# harness_selftest 一并纳入：harness-selftest 段跑的就是它，此前不在循环里，陈旧了
# 照样报「8 通过」——正是本判据要堵的那类无痕假绿。
# 目录级取材面还要**减去属于别的目标的文件**，否则同一类误报换个入口再犯一次：
# touch src/main.cpp 后 `cmake --build` 只重链 mybot，mybot_tests 永远比它旧；
# touch test/cpp/harness_selftest.cpp 后只重链 harness_selftest，mybot_tests 永远比它旧。
# 归属的权威出处是构建系统自己的记账（build/compile_commands.json 的
# `-o CMakeFiles/<target>.dir/<src>.o`），2026-10-06 实测：
#   mybot            ← src/            − src/main.cpp 本身就是入口
#   mybot_tests      ← src/ + test/cpp − src/main.cpp（它用 test/cpp/main.cpp 当入口）
#                                       − test/cpp/harness_selftest.cpp（独立二进制）
#   harness_selftest ← test/cpp/harness_selftest.cpp + test/cpp/harness.hpp
# 这两条排除与 CMakeLists 的 C3/B8 两处自检是同一份事实，故 selftest 第 7 段钉住
# 「被排除的文件确实不在该目标的 add_executable 清单里」——归属一变，排除名单就得跟着变。
# 未纳入 test_*_consts：它们的 bin 变量在本文件更后面才定义。
# 逃生口 BOT_ALLOW_STALE=1：**明确知道**要跑旧产物（如复现历史结果）时显式声明。
if [ -z "${BOT_ALLOW_STALE:-}" ]; then
	for _b in "$bin" "$tests_bin" "$selftest_bin"; do
		[ -x "$_b" ] || continue	# 缺产物由 artifact_missing 判失败，这里不重复
		_ex=()
		case "$_b" in
			"$bin")
				_in=(src)
				_ex=() ;;
			# 骨架自证只由这两个文件编出来（CMakeLists.txt:271 的
			# add_executable(harness_selftest test/cpp/harness_selftest.cpp)）；
			# 给它套整个 test/cpp/ 就又是上面那个「重建也修不好」的误报。
			"$selftest_bin")
				_in=(test/cpp/harness_selftest.cpp test/cpp/harness.hpp) ;;
			*)
				_in=(src test/cpp)
				_ex=(-not -path 'src/main.cpp'
					-not -path 'test/cpp/harness_selftest.cpp') ;;
		esac
		_stale="$(find "${_in[@]}" -type f \
			\( -name '*.cpp' -o -name '*.hpp' -o -name '*.h' \) \
			"${_ex[@]}" -newer "$_b" -print -quit 2>/dev/null)"
		if [ -n "$_stale" ]; then
			echo "守门拒绝执行：产物 $_b 比编译期输入旧（例如 $_stale）。" >&2
			echo "  继续跑等于用**上一轮的二进制**做整套 C++ 守门，汇总仍会显示通过。" >&2
			echo "  请先重建： cmake --build $(dirname "$_b") -j\$(nproc)" >&2
			echo "  确实要跑旧产物： BOT_ALLOW_STALE=1 bash test/run_all.sh" >&2
			exit 2
		fi
	done
	unset _b _stale _in _ex
fi

# ---- 参数化 lint runner（27.8 抽自三处同形态内联 lint）----
# 三处 lint（arg_table/__mpath/nan-fallback）共享同一形态：grep 找坏形态 → 有 filter 跳过
# → 找到即失败 → 否则通过。BH1750 那条额外有计数自检（抽取判据失效时显式红），
# arg_table/__mpath 补上同款防线后也收进本函数。
# 参数：$1=lint 名（记账用） $2=标题 $3=grep 命令（输出坏文件列表） $4=期望最小命中数
#       （可选，缺省 0 = 不检查；>0 时实际命中 < 期望即判「抽取判据失效」）
run_one_inline_lint() {
	local name="$1" title="$2" grep_cmd="$3" min_hits="${4:-0}"
	echo "----- lint ($title) -----"
	if [ -n "$filter" ]; then
		echo "[SKIP] 指定过滤器 '$filter' 时 lint 不在过滤范围内，跳过"
		return
	fi
	local bad hits_n
	bad="$(eval "$grep_cmd" || true)"
	hits_n="$(printf '%s\n' "$bad" | grep -c . || true)"
	if [ "$min_hits" -gt 0 ] && [ "$hits_n" -lt "$min_hits" ]; then
		echo "[FAIL] 抽取判据只命中 $hits_n 处（期望 ≥ $min_hits）——判据可能已对不上源码形态"
		record_fail "$name"
	elif [ -n "$bad" ]; then
		echo "[FAIL] 以下文件仍存在问题形态："
		echo "$bad"
		record_fail "$name"
	else
		echo "[PASS] $title"
		record_pass
	fi
}

# ---- 分段 runner 定义（F3-1 抽自本文件；只含函数定义，见各文件头注）----
# 用 $SELF 推导目录：run_all.sh 启动时已 cd 到仓库根，但 $SELF 在 cd 之前取，
# 对「从别处调用」也成立。
for _sec in "$(dirname "$SELF")/lib/sections"/*.sh; do
	# shellcheck source=/dev/null
	. "$_sec" || { echo "无法加载分段定义: $_sec" >&2; exit 2; }
done
unset _sec

# ---- 产物缺失的分段不得静默消失（N1 防线）----
# 原语义是「无编译产物则逐条 [SKIP]」，于是整段 C++ 守门（E2E + 无硬件契约 +
# TCP/信号/加固 + C++ 单测）可以在产物不存在时整体不跑，汇总仍是「N 通过, 0 失败」
# 且退出码 0——只剩 Lua 段在跑。守门必须完整：缺产物即判失败。
# 仅当 ALLOW_SKIP=1（明知故犯，如源码态只想跑 Lua）**且**该路径是缺省值时才降级
# 为 SKIP；调用方显式给了 BOT=/BOT_TESTS= 却说文件不在，本就是要测它，绝不放行。

# 当前过滤器下某分段的声明用例数（把「整段未执行」折算成准确条数）

for t in test/test_*.lua; do
	name="$(basename "$t")"
	# AG-23：分段过滤器。旧入口在这条判断上用 raw filter，于是
	# `bash test/run_all.sh agent` 匹配到 0 个 Lua 文件而汇总照绿。
	if [ "$filter" = "agent-all" ]; then
		# agent-all 的 Lua 段走 roster **精确清单**（2026-10-01）：子串过滤器
		# 分不开 test_camera.lua（仿真协议面，应入 agent 表面）与
		# test_camera_v4l2.lua（真机 ABI 回归，只该由全量/显式过滤器跑）——
		# "camera" 子串会把真机用例一起卷进来。
		case " $agent_lua_roster " in
			*" $t "*) ;;
			*) continue ;;
		esac
	elif ! filter_matches "$name" "$filter_lua"; then
		continue
	fi
	echo "----- $name -----"
	# 真机用例跳过门与 ctest 共用同一实现（阶段 5.2）：标记解析单点，
	# 不再按设备名各写一条 if（此前 i2c/video 两份，且 ctest 侧只特判文件名）。
	out="$($timeout_cmd sh test/lib/device_gate.sh "$t" "$LUACMD" "$t" 2>&1)"
	rc=$?
	# A5（2026-09-20 审计）：125 必须**带 device_gate.sh 的 [SKIP] 横幅**才记跳过。
	# 此前只认退出码，于是任何用例 `os.exit(125)`（或将来某条真实失败凑巧用 125）
	# 都会被洗成「跳过」而从 pass/fail 记账里消失——与「用例不得静默消失」的
	# 守门完整性承诺相悖。125 是 ctest 的 SKIP_RETURN_CODE 保留值，非跳过门
	# 主动产生的 125 一律判失败。
	if [ $rc -eq 125 ]; then
		echo "$out"
		if echo "$out" | grep -qF '[SKIP]'; then
			record_skip "$name"
		else
			echo "[FAIL] 退出码 125 但无 [SKIP] 横幅：只有 test/lib/device_gate.sh 的"
			echo "       无真机设备分支才可记跳过（catches os.exit(125) 洗白，A5）"
			record_fail "$name"
		fi
		continue
	fi
	echo "$out"
	# 兼容三种失败约定：退出码非零、打印 [FAIL] 行（124 = timeout 超时）、
	# 或假绿形态（P0-2）：早退/守卫短路导致未见 summary 的 [DONE] 完成标记，
	# 或一条断言都没跑（[PASS] 计数为 0）——「安静退出」不再视同通过
	if [ $rc -eq 124 ] && [ -n "$timeout_cmd" ]; then
		echo "[FAIL] 用例超时（>${TEST_TIMEOUT}s，疑似死循环）"
		record_fail "$name"
	elif echo "$out" | grep -qF "[FAIL]"; then
		record_fail "$name"
	elif ! check_green "$out" "$rc" "$name"; then
		: # check_green 已 record_fail
	else
		record_pass
	fi
done

echo "==============================================="

# ======================================================================
# 驱动入口 lint（fix-plan 2-2 收尾防线）：器件驱动 build/call 入口必须走
# drv_common.arg_table——内联 `type(data) ~= "table"` 会绕过 arg_table
# 附带的 proto=virt 注入钩子（@Action 直写路径绕开仿真打到真实总线）。
# Camera 有意豁免（头注声明：全仓唯一不挂 arg_table 样板的驱动，build
# 不碰设备、入参走内联类型守卫）。lib/ 内部实现自用，不在检查范围。
# ======================================================================
# 本 lint 搜的是「坏形态」，PASS 的条件天然是 0 命中——不能再给 min_hits（那是
# 给「正向抽取」用的参数，语义是「命中数应 ≥ N，低于则判抽取判据失效」，套在
# 坏形态搜索上会导致 PASS 结构上不可达，2026-10-08 审计发现并修正，详见
# .tmp/audit-2026-10-08.md P0）。抽取判据是否还对得上源码形态，交给
# test/run_all_selftest.sh 的合成坏样本正向对照去管，不在这里用活树命中数假装自检。
run_one_inline_lint "lint-driver-entry-arg_table" \
	"驱动入口 arg_table 断言" \
	"grep -l 'type(data) ~= \"table\"' modules/*.lua | grep -v '^modules/Camera.lua$'"

# ======================================================================
# 模块路径引导 lint（2026-09-20 重构阶段 2 收尾防线）：
# 驱动/lib 找 lib/mpath.lua 必须写成 `__mpath or <单根回退>`——宿主经
# sandbox_lua 注入 __mpath 后按 BOT4CJ_MODULE_PATH 逐段探测；直用
# `:match("[^:]+")` 只取首段，多路径布局下加载必失败
# （docs/reference.md 承诺「按序查找」，判别性用例见 hardening 段
# multipath_module_path）。只盯这一种**已知坏形态**——lib/ 里用
# `:gmatch("[^:]+")` 逐段探测的既有实现是对的，不能误伤。
# ======================================================================
# 同上（见上条 lint 的新注释）：坏形态搜索不配 min_hits。另修一处独立 bug：
# 原判据 `:match("[^:\]+")` 在被双引号参数吃掉转义后，`[^:\]` 变成未闭合字符
# 类，恒 0 命中——改用 grep -F 字面量匹配 `:match("[^:]+")`，不再过引号层。
run_one_inline_lint "lint-module-path-bootstrap" \
	"模块路径引导 __mpath 断言" \
	"grep -rnF ':match(\"[^:]+\")' modules/ | grep -v '__mpath'"

# ======================================================================
# NaN 兜底 lint（26.1 收尾防线）：驱动的配置列不得写 `tonumber(data.X) or 缺省`。
# LuaJIT 下 tonumber("nan")/tonumber("inf") 出的是 **number**（Lua 里 truthy），
# or 的右支永不触发；而 NaN 与任何数比较都为假，后续的区间判定一律放行。
# 已实测到的后果不是错值而是行为改变：MCP4725 的 eep='nan' 会走**有擦写寿命
# 上限**的 EEPROM 写路径、AD9833 的 mute='nan' 会静默把 DDS 静音、MT6826S 的
# zero='nan' 会把每次 call 的 ANGLE 永久污染成 nan、BME688 的 wait='nan' 会让
# 轮询循环的超时分支永不触发（后端进程挂死）。这四处是后果最重的样本，连同
# AS3935/APDS9900/EMC2101/GPIO 共 8 个驱动的同类站点均已修（前后行为对照记在
# 各自提交信息里），本 lint 钉住不回退。
# 正确写法是 drv_common 的 num_or(v, def)（回落缺省）或 finite_of(v)（返 nil，
# 判据取「与该列既有的非数字串同结论」）；两者都经 bus_contract.finite_of 单点。
# 只盯 `data.` 这一种形态：`data` 是 arg_table 强制的配置表名，而 `opts.` 是
# *_VIRT 内嵌模型构造器的参数名（TPL0501/BME280/AD9833 的三处 opts 站点全在
# 模型块内，生产路径零执行），不属本防线范围。
# Camera 有意豁免（在不碰清单：冻结边界，width/height 两列不改写）。
# ======================================================================
run_one_inline_lint "lint-driver-nan-fallback" \
	"配置列 NaN 兜底断言" \
	"grep -rnE 'tonumber\(data\.[A-Za-z_]+\) or ' modules/*.lua | grep -v '^modules/Camera.lua:'"

# ======================================================================
# 生命周期形态一致性 lint（26.3 收尾防线）：走 require_driver 的驱动**不得**
# 再自己定义单参的 build/call/destroy 全局。require_driver 会按 spec 里的
# build/call/destroy 回调**安装**同名全局包装（内含 arg_table 校验与
# proto=virt 注入钩子），驱动若在 require_driver 之后再写 `function build(data)`
# 就把包装整个覆盖掉——绕过 arg_table 的后果与上面那条驱动入口 lint 同源
# （@Action 直写路径绕开仿真打到真实总线），且覆盖是静默的：spec 回调照常
# 被定义、只是再没人调它。
# 判据取**元数**而非缩进：spec 回调一律是 `(ctx, data)` 两参（各驱动的 spec 表
# 有零缩进也有四空格缩进，缩进不可作判据），裸全局一律是单参 `(data)`。
# `read` 有意豁免：require_driver 只认 spec.build/call/destroy/state/name/
# i2c_addr_default，**没有 spec.read**，而宿主是直接探测全局
# `luaGlobalType(L_, "read")`（src/luavar.cpp）——想暴露 read 就只能写裸全局，
# SCSCL.lua 正是这一形态，属框架缺口而非驱动写错。
# lib/ 不在检查范围：drv_common.lua 自身就定义这四个单参全局（它就是安装方）。
# ======================================================================
echo "----- lint (require_driver 驱动的生命周期形态断言) -----"
# 单参生命周期全局：`function build(data)` 或 `build = function(data)`
lc_re='^[[:space:]]*(function[[:space:]]+(build|call|destroy)|(build|call|destroy)[[:space:]]*=[[:space:]]*function)[[:space:]]*\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\)'
rd_files="$(grep -l 'require_driver(' modules/*.lua || true)"
rd_n="$(printf '%s\n' "$rd_files" | grep -c . || true)"
bad="$(printf '%s\n' "$rd_files" | grep . \
	| while read -r f; do grep -HnE "$lc_re" "$f"; done \
	| grep -vE ':[0-9]+:[[:space:]]*local ' || true)"
if [ -n "$filter" ]; then
	echo "[SKIP] 指定过滤器 '$filter' 时 lint 不在过滤范围内，跳过"
elif [ "$rd_n" -eq 0 ]; then
	# 抽取判据失效防线：一个 require_driver 用户都没扫到，说明上面的 grep 判据
	# 已经对不上源码形态（改名/改调用方式），此时「0 命中」是空集自证而非通过。
	echo "[FAIL] 未扫到任何 require_driver 用户（抽取判据失效，0 命中不可信）"
	record_fail "lint-driver-lifecycle-shape"
elif [ -n "$bad" ]; then
	echo "[FAIL] 以下 require_driver 驱动另定义了单参 build/call/destroy 全局"
	echo "       （会覆盖 require_driver 安装的包装，静默丢掉 arg_table 与 proto=virt 钩子）："
	echo "$bad"
	echo "       改成 spec 回调 \`build = function(ctx, data)\`；确需 read 则豁免。"
	record_fail "lint-driver-lifecycle-shape"
else
	echo "[PASS] $rd_n 个 require_driver 驱动均只用 spec 回调（read 因无 spec.read 豁免）"
	record_pass
fi

# ======================================================================
# 器件常量机械对照 lint（fix-plan F5-5①）：test/test_bh1750.lua 内手抄了
# 一份「与驱动一致」的命令常量表——两边同错不报警，真机回归会拿错误常量
# 验证错误驱动。这里从两份源各抽 `local CMD_* = 0x..` 逐条比对，并断言
# 条数（抽取判据失效时显式红，不静默放行）。全仓唯一一处常量测试副本，
# 其余器件常量无重复（见 refactor-audit-lua §不得触碰：寄存器图属器件
# 事实，不做收敛，本 lint 也不外推）。
# ======================================================================
echo "----- lint (BH1750 常量驱动↔测试对照) -----"
drv="$(grep -oE '^local CMD_[A-Za-z0-9_]+[[:space:]]*= 0x[0-9A-Fa-f]+' modules/BH1750.lua | sed 's/^local[[:space:]]*//; s/[[:space:]]\+/ /g' | sort)"
tst="$(grep -oE '^local CMD_[A-Za-z0-9_]+[[:space:]]*= 0x[0-9A-Fa-f]+' test/test_bh1750.lua | sed 's/^local[[:space:]]*//; s/[[:space:]]\+/ /g' | sort)"
drv_n="$(printf '%s\n' "$drv" | grep -c .)"
if [ -n "$filter" ]; then
	echo "[SKIP] 指定过滤器 '$filter' 时 lint 不在过滤范围内，跳过"
elif [ -z "$drv" ] || [ -z "$tst" ]; then
	echo "[FAIL] 常量抽取结果为空（驱动或测试的常量块改名/改格式？判据已失效）"
	record_fail "lint-bh1750-const-parity"
elif [ "$drv_n" -ne 10 ]; then
	echo "[FAIL] 驱动侧抽到 $drv_n 条命令常量（应 10 条）——常量块形态变了，请同步本 lint 判据"
	record_fail "lint-bh1750-const-parity"
elif [ "$drv" != "$tst" ]; then
	echo "[FAIL] BH1750 命令常量在驱动与测试间不一致（两边同错不报警的预言机失效）："
	diff <(printf '%s\n' "$drv") <(printf '%s\n' "$tst") || true
	record_fail "lint-bh1750-const-parity"
else
	echo "[PASS] BH1750 命令常量驱动↔测试逐条一致（$drv_n 条）"
	record_pass
fi

# ======================================================================
# mybot（C++ 移植）无硬件端到端：编译产物缺失即判失败（见 artifact_missing）。
# 用例走真实 mybot 二进制：守护线程→共享槽→Ema→Monitor 全链路，
# I2C/SPI 器件均为内存仿真模型（内嵌于各驱动尾部 <DRIVER>_VIRT 工厂，
# lib/virtbus/ 仅存通用底座 regmap.lua）。
#
# 用例表：用例名|raw 快照浮点断言 ERE（证明 :f 字段未被取整）|count 下限。
# EMA 混合断言对所有用例通用：某拍 monf 行内 out ≠ raw（滤波确实推进）。
# 二进制缺省 ./build/mybot，可用 BOT=xxx 覆盖。
# ======================================================================
e2e_cases=(
	'mpu_virt|"v6":41\.[0-9]+|5'
	'bme280_virt|"v0":2[0-9]\.[0-9]+|5'
	'ads1256_virt|"v1":[0-2]\.[0-9]+|5'
	'vl53l0x_virt|"v0":[0-9]+\.[0-9]+|5'
	'vl53l4cd_virt|"v0":[0-9]+\.[0-9]+|5'
	'sht3x_virt|"v0":2[0-9]\.[0-9]+|5'
	'mcp3421_virt|"v0":-?[0-9]+\.[0-9]+|5'
	'ms5611_virt|"v0":10[01][0-9]\.[0-9]+|5'
	'sgp30_virt|"v0":[4-7][0-9][0-9]\.[0-9]+|5'
	'ina219_virt|"v0":1[12]\.[0-9]+|5'
	'ads1115_virt|"v0":1\.[0-9]+|5'
	# AS7262 raw 六通道是无符号整数计数（:f 透传无小数），浮点断言锚定 monf
	# 行 Ema 对 V 计数的 α 混合输出 out（必为带小数浮点）
	'as7262_virt|"out":[0-9]+\.[0-9]+|5'
	# MAX30102 raw IR/RED 同为无符号 18 位整数计数，浮点断言锚定 monf 行
	# Ema 对 IR 计数的 α 混合输出 out（必为带小数浮点）
	'max30102_virt|"out":[0-9]+\.[0-9]+|5'
	# AMG8833 raw MAXR/MAXC 是整数行列，浮点断言锚定 monf 行 Ema 对
	# AVGT 平均温度的 α 混合输出 out（必为带小数浮点）
	'amg8833_virt|"out":[0-9]+\.[0-9]+|5'
	# PCF8574 raw PINS/OUT 是无符号 8 位整数引脚码（:f 透传无小数），
	# 浮点断言锚定 monf 行 Ema 对 PINS walking 位码的 α 混合输出 out
	'pcf8574_virt|"out":[0-9]+\.[0-9]+|5'
	# LTC2944 raw 四字段均 :f 浮点；v0=CHARGE/v1=V/v2=I/v3=T，锚定 v1
	# 母线电压正弦（11.6~12.4V，带小数即证明未被 sign=16 取整）
	'ltc2944_virt|"v1":1[12]\.[0-9]+|5'
	# CHT8305 raw 两字段均 :f 浮点；v0=T（20~30°C 正弦）/v1=H（40~60%RH
	# 反相），锚定 v0 温度（带小数即证明未被 sign=16 取整）
	'cht8305_virt|"v0":2[0-9]\.[0-9]+|5'
	# ADS1015 raw 单字段 voltage:f（12 位左对齐孪生，V=raw12*FS/2048），
	# AIN0 正弦 1.40~1.90V，锚定 v0（带小数即证明未被 sign=16 取整）
	'ads1015_virt|"v0":1\.[0-9]+|5'
	# INA226 raw 三字段均 :f 浮点；v0=V/v1=I/v2=P（总线 16 位无移位
	# 1.25mV、分流 2.5µV 全软件换算），锚定 v0 母线电压正弦（11.6~12.4V）
	'ina226_virt|"v0":1[12]\.[0-9]+|5'
	# INA3221 raw 六字段均 :f 浮点；v0=V1/v1=I1/v2=V2/v3=I2/v4=V3/v5=I3
	# （三通道 13 位 <<3：总线 8mV、分流 40µV 全软件换算），锚定 v0 的
	# ch1 母线电压正弦（11.6~12.4V）
	'ina3221_virt|"v0":1[12]\.[0-9]+|5'
	# MAX17043 raw 两字段均 :f 浮点；v0=VCELL（12 位 <<4、1.25mV 全软件
	# 换算，3.60~4.10V 锂电正弦）/v1=SOC（1/256% 定点），锚定 v0
	'max17043_virt|"v0":[34]\.[0-9]+|5'
	# MAX17048 raw 两字段均 :f 浮点；v0=VCELL（16 位直读无移位、78.125µV
	# 全软件换算，3.60~4.10V 锂电正弦）/v1=SOC（1/256% 定点），锚定 v0
	'max17048_virt|"v0":[34]\.[0-9]+|5'
	# BH1745 raw 四通道是无符号 16 位整数计数（:f 透传无小数），浮点断言
	# 锚定 monf 行 Ema 对 R 计数（19k~25k 正弦）的 α 混合输出 out
	'bh1745_virt|"out":[12][0-9]{4}\.[0-9]+|5'
	# BH1750 命令式环境光（单字节 opcode、测量值纯读 2 字节大端 count）：
	# raw v0=LUX:f 浮点（virt_tick 32 拍正弦 count 12002~18002 → 10001.7~15001.7）。
	# 正弦里有少数拍 count 恰为 6 的倍数（如 17496→14580）raw 成整数、而守护
	# 20ms 拍与 50ms pump 存在混叠（快照采到哪拍不固定），故浮点断言锚定 monf
	# 行 Ema 的 α 混合输出 out（与 bh1745/mhz19 同口径）证明 :f 未被 sign=16 取整
	'bh1750_virt|"out":1[0-9]{4}\.[0-9]+|5'
	# APDS9900 raw LUX 本身即 :f 浮点照度（内核两线 IR 补偿，缺省档
	# 1354~3160 lux 正弦），CH0/CH1/PROX 整数计数 :f 透传；锚定 v0=LUX
	'apds9900_virt|"v0":[12][0-9]{3}\.[0-9]+|5'
	# BMM150 raw X/Y/Z 三轴地磁 µT（XY 13 位、Z 15 位 + RHALL 14 位，Bosch
	# 整数补偿管线收尾 idiv /16，输出恒为整数值、JSON 无小数点），浮点断言
	# 锚定 monf 行 Ema 对 Y 轴（-27~3µT 正弦，含负值）的 α 混合输出 out
	'bmm150_virt|"out":-?[0-9]+\.[0-9]+|5'
	# MLX90393 raw 四字段均 :f 浮点；v0=X/v1=Y/v2=Z（µT，命令式 status-first
	# 器件，gain0 0.751/1.210µT/LSB 量化后正算回物理量）/v3=T（°C），锚定
	# v0 的 X 轴 ±30µT 正弦（含负值，带小数即证明未被 sign=16 取整）
	'mlx90393_virt|"v0":-?[0-9]+\.[0-9]+|5'
	# AS3935 事件型：v0=CODE 0~3/v1=DIST_KM 公里/-1 两整数，v2=ENERGY
	# 21 位能量（tick 闪电拍 217157/782842，整数物理量 :f 透传无小数点；
	# 若无 :f 会被 sign=16 截断到 ≤65535），锚定 raw 行 v2 六位整数；
	# Ema 滤 v1 DIST_KM（-1 与 10~35 混合），通用断言验 monf out≠raw
	'as3935_virt|"v2":[0-9]{6}[,}]|5'
	# EMC2101 风扇控制器：v0=TEMP_IN 整数/v1=TEMP_EXT:f 1/8°C 小数/
	# v2=RPM:f 转速，tick 正弦恒四位数 1800~4200（锚 raw v2 四位整数
	# 部分，整除拍 JSON 无小数点、其余拍带小数，两种形态都算通过，避免
	# 采样相位碰不到整除拍的抖动；Ema 滤 v1 外温，通用断言验 monf）
	'emc2101_virt|"v2":[0-9]{4}(\.[0-9]+)?[,}]|5'
	# BME688 四合一：v0=T:f（22~28°C 正弦）/v1=P:f/v2=H:f/v3=GAS:f
	# 气体电阻/v4=GAS_OK 整数，forced 门靠 virt_tick 预武装零睡眠，
	# 锚 v0 温度（带小数即证明未被 sign=16 取整）
	'bme688_virt|"v0":2[0-9]\.[0-9]+|5'
	# BMI270 六轴 IMU：ACCEL_X/Y/Z + GYRO_X/Y/Z 六字段均 sign='16'
	# 展开的有符号整数码（无 :f），配置 blob 上传 + 150ms 加载门靠
	# virt_tick 预武装（build 仅睡 114ms），浮点断言锚定 monf 行 Ema
	# 对 ACCEL_X 正弦码（100~500）的 α 混合输出 out
	'bmi270_virt|"out":-?[0-9]+\.[0-9]+|5'
	# LSM6DSV16X 六轴 IMU：ACCEL_X/Y/Z + GYRO_X/Y/Z 六字段均 sign='16'
	# 展开的有符号整数码（无 :f），无 blob/无转换门（build 实睡 110ms：
	# 10ms 复位轮询+100ms 陀螺启动），浮点断言锚定 monf 行 Ema 对
	# ACCEL_X 正弦码（100~500）的 α 混合输出 out
	'lsm6dsv_virt|"out":-?[0-9]+\.[0-9]+|5'
	# MT6826S 15 位磁编码器（SPI Mode3，首个全双工同帧器件）：v0=ANGLE:f
	# 度数（virt_tick 32 拍线性爬坡，11.25° 步进，非零拍必带小数）/
	# v1=RAW/v2=STATUS/v3=CRC_OK 整数；锚 v0 浮点（证明 :f 未被取整）
	'mt6826s_virt|"v0":[0-9]+\.[0-9]+|5'
	# MH-Z19B NDIR CO₂（首个 UART virt 器件，/dev/serial0@9600 请求-应答帧）：
	# v0=CO2:f 整数 ppm（virt_tick 32 拍一周爬坡 400~4368、128ppm 步进，
	# :f 透传无小数）/v1=TEMP/v2=S；浮点断言锚定 monf 行 Ema 对浓度的 α 混合 out
	'mhz19_virt|"out":[0-9]+\.[0-9]+|5'
	# SDS011 激光颗粒物（第二个 UART virt 器件，/dev/serial0@9600 被动查询模式）：
	# v0=PM25:f / v1=PM10:f 浮点 µg/m³（virt_tick 5 拍一周扬尘爬坡，0.8 步进、
	# raw 码 mod 10 恒非 0 ⇒ raw 行必带小数，锚 mon0 的 v0 即证明 :f 未取整）
	'sds011_virt|"v0":[0-9]+\.[0-9]+|5'
	# ADXL345 raw 三轴均 sign='16' 展开的有符号整数码（无 :f 字段），
	# 浮点断言锚定 monf 行 Ema 对 ACCEL_X 正弦码（±77，含负值）的 α 混合 out
	'adxl345_virt|"out":-?[0-9]+\.[0-9]+|5'
	# LPS22HB raw 两字段均 :f 浮点；v0=P（24 位小端/4096，1008.25~1018.25hPa
	# 海平面正弦）/v1=T（16 位小端/100，20~24°C），锚定 v0 气压（带小数即
	# 证明未被 sign=16 取整）
	'lps22hb_virt|"v0":10[01][0-9]\.[0-9]+|5'
)

if [ ! -x "$bin" ]; then
	n_declared="$(count_e2e_declared)"
	[ "$n_declared" -gt 0 ] && artifact_missing "mybot E2E" "$n_declared 条用例" "$bin" "$bot_explicit"
else
	for spec in "${e2e_cases[@]}"; do
		name="${spec%%|*}"
		rest="${spec#*|}"
		float_ere="${rest%%|*}"
		count_min="${rest##*|}"
		if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
			continue
		fi
		run_one_e2e "$name" "$float_ere" "$count_min"
	done
fi

# ======================================================================
# mybot 无硬件契约回归（无需 I2C/SPI 真机）：
# 正值：退出码 0 + 输出必须包含锚点；负值：退出码非 0（表名拼错、
# 别名重复、$ 引用标量等应清晰报错绝不裸崩）。覆盖：
#   sqlquote      引号值内 "--"/"/*"/";"/","/括号/空白按字面解析
#   insert_typo   INSERT 目标表拼错 → 解析期报错
#   insert_colorder  INSERT 列名清单与建表声明序不一致 → 值按列名落位（C3）
#   insert_badcol    INSERT 写不存在的列名 → 解析期报错（C3，此前静默顺序落位）
#   number_type   CREATE TABLE 支持 Number 列（解析期一次数值校验，值仍文本驻留）
#   number_bad    Number 列写入非数值字面量 → 解析期清晰报错
#   daemon/filter/ema_chain/monitor/mpu_daemon/multidaemon
#                 守护采样→消费链路（含 Kalman/Ema/Monitor）
#   daemon_setup_fail  守护 setup 失败响亮契约（N-27）：失败码进槽 status 字段
#                 而非伪装成 v0 采样值，宿主按 ERR 报错并含 "slot status -8"
#   daemon_badproto/daemon_fieldmode/daemon_fieldempty
#                 守护配置 schema 加载期校验（E2）：非法 proto/fields 在结构脚本
#                 加载期报错（含守护名/列/表/行号），不再静默按 i2c 走或当浮点透传
#   relay-test / ref_prefix   Relay.controller 转发 + note 透传（$ 前缀字面）
#   alias_inline 动作脚本内联别名生效；alias_override/alias_dup 覆盖/重复负值
#   vars_num     @Vars 仅支持 Number：结构表 $ 数值常量填充 Relay.note
#   vars_bad/vars_nonnum/vars_dup  Vars 缺 value 列 / 非数值 / 动作脚本内重复定义 → 负值契约
#   expr_num     $(...) 表达式：Vars 内 + SQL 元数据列 + @Action 单元格三处
#   expr_undefined 元数据列表达式引用未定义标识符 → 装配期报错（先于任何 build）
#   expr_overflow 元数据列表达式溢出为 inf → 求值期报错（有限值防线，inf/nan 不入驱动）
#   mt_noblank  矩阵间只有单个换行（无空行）→ 第 2+ 个矩阵名仍须正确识别
#   mt_crlf     同上但 CRLF 行尾 → 修复不得只按 LF 语义而破坏 CRLF
#   mt_ragged   行内单元格数与表头不齐 → 须报 "Does Not Sync" 且行号准确
#   ref_alias_scalar  $ 引用指向标量 Alias → 报 "non-object" 而非类型崩溃
#   ref_forward    $ 前向引用合法（装配后统一校验）+ destroy 只取字面列
#                  （不再出现读已释放引用的 Deactive warning，F-04/F-05）
#   ref_undefined  $ 指向未定义变量 → 装配期报错且先于任何驱动 build（无 spawned）
#   ref_override   N-5：会话 @Alias 覆盖结构 @Vars 名字，$ 引用列仍绑定结构期
#                  变量（seed 期锁定目标指针）——note=200 而非按名重查到别名报
#                  "referenced variable returned a non-object"
#   pca9685_virt / pca9685_badchan
#                 首条【非守护】virt 覆盖：@Action 直写舵机驱动板走内存仿真
#                 （drv_common 入口前置注入 + adopt_fd 跨状态机采纳 fd）；
#                 正值断言虚拟横幅，负值断言通道越界被守卫（证明该链路非空断言）
#   mcp4725_virt  第二条【非守护】virt 覆盖（I2C DAC 直写）：同时钉住
#                 「驱动 build/call 走 arg_table（代调 virt_prepare）」——
#                 旧风格入口绕过该钩子时，本用例的 i2c_open 会打到真实
#                 /dev/i2c-99 响亮失败而非仿真（2026-09-19 审计修复回归）
#   scscl_virt / scscl_badid
#                 首个【UART 非守护】virt 覆盖（BUS="uart" 模型 attach_uart +
#                 adopt uart fd）：@Action 直写总线舵机（SCSCL，大端帧/1M 波特率）；
#                 负值断言站号非法在 build 期被守卫
#   pca9685_virt  第 5 字段禁 "Deactive warning"（F-04′）：destroy 期元数据必须
#                 带着 $i2c-v 的 fd 快照，否则去初始化报 Invalid Argument: fd or address
#                 （该失败只打警告不改退出码，故只能靠禁断言抓）
#   ref_bus_forward 接口器件前向引用（总线声明在器件之后）→ build 期即失败（F-04′）：
#                 fd 由器件行经 $i2c-N 从 @I2C 快照而来，而「总线必须先于器件声明」
#                 是 build 期强制的（器件 build 要 fd）——同一条不变式也保证倒序销毁时
#                 总线最后关闭 fd。全程不触总线：PCA9685 build 在 i2c_pair 处即返回，
#                 @I2C 的 build 根本未执行，故插着真舵机的机器上同样安全。
#   trig_basic  trigger 前置调用（controller 的镜像入边）：relay-src 从不出现在
#                 @Action，其 Relay 打印出现即证明前置调用发生；controller 链
#                 闭合（Timer 经转发收到 delay=300）。顺序与数据到位的观察面
#                 （行序、call 参数 dump）在本文件「trigger 前置调用」专段补齐
#   trig_param  .mt 参数列不得占用触发器名——结果子表按触发器名并入调用参数
#   trig_forward/trig_scalar/trig_reserved/trig_collide/trig_dollar/trig_n6
#                 trigger 负值契约：前向引用 / @Alias·@Vars 标量目标 / 框架保留键 /
#                 与本表元数据列同名 / $ 数据引用写法 / 会话别名覆盖（N-6）
#   trig_err    触发器 ERR 整帧 halt：触发目标 Timer 缺 delay 参数必报 ERR，
#                 派发帧响亮中止且退出码 1
#   ctrl2_basic/trig2_basic
#                 controller/trigger 多列（基名+数字编号列）：扇出广播（每个
#                 controller 收同一份 payload，返回值取最后者）/ 依序前置调用
#                 （结果各自按名到位）；行序与同 payload 观察面在本文件
#                 「trigger 前置调用」专段补齐
#   flow_dup/flow_dupc/flow_fwd2/flow_scalar2/trig_scalar2
#                 多列负值契约：同列族重复指向 / controller2 前向引用 /
#                 编号列拒绝 @Alias·@Vars 标量目标
#   ctrl2_err   controller 扇出 fail-fast：第一个 controller ERR 即停止，
#                 后续 controller 不再被转发（relay 目击者禁言断言）
# 用例表：SQL|MT|期望退出码|输出必须包含|输出必须不含（第 5 字段可省；MT/SQL 含 "/" 时视为仓库根相对路径）
# 第 6 字段可省，"I" = 用 --input 文件通道代替 stdin 管道（片段以自身目录为
# include 基准，无法从仓库根以 stdin 单跑——用 I 让它们以正确基准被守门）。
# 二进制缺省 ./build/mybot，可用 BOT=xxx 覆盖（与 E2E 段同约定）。
# ======================================================================
parse_cases=(
	'sqlquote.sql|sqlquote.mt|0|joined, total publishes='
	'insert_typo.sql|insert_typo.mt|1|table is not defined'
	'insert_colorder.sql|number_type.mt|0|note=hello-number'
	'insert_badcol.sql|insert_badcol.mt|1|no such column'
	'number_type.sql|number_type.mt|0|note=hello-number'
	'number_bad.sql|number_bad.mt|1|declared Number'
	'daemon.sql|daemon.mt|0|joined, total publishes='
	'filter.sql|filter.mt|0|joined, total publishes='
	'ema_chain.sql|ema_chain.mt|0|joined, total publishes='
	'monitor.sql|monitor.mt|0|joined, total publishes='
	'mpu_daemon.sql|mpu_daemon.mt|0|joined, total publishes='
	'daemon_setup_fail.sql|daemon_setup_fail.mt|1|slot status -8'
	'daemon_badproto.sql|daemon_schema.mt|1|not a supported bus'
	'daemon_fieldmode.sql|daemon_schema.mt|1|unknown field mode'
	'daemon_fieldempty.sql|daemon_schema.mt|1|empty field name'
	'daemon_fieldcount.sql|daemon_schema.mt|1|exceeds the shared-slot capacity'
	# maxvals 列（ABI v2，2026-10-16）：fields 数量按本行 maxvals 校验——
	#   narrow  maxvals=32 + 40 字段 → 拒（证明判据取行内值而非编译期缺省 64）
	#   range   maxvals=99999 → 拒（硬上限 1024，槽分配输入不许静默回落）
	#   ok      65 字段（> 缺省 64）+ maxvals=128 → 放行并完整跑一轮守护生命周期
	'daemon_fieldcount_maxvals_narrow.sql|daemon_schema.mt|1|exceeds the shared-slot capacity of 32'
	"daemon_maxvals_range.sql|daemon_schema.mt|1|column 'maxvals' value '99999'"
	# kind 列（sim_sensor_daemon 框架列，2026-10-16）：拼错加载期拒绝
	"daemon_kind_bad.sql|daemon_schema.mt|1|column 'kind' value 'immu'"
	'daemon_fieldcount_maxvals_ok.sql|daemon_maxvals_ok.mt|0|joined, total publishes='
	'single_consumer.sql|daemon_schema.mt|1|two concurrent consumers'
	'float_s16_daemon.sql|float_s16_daemon.mt|1|would be truncated to integer'
	'multidaemon.sql|multidaemon.mt|0|joined, total publishes='
	# 注意：第 5 字段是 forbid（禁止出现）不是追加锚点；合并快照锚点放 expect，
	# forbid 留空。首个 VIRTUAL HARDWARE 横幅由 chunk 自身保证，无需断言。
	'daemon_multi.sql|daemon_multi.mt|0|joined, total publishes='
	# 多守护聚合（sources 列，2026-10-16）：两路异型 virt 传感器拼进一个槽——
	# v9 存在即证明 7+3 拼接到位（imu0 单路最多 7 值）；序 = sources 声明序
	'daemon_aggregate.sql|daemon_aggregate.mt|0|"v9":'
	'robots/relay-test.sql|scripts/relay-test.mt|0|note=hello-relay'
	'ref_prefix.sql|ref_prefix.mt|0|Relay: test=200 note=timer-0'
	'alias_inline.sql|alias_inline.mt|0|served 1 call(s)'
	'alias_inline.sql|mt_noblank.mt|0|served 1 call(s)'
	'alias_inline.sql|mt_crlf.mt|0|served 1 call(s)'
	# 孤儿检测（F3/N-32）发现的两条「夹具在但没登记」用例：都是纯逻辑离线可跑
	#   servo      控制器为 dummy：offset 漂移 / |min|/|max| 限幅 / 负 max 反向
	#   h03_arr    数组参数跨语言双向往返：JsonArray→Lua 表（# 与下标）→ 回 JsonArray
	'servo.sql|servo.mt|0|Dummy served 2 call(s)'
	'h03_arr.sql|h03_arr.mt|0|"list":[10,20,30]'
	'robots/relay-test.sql|mt_ragged.mt|1|Does Not Sync. we got line: 6'
	'alias_override.sql|alias_override.mt|1|missing or not a finite number'
	'alias_dup.sql|alias_dup.mt|1|Duplicate alias name'
	'vars_num.sql|vars_num.mt|0|note=200'
	"vars_bad.sql|vars_bad.mt|1|has no 'value' column"
	'vars_nonnum.sql|vars_nonnum.mt|1|neither a Number'
	'alias_dup.sql|vars_dup.mt|1|Duplicate Vars name'
	'vars_num.sql|vars_override.mt|1|must not override the'
	'expr_num.sql|expr_num.mt|0|note=50'
	'expr_undefined.sql|expr_undefined.mt|1|ghost'
	'expr_overflow.sql|expr_overflow.mt|1|non-finite'
	'ref_alias_scalar.sql|ref_alias_scalar.mt|1|referenced variable returned a non-object'
	'ref_cycle.sql|ref_cycle.mt|1|reference detected'
	'ref_forward.sql|ref_forward.mt|0|joined, total publishes=|Deactive warning'
	'ref_undefined.sql|ref_undefined.mt|1|but it is not defined|spawned, config:'
	'ref_override.sql|ref_override.mt|0|note=200|referenced variable returned a non-object'
	'lex_semicolons.sql|lex_semicolons.mt|1|Token ;'
	'param_override.sql|param_override.mt|1|is rejected because'
	'daemon_badfield.sql|daemon_badfield.mt|0|absent or non-numeric in driver result'
	'pca9685_virt.sql|pca9685_virt.mt|0|VIRTUAL HARDWARE|Deactive warning'
	'pca9685_badchan.sql|pca9685_badchan.mt|1|out of range 0-15'
	'mcp4725_virt.sql|mcp4725_virt.mt|0|VIRTUAL HARDWARE'
	'scscl_virt.sql|scscl_virt.mt|0|VIRTUAL HARDWARE'
	'scscl_badid.sql|scscl_badid.mt|1|Invalid Argument: id'
	'scscl_burn_guard.sql|scscl_burn_guard.mt|1|requires allow_burn'
	'ref_bus_forward.sql|ref_bus_forward.mt|1|Invalid Argument: fd or address'
	'trig_basic.sql|trig_basic.mt|0|note=src'
	'trig_basic.sql|trig_param.mt|1|is a trigger reference name'
	'trig_forward.sql|trig_forward.mt|1|The trigger must be defined before'
	'trig_scalar.sql|trig_scalar.mt|1|cannot be trigger targets'
	'trig_reserved.sql|trig_reserved.mt|1|cannot name a trigger'
	'trig_collide.sql|trig_collide.mt|1|collides with metadata column'
	'trig_dollar.sql|trig_dollar.mt|1|does not support '
	'trig_n6.sql|trig_n6.mt|1|referenced as a controller or trigger'
	'trig_err.sql|trig_err.mt|1|Invalid Argument: delay'
	'ctrl2_basic.sql|ctrl2_basic.mt|0|slept'
	'trig2_basic.sql|trig2_basic.mt|0|note=s2'
	'flow_dup.sql|flow_dup.mt|1|more than once'
	'flow_dupc.sql|flow_dupc.mt|1|more than once'
	'flow_fwd2.sql|flow_fwd2.mt|1|The controller must be defined before'
	'flow_scalar2.sql|flow_scalar2.mt|1|cannot be controller targets'
	'trig_scalar2.sql|trig_scalar2.mt|1|cannot be trigger targets'
	'ctrl2_err.sql|ctrl2_err.mt|1|Invalid Argument: delay|note=witness'
	# @Merge 展开（运行端动作脚本归并，内核 mtmerge_core；旧名 @Include，2026-10-12 改名）：
	#   include_a/include_b    两个被包含脚本单独跑也合法（正值，登记夹具防孤儿）
	#   include_inner          主脚本无 @Action：首个 include 顶替累加器
	#   include_nested         嵌套正值：主脚本 → 组合片段（无自有 @Action）→ 两叶
	#   include_main           归并正例（观察面专段补全量值断言，此处钉 110 出现 + 0 不出现）
	#   include_overlap        主脚本与 include 共享设备 → 设备集相交报错
	#   include_missing        引用不存在的文件 → 清晰报错
	#   include_twice          普通 .mt 重复包含 → 报错（抓笔误；共享用 *.once.mt）
	#   include_gait.once.mt   参数化片段单独跑：$(amp) 取自身缺省 21
	#   include_knob           旋钮正值：主脚本 @Vars 覆盖片段 amp → test=35 而非 21
	#   shared/fa/fb.once.mt   菱形三件套单独跑均合法（fb 单独跑时 shared 未包含过）
	#   include_diamond        菱形正值：两臂都包含 shared.once.mt，第二路跳过（注记）
	'include_demo.sql|include_a.mt|0|test=110'
	'include_demo.sql|include_b.mt|0|test=220'
	'include_demo.sql|include_inner.mt|0|test=220'
	'include_demo.sql|include_main.mt|0|test=110|test=0'
	'include_demo.sql|include_nested.mt|0|test=220'
	'include_demo.sql|include_overlap.mt|1|appears in both scripts'
	'include_demo.sql|include_missing.mt|1|cannot open include file'
	'include_demo.sql|include_twice.mt|1|more than once'
	'include_demo.sql|include_gait.once.mt|0|test=21||I'
	'include_demo.sql|include_knob.mt|0|test=35|test=21'
	'include_demo.sql|shared.once.mt|0|test=300||I'
	'include_demo.sql|fa.once.mt|0|test=100||I'
	'include_demo.sql|fb.once.mt|0|test=200||I'
	'include_demo.sql|include_scene.once.mt|0|test=220||I'
	'include_demo.sql|include_diamond.mt|0|test=300'
	# @Action 设备列别名解析（2026-09-19 设计评估）：设备位写 @Alias 解析穿透到
	# 真名（一层为止）；不同别名指到同一设备由派发期解析名查重抓——归并期
	# checkDisjoint 只见列头文本，这是第二层防线的落点
	'dev_alias.sql|dev_alias_direct.mt|0|note=from-a|note=from-b'
	'dev_alias.sql|dev_alias_ghost.mt|1|resolves via @Alias to'
	'dev_alias.sql|dev_alias_chain.mt|1|is itself a scalar'
	'dev_alias.sql|dev_alias_vars.mt|1|cannot name a device'
	'dev_alias.sql|dev_alias_dup.mt|1|already targeted by column'
	# 复用场景（主从覆盖 + 设备列解析组合）：片段缺省绑定 relay-a，主脚本
	# 同名 @Alias 改绑 relay-b——模板一字不动，播放必须整体换到 relay-b
	'dev_alias.sql|dev_alias_leg.once.mt|0|note=from-a|note=from-b'
	'dev_alias.sql|dev_alias_rebind.mt|0|note=from-b|note=from-a|I'
	# $(...) 类型分派表达式（2026-09-20 设计评估）：'+' 出现文本（@Alias）即
	# 拼接（数值真值 formatNumber 参与），全数值仍是算术；落点 = @Action 全部
	# 单元格（设备位/参数位/数据格），求值都在派发期。$(...) 内标识符是严格
	# 引用（拼接文本只能来自别名），'-' 等运算符对文本显式报错
	'dev_expr.sql|dev_expr_head.mt|0|note=from-2|note=from-1'
	'dev_expr.sql|dev_expr_param.mt|0|test=200'
	'dev_expr.sql|dev_expr_cell.mt|0|"echo":"hello-2"'
	'dev_expr.sql|dev_expr_minus.mt|1|cannot be applied to a text operand'
	'dev_expr.sql|dev_expr_undefined.mt|1|not a defined hardware variable'
)
# parse_cases 的切分与过滤循环（原先内联在顶层——bash 的 local 只能在函数内
# 使用，循环体里的 `local f` 每次迭代都向 stderr 报错一次且变量泄漏为全局）。
# 收进函数后切分变量按函数局部作用域，`filter` 仍读全局。
if [ ! -x "$bin" ]; then
	n_declared="$(count_parse_declared)"
	[ "$n_declared" -gt 0 ] && artifact_missing "无硬件契约" "$n_declared 条用例" "$bin" "$bot_explicit"
else
	run_parse_cases
fi

# ======================================================================
# 仿真器 IMU/里程计守护采样 e2e（2026-10-16）：真二进制 + 两路守护 + sources
# 聚合 + Monitor 消费，详见 run_one_sim_nav_e2e（test/lib/sections/lua_e2e.sh）。
# ======================================================================
if filter_matches "sim_nav" "$filter"; then
	run_one_sim_nav_e2e
fi


# ======================================================================
# controller/trigger 多列：顺序与数据到位（BOT4CJ_DEBUG=1）。
# 正身断言已登记 parse_cases，本节补需要调试开关/行序的三条观察面：
#   trig_basic  触发先于消费、返回表以触发器名为键并入 call 参数 dump、
#               触发器数据是输入侧（controller 转发 payload 不含触发器子表）
#   trig2_basic 两个触发器按列声明序触发（s1 < s2 < sink），返回表各自按名到位
#   ctrl2_basic 扇出广播：payload 构建一次（Forward dump 恰一次），每个
#               controller 各收到同一份数据（各自 Controller result dump）
# ======================================================================
# C8（2026-09-20 审计）：本段此前**没有 $filter 守卫**（邻居段落如 mtmerge 都有），
# 于是它在任何过滤器调用下都无条件跑 3 条用例 —— `run_all.sh zzz_typo` 会以
# 「3 通过, 0 失败」退出 0，把末尾那条 `pass + fail == 0` 的空匹配防线整条废掉
# （该防线正是为「过滤器拼错不得假绿」而设）。守卫后语义与其它段落一致。
# F3-5 余部①：三条观察面抽成同型 runner，条数由 count_calls 数调用点推导。
# （函数定义已移至 test/lib/sections/lua_e2e.sh）

if filter_matches "trig_basic" "$filter" || filter_matches "trig2_basic" "$filter" \
	|| filter_matches "ctrl2_basic" "$filter" || filter_matches "trigger" "$filter" \
	|| filter_matches "controller" "$filter"; then
if [ ! -x "$bin" ]; then
	artifact_missing "controller/trigger 多列观察面" "$(( $(count_calls run_one_trig_obs) )) 条用例" "$bin" "$bot_explicit"
else
	run_one_trig_obs 'trig_basic' 'trigger 前置调用'
	run_one_trig_obs 'trig2_basic' 'trigger 多列'
	run_one_trig_obs 'ctrl2_basic' 'controller 多列'
fi
fi	# C8：$filter 守卫（与邻居段落同语义）

# ======================================================================
# mtmerge 离线合成器已移除（2026-10-10）：运行端 @Merge 展开仍保留，归并内核
# mtmerge_core 由 test_mtmerge.cpp 白盒单测覆盖。此段落原有的 5 条用例已删除。
# ======================================================================

# ======================================================================
# @Merge 归并观察面（parse_cases 只能钉单点断言，这里做多值/计数断言）：
#   include_main   三路设备合并到单时间轴——r1 滞后 1 拍、r2 滞后 2 拍；
#                  两个 include 的全部动作（100/110 与 200/210/220）都在输出里；
#                  相位前导行未起拍的设备不得以 0.0 误发（test=0 禁止出现）；
#                  主脚本自己的 timer-0 正常走完（slept 结果 JSON 在场）。
#   diamond        菱形复用：fa/fb 两臂都包含 shared.once.mt——skip 注记恰好
#                  一条（include-once 生效的直接证据；第二路若未跳过会以
#                  设备集相交报错退出）；三路动作全部在场。
# ======================================================================
# F3-5 余部①：条数由 count_calls 数调用点推导（runner 定义在分段文件，
# 调用点仍留在本文件——count_calls 数的就是它）。
if filter_matches "include" "$filter"; then
if [ ! -x "$bin" ]; then
	artifact_missing "@Merge 归并观察面" "$(( $(count_calls run_include_case) )) 条用例" "$bin" "$bot_explicit"
else
	run_include_case 'include_main' 'include-main' '@Merge 归并'
	run_include_case 'include_diamond' 'include-diamond' 'include-once'
fi
fi

# ======================================================================
# TCP 动作源端到端：唯一覆盖 actionsource.cpp（--tcp 监听分支）的守门。
# 复用 scripts/tcp_e2e.sh：起服务端 → Python 客户端下发 relay-test.mt →
# 校验服务端日志。缺编译产物判失败（本段是 actionsource.cpp 监听分支的唯一覆盖）；
# 缺 python3 仍按 README 声明的软依赖跳过并计入汇总。
# 随机高位端口（19000-19999）规避默认 19240 被占/串扰。
# ======================================================================
if filter_matches "tcp" "$filter"; then
	run_one_tcp
fi

# ======================================================================
# TCP 异常注入（审计覆盖缺口 #2）：tcp_e2e.sh 只有 happy path，半包/断连/
# 空闲挂死/垃圾帧/口令负路径此前零覆盖。复用 scripts/tcp_adversarial.sh
# 场景矩阵（详见该脚本头注释），每场景独立服务端 + 看门狗——「挂死不退」
# 本身是被断言的故障形态。缺 python3 按 SKIP 计（与 TCP 段同约定）。
# 场景数从该脚本的 run_scenario 调用点数出来（本文件不做第二份计数）。
# ======================================================================
if filter_matches "tcp" "$filter"; then
	run_one_tcp_adv
fi

# ======================================================================
# Rust agent 端到端（scripts/agent_e2e.sh，rig 迁移批次 B/C）：拓扑是
# mybot-agent（agent/，rig 驱动）↔ mybot --mcp-backend（AF_UNIX 帧）两个进程。
# R1 工具循环（三条回执真的从后端回来 + 后端侧 Lua
# 驱动见证）、R2 提示词包进系统提示词、R3 审计轨迹（agent 落 session/model 行、
# 工具行归后端）、R4 REPL + 能力门控（缺 --agent-shell 时 run_command 不在工具表）、
# R5 --check-config 正负路径、R6 单轮调用上限、R7/R7b 限流重试与恒失败、
# R8/R8b 单次超时与 SIGINT 取消、R9 图片后注、R10 stdout 写失败不 panic、
# R11 --session-file/--resume 两进程接力（批次 D，2026-09-25 落地）。
# mybot-agent 是**可选**产物（Rust 由单独 CI job 构建）：缺它按 SKIP 计；
# 缺 build/mybot 判失败（本段的后端就是它，且那是核心产物）。
#
# 原先此文件上面还有一段「agent 模式端到端」（C++ 的 22 个场景）。d384a9b9 把
# C++ Agent REPL 换成桩之后那 22 段全部打在「错误: C++ Agent 已移除」上（实测
# 119 条断言红），而该表面是**有意移除**的，留着一段恒红的守门没有意义，故整段
# 删除；它验过的性质按归属分流，不是凭空消失：
#   * 后端工具面的 6 条（apply_sql 带电生效与热删除、两者的门控对照、
#     read_variables 回读与对照、策略拒绝零副作用）→ 迁进 scripts/mcp_e2e.sh
#     的独立趟（纯 Python 帧客户端直连后端，不经模型，判据更硬）；
#   * 循环层的（工具循环、超时、重试、取消、图片后注、stdout 纯净/写失败、
#     会话持久化两进程接力）→ R 段（R11 = --session-file/--resume，批次 D）；
#   * DeepSeek/Anthropic 协议差异与恢复 → R12/R13；虚拟 DAC 读写闭环 → R14。
#     agent over TCP 远程 REPL 已评估不做（2026-09-25，决策记录见提交 c38928f）。
# ======================================================================
if filter_matches "agent" "$filter_e2e"; then
	# 状态目录双保险（2026-10-03 家目录持久化批次）：agent_e2e.sh 自身会把 MYBOT_HOME
	# 指向它的临时目录，这里再兜一层——即便那层隔离将来失效，缺省落盘的对话历史/地图
	# 也只会写进这个临时目录，绝不碰真实 $HOME/.mybot。
	_e2e_home="$(mktemp -d "${TMPDIR:-/tmp}/mybot-e2e-home.XXXXXX")"
	MYBOT_HOME="$_e2e_home" run_one_agent_rust_e2e
	# ICA 证据账本两进程（scripts/ica_e2e.sh，BOT4CJ_ICA=1 实验特性）：此前无人调用，
	# 接进同一段。产物依赖与上面那段相同，脚本自身也无条件沙箱 MYBOT_HOME，共用这层双保险。
	MYBOT_HOME="$_e2e_home" run_one_ica_e2e
	rm -rf "$_e2e_home"
	unset _e2e_home
fi

# ======================================================================
# MCP 后端端到端（scripts/mcp_e2e.sh）：Python 帧客户端（纯标准库，独立第三实现）
# 直连 mybot --mcp-backend（AF_UNIX 4B BE 帧）→ relay 虚拟机器人。含两趟能力门控对照
# （run_command 随 --agent-shell 进出工具表）、socket 0700/0600、审计 session+tool 记录、
# fd 卫生（run_command 子进程不继承 socket fd）、SIGTERM 优雅停机、M5 反面（开危险能力
# 无 policy 拒启，退出 2）。2026-09-24（批次 B）：MCP stdio 段随 sidecar→agent 迁移删除，
# 本段因此不再依赖任何 Rust 产物——Rust 侧链路断言由上面的 agent-rust-e2e 接力。
# ======================================================================
if filter_matches "mcp" "$filter_e2e"; then
	run_one_mcp_e2e
fi

# ======================================================================
# mtmerge 离线合成器相位语义回归已移除（2026-10-10，随独立 mtmerge 目标一起删除）。
# 运行端 @Merge 展开的相位语义由 test_mtinclude.cpp 覆盖。
# ======================================================================

# ======================================================================
# 审计加固回归（#1/#2/#4）：输入源信任边界与守护 setup 失败回滚。
#   tcp_host_bad    --tcp-host 非点分 IPv4 → 清晰报错、退出码非 0
#   help_exit_and_sections  --help 退出码 0 且含关键区块（帮助文本的黄金锚点，B1）
#   action_toolarge 动作脚本超 8MiB 上限 → 拒绝而非把整份输入吃进内存
#                   （防线前实测 100MB 输入 → RSS 4.2GB）
#   daemon_build_raise @Daemon 的 driver 误配成无全局 build 的模块 →
#                   必须走 fail() 回滚（打印 "driver build() raised"），
#                   而非把 Lua error 抛出 chunk 使 C++ 侧跳过 cleanup
#   mode_key_cannot_override_dispatch
#                   上游驱动返回值里的 mode 键不得改写 controller 的派发目标
#                   （N2：mode 由框架独占，必须最后写入）
#   driver_returns_nothing
#                   驱动 call() 漏写 return 不得被当成成功（N3：非表返回即契约违反）
#   driver_returns_cyclic_table
#                   驱动返回自引用表曾是宿主栈溢出裸 SIGSEGV（C-9：转换深度上限，
#                   超限时就地转 ERR——不清栈会让该 lua_State 之后无法复用）
# 夹具写在 .tmp/（已 gitignore），经 BOT4CJ_MODULE_PATH 多路径注入。
# ======================================================================

if filter_matches "hardening" "$filter" || filter_matches "tcp_host" "$filter"; then
	run_one_hardening 'tcp_host_bad' 1 '--tcp-host 地址无效' \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql --tcp 19301 --tcp-host 'not-an-ip'

	# 审计 H-2：非回环监听必须设 --tcp-token，缺省即拒绝启动（不再仅告警）
	run_one_hardening 'tcp_noloop_requires_token' 1 '非回环且未设 --tcp-token' \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql --tcp 19302 --tcp-host 0.0.0.0

	# 审计中-3：裸 --tcp（漏写端口号）明确报错，不再静默回落端口 1 走到 bind 失败
	run_one_hardening 'tcp_no_port' 1 '--tcp 需要端口号' \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql --tcp

	# B1（2026-09-20 计划 M0）：--help 此前零守门（全仓 grep 无命中）。CLI 帮助
	# 文本是用户可见契约：退出码 0 与关键区块在此钉住；选项集合与 docs/ 选项表
	# 的双向一致性由 C++ 单测 cliargs_help_option_set_matches_docs 比对。
	run_one_hardening 'help_exit_and_sections' 0 '安全约束：动作脚本只能引入新的参数键' \
		timeout $HARDENING_TIMEOUT "$bin" --help

	mkdir -p .tmp
	# 9MiB 合法动作脚本：超过 8MiB 上限，必须在读取阶段就被拒绝
	{ echo '@Action'; echo 'relay0.test;'; yes '    200;'; } 2>/dev/null | head -c 9000000 > .tmp/toolarge.mt
	run_one_hardening 'action_toolarge' 1 'exceeds the byte limit' \
		timeout $HEAVY_TIMEOUT "$bin" --robot=robots/relay-test.sql --input .tmp/toolarge.mt
	rm -f .tmp/toolarge.mt

	# F-02：结构脚本（.sql）与动作脚本统一 8 MiB 上限——旧实现只有 .mt 限流，
	# 超大 .sql 会把全部 token 驻留内存（长引号值还会按 O(n²) 钉死一核）。
	# 行长压到 ~120 B（token 数 ~76 万），避免守门内存峰值被 sanitizer 放大。
	pad="$(printf 'x%.0s' $(seq 1 100))"
	{ echo 'CREATE TABLE T ( name String );'; yes "INSERT INTO T ( name ) VALUES ('$pad');"; } 2>/dev/null | head -c 9000000 > .tmp/sql_toolarge.sql
	run_one_hardening 'sql_toolarge' 1 'exceeds the byte limit' \
		timeout $HEAVY_TIMEOUT "$bin" --robot=.tmp/sql_toolarge.sql --input /dev/null
	rm -f .tmp/sql_toolarge.sql

	# F-20：未知/拼错的 --key 不再「打印帮助 + exit 0」——CI 里的假成功出口
	run_one_hardening 'unknown_arg' 2 '未知参数：--robott' \
		timeout $HARDENING_TIMEOUT "$bin" --robott=robots/relay-test.sql

	# 多路径模块根（2026-09-20 重构阶段 2）：docs/reference.md 承诺
	# BOT4CJ_MODULE_PATH 支持 ':' 分隔多路径按序查找，但驱动侧引导只取首段
	# （58 个文件逐字相同的一行）——首段不含 lib/ 时驱动加载即失败。
	# 判别性要求：首段必须不存在，否则测不出问题。
	run_one_hardening 'multipath_module_path' 0 'Relay: test=200 note=hello-relay -> delay=200' \
		env BOT4CJ_MODULE_PATH=".tmp/no-such-module-root:./modules" \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql --input scripts/relay-test.mt

	setup_hardening_daemon_build_fixture
	run_one_hardening 'daemon_build_raise' 0 'driver build() raised' \
		env BOT4CJ_MODULE_PATH="./modules:.tmp/fixmod" timeout $HEAVY_TIMEOUT "$bin" \
		--robot=.tmp/fixmod.sql --input=.tmp/fixmod.mt

	# N2 回归：上游驱动的返回表里混进 mode 键（controller payload 会原样带着它），
	# mode 必须由框架独占、下游派发目标必须仍是 call——否则上游一句话就能让
	# 下游驱动的 call() 完全不执行且退出码仍为 0。锚点取下游自己写出的键。
	setup_hardening_mode_override_fixture
	run_one_hardening 'mode_key_cannot_override_dispatch' 0 'down_served' \
		env BOT4CJ_MODULE_PATH="./modules:.tmp/fixmod" timeout $HEAVY_TIMEOUT "$bin" \
		--robot=.tmp/fixmod_hij.sql --input=.tmp/fixmod_hij.mt

	# N3 回归：call() 漏写 return（返回 0 个值）曾被折成空表、被 ensureOk 当成
	# 成功——硬件没动却报绿。现在必须清晰报错并以非 0 退出。
	setup_hardening_no_return_fixture
	run_one_hardening 'driver_returns_nothing' 1 "returned no value" \
		env BOT4CJ_MODULE_PATH="./modules:.tmp/fixmod" timeout $HEAVY_TIMEOUT "$bin" \
		--robot=.tmp/fixmod_noret.sql --input=.tmp/fixmod_noret.mt

	# C-9 回归：驱动返回自引用表（t.self = t，最常见的笔误形态）曾是宿主栈溢出
	# 裸 SIGSEGV（退出码 139，且跳过 deactivate 清理链）——必须变成清晰契约报错。
	setup_hardening_cyclic_fixture
	run_one_hardening 'driver_returns_cyclic_table' 1 'nests deeper than' \
		env BOT4CJ_MODULE_PATH="./modules:.tmp/fixmod" timeout $HEAVY_TIMEOUT "$bin" \
		--robot=.tmp/fixmod_cyc.sql --input=.tmp/fixmod_cyc.mt

	# F5-4/P1-3：同一物理串口被两个「各自 open 独立 fd」的 UART 总线变量声明
	# （不同波特率，危险形态最小样本）。断言：结构装配期硬拒绝（ IllegalArgumentException
	# 折成 ERR 输出，rc=1）——此前只告警，P1-3 起升级为硬门禁。
	# 取向声明见 docs/faq.md。夹具按 hardening 段惯例运行期生成进 .tmp/
	# （不进 robots/test/：孤儿检测要求静态夹具必须接进用例表）。
	setup_hardening_uart_shared_fixture
	run_one_hardening 'uart_shared_path_rejected' 1 'is opened independently by 2 consumers' \
		env BOT4CJ_MODULE_PATH="./modules" timeout $HEAVY_TIMEOUT "$bin" \
		--robot=.tmp/uart_two_vars.sql --input /dev/null

	# F5-2：C-API 无保护帧回归——驱动给 _G 装上带报错 __index 的元表后，宿主
	# 对「缺失全局」的 getglobal 会执行该元方法。旧实现 getglobal/createtable
	# 在 pcall 之外：longjmp 构建（默认源码构建）下无捕获跳转即 panic 裸崩
	# （134/139，跳过 deactivate 清理链）；C++ unwind 构建下虽被宿主兜底
	# catch 折成 rc=1，但文案是含混的「non-standard exception」，真实报错
	# 文本全丢。现「取全局 + 造参数表 + 填参」整段进受保护帧，两种构建下
	# 都折成既有 ERR 契约（rc=1 + 带上下文的报错文本）。夹具只定义 build
	# 不定义 call：结构期 build 正常，动作派发的 call 触发 __index。
	setup_hardening_getglobal_fixture
	run_one_hardening 'lua_getglobal_unprotected_frame' 1 'boom from __index' \
		env BOT4CJ_MODULE_PATH="./modules:.tmp/fixmod" timeout $HEAVY_TIMEOUT "$bin" \
		--robot=.tmp/fixmod_gmt.sql --input=.tmp/fixmod_gmt.mt
fi

# ======================================================================
# agent CLI 负路径（F-20 同族；2026-09-24 随「agent 循环迁 Rust」整体改写：
# --agent 已移除（cliargs 快速失败 + 指引），模型循环类选项指路 mybot-agent，
# 门控类选项归属 --mcp-backend，--check-config 与 --mcp-backend 联用）。
#
# AG-23（第三轮审计）：这些用例独立设门——裸 `hardening` 仍进（向后兼容）、
# `agent-all` 也进（那是覆盖全表面的入口）、单条名字前缀 `agent_` 也进。
# ======================================================================
if filter_matches "hardening" "$filter" || [ "$filter" = "agent-all" ] \
	|| [[ "$filter" == agent_* ]]; then

	# 1) 模型循环类选项属于 mybot-agent：显式拒绝退出 2 并指路（不静默忽略、
	#    也不报「未知参数」——那是 mybot-agent 的选项面，本程序只是不跑模型循环）
	if case_matches 'agent_opt_outside_agent'; then
	run_one_hardening 'agent_opt_outside_agent' 2 '属于 Rust agent' \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql --task '让继电器动作一次'
	fi

	# 2) --agent 已移除（agent 循环迁 Rust）：校验层快速失败退出 2 + 两进程替代
	#    用法指引——不再有「注入 LLM 驱动 → 装配哨兵 → TCP accept → 桩报错」的
	#    死工作序列（原三条 --agent --tcp 组合互斥用例随之改写为等价负路径）
	if case_matches 'agent_tcp_input_mutex'; then
	run_one_hardening 'agent_tcp_input_mutex' 2 '--agent 已移除' \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql --agent --tcp 19399 --input=/dev/null
	fi
	if case_matches 'agent_tcp_task_mutex'; then
	run_one_hardening 'agent_tcp_task_mutex' 2 '--mcp-backend 与 --tcp 互斥' \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql \
		--mcp-backend --mcp-socket /tmp/hard-mcp.sock --tcp 19399
	fi
	if case_matches 'agent_tcp_crossmachine_needs_token'; then
	run_one_hardening 'agent_tcp_crossmachine_needs_token' 2 '需要 --mcp-socket' \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql --mcp-backend
	fi

	# 3) 后端 + 危险能力 ⇒ 强制外部确认（评估 §3.2）：开 --agent-shell 必须配
	#    --agent-policy 且 require_confirm 含 run_command，否则 buildAgentConfig
	#    拒绝启动（退出 2，配置错误不碰真机）。原「agent 缺 API key」用例随
	#    --agent 移除改写——C++ 宿主侧已无模型调用，「缺 key」判据归
	#    mybot-agent（agent_e2e.sh R5 的 --check-config 场景）
	if case_matches 'agent_missing_key'; then
	run_one_hardening 'agent_missing_key' 2 '必须用 --agent-policy' \
		timeout $HARDENING_TIMEOUT "$bin" --robot=robots/relay-test.sql \
		--mcp-backend --mcp-socket /tmp/hard-mcp.sock --agent-shell
	fi

	# 4) 提示词包选项归属：--prompt-file 属 mybot-agent（总量上限 F2-9 的判据
	#    也随之在 Rust prompt.rs，agent_e2e.sh 的 R2b 场景钉「超 64KiB 启动即拒」；
	#    C++ 侧的配置期预检已随 --agent 移除不可达）。本程序对它显式拒绝并指路。
	if case_matches 'agent_prompt_over_cap'; then
	mkdir -p .tmp
	awk 'BEGIN { for (i = 0; i < 3000; i++) print "padding line for the system prompt cap test" }' \
		> .tmp/bigprompt.md
	run_one_hardening 'agent_prompt_over_cap' 2 '属于 Rust agent' \
		env BOT4CJ_LLM_KEY=dummy timeout $HEAVY_TIMEOUT "$bin" \
		--robot=robots/relay-test.sql --prompt-file .tmp/bigprompt.md
	fi

	# 5) PL-1（2026-09-22）：--check-config 的端到端判据（2026-09-24 起与
	#    --mcp-backend 联用；配置文件经 BOT4CJ_LLM_CONFIG 指定——--llm-config
	#    选项本身已属 mybot-agent，但配置文件查找链两侧共用）。
	#    这条选项的**全部价值**在「不装载结构、不上电、不联网」，所以只断言
	#    「打印了摘要」不够——把这三件事分别钉住：
	#      ① 正向：配置指向必然拒绝连接的接入点（127.0.0.1:1）仍 rc=0，
	#         且输出里**没有网络错误字样** → 证明它真的没发起请求；
	#      ② 「只读不装载」：结构脚本**可读但不是合法 SQL** 时 --check-config 仍
	#         rc=0，而对同一脚本真跑一次必然非 0 → 两者对照才证明它只读了脚本头、
	#         没有走 SQL 解析与上电（若结构脚本连读都读不到，那是配置错误，
	#         与真跑同样非 0，故不能拿「不存在的脚本」当这条的夹具）；
	#      ③ 配置拼错字段 → rc=2（校验仍然生效，不是「什么都放行」）。
	#    配置文件一律写真实临时文件并经环境变量显式指定：不用 <(...) 进程替换
	#    （被 open 时报 /dev/fd/63 打不开），也不能省略——CWD 里恰好存在的
	#    ./mybot.llm.json 会被自动拾取，让用例随开发者本机配置飘。
	if case_matches 'agent_check_config'; then
	printf '{"endpoint":"http://127.0.0.1:1/v1/chat/completions","model":"m"}' \
		> .tmp/checkcfg_ok.json
	printf '{"api_kee":"x"}' > .tmp/checkcfg_bad.json
	printf 'THIS IS NOT SQL AT ALL;\n' > .tmp/checkcfg_badstruct.sql

	run_one_hardening 'agent_check_config_ok' 0 '配置校验通过' \
		env BOT4CJ_LLM_KEY=dummy BOT4CJ_LLM_CONFIG=.tmp/checkcfg_ok.json timeout $HEAVY_TIMEOUT "$bin" \
		--robot=robots/relay-test.sql --mcp-backend --check-config

	echo "----- agent_check_config_no_network (agent) -----"
	out="$(env BOT4CJ_LLM_KEY=dummy BOT4CJ_LLM_CONFIG=.tmp/checkcfg_ok.json timeout $HEAVY_TIMEOUT "$bin" \
		--robot=robots/relay-test.sql --mcp-backend --check-config 2>&1)"
	if echo "$out" | grep -qiE 'curl|连接|connection|refused|网络错误'; then
		record_fail "agent_check_config_no_network(输出含网络错误字样)"
		echo "$out"
	else
		record_pass
	fi

	echo "----- agent_check_config_only_reads_structure_head (agent) -----"
	cfg_rc=0
	env BOT4CJ_LLM_KEY=dummy BOT4CJ_LLM_CONFIG=.tmp/checkcfg_ok.json timeout $HEAVY_TIMEOUT "$bin" \
		--robot=.tmp/checkcfg_badstruct.sql --mcp-backend --check-config \
		>/dev/null 2>&1 || cfg_rc=$?
	run_rc=0
	env BOT4CJ_LLM_KEY=dummy BOT4CJ_LLM_CONFIG=.tmp/checkcfg_ok.json timeout $HEAVY_TIMEOUT "$bin" \
		--robot=.tmp/checkcfg_badstruct.sql \
		--mcp-backend --mcp-socket /tmp/hard-mcp.sock >/dev/null 2>&1 || run_rc=$?
	if [ "$cfg_rc" -eq 0 ] && [ "$run_rc" -ne 0 ]; then
		record_pass
	else
		record_fail "agent_check_config_only_reads_structure_head(校验 rc=$cfg_rc 应 0，真跑 rc=$run_rc 应非 0)"
	fi

	run_one_hardening 'agent_check_config_bad_field' 2 '未知字段' \
		env BOT4CJ_LLM_KEY=dummy BOT4CJ_LLM_CONFIG=.tmp/checkcfg_bad.json timeout $HEAVY_TIMEOUT "$bin" \
		--robot=robots/relay-test.sql --mcp-backend --check-config
	fi
fi

# ======================================================================
# 守护 tick 期故障注入（审计覆盖缺口 #3）：总线持续 NACK → tick error
# 日志 + count 停滞 + 主流程不受影响（rc=0，仍正常 join/清理）。
# 旧守门只断言「count 达标」（正向路径）；sensor_daemon「坏样本不发布、
# count 停滞即诊断线索」的负向设计从未被 E2E 断言。
# 夹具：NackDrv.lua（.tmp/fixmod，同 hardening 的 BOT4CJ_MODULE_PATH 注入），
# 内嵌 NackDrv_VIRT 模型：virt_tick 拍号 < 8 时正常应答，此后 I2C 写/读恒
# NACK——驱动 call 返回 ERR，守护按 tick 错误处理、不再 publish。
# 断言：rc=0、VIRTUAL HARDWARE 横幅、tick error 日志、count 恰停在 8
# （setup 预武装 virt_tick(0) 后，拍 0~7 共 8 次发布）、count 有多个取值
# （证明前 8 拍确实在发布，而非从头就没发布）、joined 行在位。
# ======================================================================
if filter_matches "nack" "$filter"; then
	run_one_daemon_nack
fi

# ======================================================================
# 进程级 fd 探针（审计覆盖缺口 #4）：长动作 + 守护持续采样期间，
# 采样 /proc/<pid>/fd 计数——稳态播放期 fd 总数必须有界且平稳，
# 「每拍/每次调用漏关一个 fd」的泄漏会表现为计数单调增长。
# 虚拟总线 fd 不占进程 fd 表（纯内存），此处盯的是真实 fd 消耗点：
# TCP listen/accept、stdin、LuaJIT 内部管道等；Lua 层的精细生命周期
# 由 test_virtbus_fdleak.lua（virtbus.fd_count）补齐。
# ======================================================================
if filter_matches "fd" "$filter"; then
	run_one_fd_probe
fi

# ======================================================================
# F-08 信号/退出路径：SIGTERM/SIGINT 只置停止标志，随后必须走正常清理链
# （runAction 停派发 → deactivate → 守护 join → 驱动 destroy），不能裸死。
# 此前 main.cpp 的 sigaction 与 robot.cpp 的停机分支全仓零覆盖。
#   signal_halt  播放中发 SIGTERM（12s 长动作，1s 后打断）
#                → rc=0 + 停派发行 + 「joined, total publishes=」行
#   signal_accept --tcp 等待客户端时发 SIGTERM → rc=1 + 明确中断报错（accept
#                 被 EINTR 打断并检查停止标志的路径）
# 夹具写在 .tmp/（gitignore）：Timer 长动作 + 无硬件守护（lib/daemon_probe.lua）。
# ======================================================================
if filter_matches "signal" "$filter"; then
	setup_hardening_signal_fixture
	{ echo '@Action'; echo 't0.delay;'; for _ in $(seq 1 60); do echo '   200;'; done; echo '@'; } > .tmp/signal_long.mt
	run_one_signal 'signal_halt' 0 'Stop requested, halting action dispatch' 'joined, total publishes=' \
		"$bin" --robot=.tmp/signal_robot.sql --input=.tmp/signal_long.mt
	run_one_signal 'signal_accept' 1 'TCP 等待客户端连接被停止信号中断' '' \
		"$bin" --robot=robots/relay-test.sql --tcp $((18000 + RANDOM % 1000))
fi

# ======================================================================
# fixture 孤儿检测（F3/N-32）：robots/test/*.sql 与 scripts/test/*.mt 里没被
# 任何用例表/脚本引用的夹具会静默失效——新写了回归夹具却忘了接进用例表，
# 守门全绿而该夹具从未跑过一次。判据：文件 stem（去扩展名）与带扩展名基名
# 是否作为**整字段**出现在用例表正文（e2e_cases 的用例名、parse_cases 的两列
# 文件名）/ scripts/*.sh / CMakeLists.txt 中。
# C11（2026-09-20 审计）：原判据是**子串**，并以此为设计（「注册了其一即视为
# 该名字空间已被守门认知」）——实测该理由不成立：每个真机夹具 `bme280.mt`
# 都是已登记仿真用例 `bme280_virt` 的子串，于是 26 对真机夹具（52 个文件）
# 被整体误判为「已登记」而从不执行，检测器却报「无孤儿」——覆盖静默变薄。
# 现改为整字段精确匹配：真机夹具必须在此白名单显式声明，漏登记的纯逻辑夹具
# 会立刻判失败。注意用例表条目有**两种引号形态**（parse_cases 里 expect 含
# 单引号的条目用双引号书写，如 vars_bad 的 "has no 'value' column"），提取
# 标识符时两种都要认——只认单引号会让这类条目被误判成孤儿（本次修正中实测踩到）。
# 实机夹具（需 /dev/i2c-*、/dev/spidev*、/dev/gpiochip*、/dev/pwmchip*、
# /dev/serial*，离线守门跑不了）在下方白名单显式登记，每个都对应文件头注释的
# 「实机测试」；白名单外出现孤儿即判失败——或接进用例表，或在此声明为实机夹具。
# 与「用例表引用的文件必须存在」互补：这里管漏登记，那里管空引用。
# 只在无过滤器的全量跑里执行（与常量自检同理由）。
# ======================================================================
# 前 9 个为既有登记；后半 26 个是审计 C11 修正判据后如实暴露的真机夹具
# （文件头均注明「实机测试」）：ads1115 adxl345 amg8833 as3935 as7262 bh1745
# bh1750 bme280 bmi270 bmm150 emc2101 ina219 ina226 ina3221 lcd1206 lsm6dsv
# ltc2944 max17043 mhz19 mlx90393 ms5611 sgp30 sht3x uart vl53l0x vl53l4cd
orphan_whitelist="ad9833 ads1115_diff gpio hal_i2c jit_rows mcp4725 mpu_filter pwm tpl0501 ads1115 adxl345 amg8833 as3935 as7262 bh1745 bh1750 bme280 bmi270 bmm150 emc2101 ina219 ina226 ina3221 lcd1206 lsm6dsv ltc2944 max17043 mhz19 mlx90393 ms5611 sgp30 sht3x uart vl53l0x vl53l4cd"

# ======================================================================
# 系统常量自检（F-24）：Lua 侧硬编码 ioctl/termios 编号（hal_backend_glibc.lua）
# 与波特率映射表（lib/hal/uart.lua）跟系统头的一致性已在编译期断言（构建失败
# 即漂移）；此处执行期再跑一遍作为双保险。二进制与 mybot_tests 同目录构建
# （BOT_TESTS 指向 sanitizer 构建时同样适用）。只在无过滤器的全量跑里执行——
# 过滤器只匹配用例名，常量自检不受过滤语义管辖，且不能让「拼错过滤器」的空
# 匹配防线失效。
# ======================================================================

# ======================================================================
# C++ 层单元测试（test/cpp/）：解析器与值语义工具的白盒覆盖，零第三方框架。
# 守门契约与 Lua/E2E 段完全一致：退出码 0 + [DONE] 完成标记 + [PASS] 计数非零
# （三者缺一即判失败，防「用例没跑起来却报绿」）。
# 测试二进制缺省 ./build/mybot_tests，可用 BOT_TESTS=xxx 覆盖。
# 命令行过滤器同样传给 C++ 单测；未命中任何用例时按 SKIP 处理
# （过滤器多为 Lua 用例名，不应因此判红；全仓库无匹配由末尾的空匹配防线兜底）。
# ======================================================================
if [ -z "$filter" ]; then
	run_fixture_orphans
	run_const_checks "$(dirname "$tests_bin")"
fi
run_cpp_unit
run_harness_selftest

# 空匹配防线：过滤器拼错时 0 通过 0 失败不得假绿
if [ $((pass + fail)) -eq 0 ]; then
	echo "汇总: 无匹配用例（过滤器 '${filter}' 未命中任何 test/test_*.lua、mybot E2E、无硬件契约回归、TCP E2E、agent E2E、输入边界加固、C++ 单测或测试骨架自证，请检查拼写）"
	exit 1
fi
echo "汇总: $pass 通过, $fail 失败, $skip 跳过"
if [ "$skip" -gt 0 ]; then
	echo "未执行:$skipped_list"
fi
if [ $fail -ne 0 ]; then
	echo "失败用例:$failed"
	echo "守门结果: rc=1"
	exit 1
fi
echo "守门结果: rc=0"
