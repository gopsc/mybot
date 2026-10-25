# test/lib/sections/tail_checks.sh —— 守门分段 runner（自 run_all.sh 抽出，F3-1）
#
# 抽取原则（零行为变化）：**只搬函数定义**。用例表、调用循环、记账与汇总
# 全部留在 run_all.sh——`count_calls` 数的是 run_all.sh 里的调用点，
# `$SELF` 孤儿检测也以它为准；这些函数只被 run_all.sh source，不单独执行。
# 它们依赖 run_all.sh 的全局量（$SELF/$bin/$tests_bin/$filter/record_*/用例表），
# 因此**只能在 source 之后调用**，且不要在本文件里读 $1 之类的入口参数。

run_fixture_orphans() {
	echo "----- fixture-orphans (夹具孤儿检测) -----"
	# 登记标识符集合（**精确整字段**匹配，不做子串）：
	#   e2e_cases   条目是 `用例名|<正则>|<最少条数>` —— 名字即 stem（无扩展名）；
	#   parse_cases 条目是 `结构.sql|动作.mt|期望rc|...` —— 带扩展名。
	#   C11（2026-09-20 审计）：旧实现拿**去扩展名的 stem** 在两张表里 grep -F
	#   子串，而每个真机夹具 `bme280.mt` 都是已登记仿真用例 `bme280_virt` 的子串
	#   —— 它们因此被误判为「已登记」，从不执行、也从不报孤儿（覆盖静默变薄而
	#   检测器报绿）。改为整字段比较后，真机夹具必须显式进 orphan_whitelist。
	local reg_tokens=" $(
		{
			sed -n '/^e2e_cases=(/,/^)/p' "$SELF" \
				| sed -n "s/^[[:space:]]*[\"']\([^|]*\)|.*/\1/p"
			sed -n '/^parse_cases=(/,/^)/p' "$SELF" \
				| sed -n "s/^[[:space:]]*[\"']\([^|]*\)|\([^|]*\)|.*/\1 \2/p"
		} | tr '\n' ' ' | tr ' ' '\n' | sed 's#.*/##' | tr '\n' ' '
	) "
	local f stem base n=0 orphans=""
	for f in robots/test/*.sql scripts/test/*.mt; do
		stem="$(basename "$f")"; stem="${stem%.*}"
		base="$(basename "$f")"
		case " $orphan_whitelist " in *" $stem "*) continue ;; esac
		# 登记来源只看用例表正文（e2e_cases/parse_cases）+ 其它守门脚本 + CMake 目标。
		# 刻意不 grep 本文件全文：注释里顺带提一句名字并不等于接进了表。
		case "$reg_tokens" in *" $stem "*|*" $base "*) continue ;; esac
		grep -qF "$base" scripts/*.sh CMakeLists.txt 2>/dev/null && continue
		orphans="$orphans $f"
		n=$((n + 1))
	done
	if [ "$n" -eq 0 ]; then
		echo "[PASS] 无孤儿夹具（实机白名单 $(echo $orphan_whitelist | wc -w) 个）"
		record_pass
	else
		echo "[FAIL] $n 个夹具未被任何用例表引用（接进用例表，或加入 orphan_whitelist 声明为实机夹具）："
		for f in $orphans; do echo "       $f"; done
		record_fail "fixture-orphans"
	fi
}

run_const_checks() {
	echo "----- const-check (系统常量自检) -----"
	local const_dir="$1" ok=true out
	# 三个自检二进制（ioctl/uart/v4l2）均无外部依赖，缺产物按「构建产物缺失」硬失败。
	# 原第四个 test_curl_consts 随 Lua 协议驱动轨道删除（2026-09-25 #8）。
	for prog in test_ioctl_nums test_uart_consts test_v4l2_consts; do
		local binp="$const_dir/$prog"
		if [ ! -x "$binp" ]; then
			artifact_missing "系统常量自检" "$prog" "$binp" "$tests_explicit"
			return 2
		fi
		out="$("$binp" 2>&1)"
		if [ $? -ne 0 ]; then
			ok=false
			echo "[FAIL] $prog 执行失败：$out"
		else
			echo "$out"
		fi
	done
	if $ok; then
		record_pass
	else
		record_fail "const-check"
	fi
}

run_cpp_unit() {
	echo "----- cpp-unit (C++ 单测) -----"
	if [ ! -x "$tests_bin" ]; then
		artifact_missing "C++ 单测" "全部用例" "$tests_bin" "$tests_explicit"
		return 2
	fi
	local out rc pass_n
	# AG-23：C++ 分段用自己的过滤器形态（作用域语法 `agent:` 与文件名子串
	# `agent` 不是一回事）。未命中就在**本层**显式跳过，而不是把匹配不到的
	# 过滤器透传给二进制、让「无匹配用例」在下一层才出现（那样汇总里看不出
	# 是哪一层没匹配上）。
	if [ -n "$filter" ] && ! filter_matches "agent:" "$filter_cpp"; then
		echo "[SKIP] 过滤器 '${filter}' 未命中 cpp-unit 分段（该段用 '${filter_cpp}'）"
		record_skip "cpp-unit(过滤器未命中)"
		return 2
	fi
	if [ -n "$timeout_cmd" ]; then
		out="$($timeout_cmd "$tests_bin" $filter_cpp 2>&1)"
	else
		out="$("$tests_bin" $filter_cpp 2>&1)"
	fi
	rc=$?
	echo "$out"
	if [ $rc -eq 124 ] && [ -n "$timeout_cmd" ]; then
		echo "[FAIL] C++ 单测超时（>${TEST_TIMEOUT}s，疑似死循环）"
		record_fail "cpp-unit(C++)"
		return
	fi
	if echo "$out" | grep -qF "无匹配用例"; then
		# C9（2026-09-20 审计）：只有**带过滤器**时「无匹配用例」才是合法跳过。
		# 空过滤器下这句话意味着这个二进制一个用例都没注册（桩二进制、漏登记进
		# CMakeLists、产物被换）——那必须判失败，否则整段 C++ 守门静默降级成 SKIP
		# （旧实现排在这里、先于 rc 与 [PASS] 计数检查，故空过滤器也会走 SKIP）。
		if [ -n "$filter" ]; then
			echo "[SKIP] 过滤器 '${filter}' 未命中任何 C++ 用例"
			record_skip "cpp-unit(过滤器未命中)"
			return 2
		fi
		echo "[FAIL] 假绿嫌疑：C++ 单测二进制在无过滤器下报「无匹配用例」（未注册任何用例？）"
		record_fail "cpp-unit(零用例)"
		return
	fi
	if echo "$out" | grep -qF "[FAIL]"; then
		record_fail "cpp-unit(C++)"
	elif ! check_green "$out" "$rc" "cpp-unit(C++)"; then
		: # check_green 已 record_fail
	else
		record_pass
	fi
}

# ======================================================================
# 测试骨架自证（2026-09-21 审计 AG-5）：harness.hpp 的三条判定（零断言即失败 /
# TH_SKIP 不算失败 / 断言后跳过算失败）由 harness_selftest 用一份独立的 th 状态
# 自证。段契约与其他段一致：退出码 0 + [DONE] + [PASS] 非零。
# 为什么值得一个独立分段：这一条守的是「所有其它守门都依赖的那把尺子」——
# 尺子失真时，全部用例照样全绿，没有任何其它机制会发现。
# ======================================================================
run_harness_selftest() {
	echo "----- harness-selftest (测试骨架自证) -----"
	# 路径单点在 run_all.sh 顶部的 selftest_bin：产物陈旧判据也拿同一个变量，
	# 两处各派生一次的话，改了 BOT_TESTS 就会出现「判的是 A、跑的是 B」。
	local binp="$selftest_bin"
	if [ ! -x "$binp" ]; then
		artifact_missing "测试骨架自证" "harness_selftest" "$binp" "$tests_explicit"
		return 2
	fi
	# 段门（2026-10-06 补）：本段此前**不受过滤器管辖**，无条件跑完记 1 通过，于是
	# 末尾「pass + fail == 0」的空匹配防线（C8）永远不成立——`run_all.sh zzz_typo`
	# 会以「1 通过, 0 失败」退出 0。这与上面 run_const_checks / run_fixture_orphans
	# 被 `[ -z "$filter" ]` 圈住是同一个理由（run_all.sh 那段注释写的就是「不能让
	# 『拼错过滤器』的空匹配防线失效」），只是本段是 2026-09-21 AG-5 后加的，漏了。
	# 用段门而不是塞进 `[ -z "$filter" ]`：`run_all.sh harness` 是合法用法，应当放行。
	# 不往下传过滤器给二进制——本段的 8 条自证用例是一个整体，按名字挑没有意义。
	if [ -n "$filter" ] && ! filter_matches "harness-selftest" "$filter"; then
		echo "[SKIP] 过滤器 '${filter}' 未命中 harness-selftest 分段"
		record_skip "harness-selftest(过滤器未命中)"
		return 2
	fi
	local out rc pass_n
	if [ -n "$timeout_cmd" ]; then
		out="$($timeout_cmd "$binp" 2>&1)"
	else
		out="$("$binp" 2>&1)"
	fi
	rc=$?
	echo "$out"
	if [ $rc -eq 124 ] && [ -n "$timeout_cmd" ]; then
		echo "[FAIL] 测试骨架自证超时（>${TEST_TIMEOUT}s）"
		record_fail "harness-selftest"
		return
	fi
	if echo "$out" | grep -qF "[FAIL]"; then
		echo "[FAIL] 测试骨架行为与预期不符：零断言/跳过/失败的判定被改动过？"
		record_fail "harness-selftest"
	elif ! check_green "$out" "$rc" "harness-selftest"; then
		: # check_green 已 record_fail
	else
		record_pass
	fi
}
