# test/lib/sections/accounting.sh —— 守门分段 runner（自 run_all.sh 抽出，F3-1）
#
# 抽取原则（零行为变化）：**只搬函数定义**。用例表、调用循环、记账与汇总
# 全部留在 run_all.sh——`count_calls` 数的是 run_all.sh 里的调用点，
# `$SELF` 孤儿检测也以它为准；这些函数只被 run_all.sh source，不单独执行。
# 它们依赖 run_all.sh 的全局量（$SELF/$bin/$tests_bin/$filter/record_*/用例表），
# 因此**只能在 source 之后调用**，且不要在本文件里读 $1 之类的入口参数。

record_pass() { pass=$((pass + 1)); }

record_fail() { fail=$((fail + 1)); failed="$failed $1"; }

record_skip() { skip=$((skip + 1)); skipped_list="$skipped_list $1"; }

count_calls() { grep -cE "^[[:space:]]*$1 ['\"]" "$SELF"; }

artifact_missing() {
	local phase="$1" count="$2" path="$3" explicit="$4"
	if [ "$ALLOW_SKIP" = "1" ] && [ "$explicit" != "1" ]; then
		echo "[SKIP] $phase —— $count未执行（缺编译产物 $path，ALLOW_SKIP=1 放行）"
		record_skip "$phase"
		return 0
	fi
	echo "[FAIL] 守门不完整：$phase —— $count未执行（缺可执行产物 $path）"
	echo "       先构建：cmake -S . -B build && cmake --build build"
	echo "       只想跑 Lua 段请显式声明：ALLOW_SKIP=1 bash test/run_all.sh"
	record_fail "$phase(缺产物)"
	return 1
}

count_e2e_declared() {
	local n=0 spec name
	for spec in "${e2e_cases[@]}"; do
		name="${spec%%|*}"
		if filter_matches "$name" "$filter"; then n=$((n + 1)); fi
	done
	echo "$n"
}

count_parse_declared() {
	local n=0 spec sql rest mt
	for spec in "${parse_cases[@]}"; do
		sql="${spec%%|*}"
		rest="${spec#*|}"
		mt="${rest%%|*}"
		if filter_matches "$sql" "$filter" || filter_matches "$mt" "$filter"; then
			n=$((n + 1))
		fi
	done
	echo "$n"
}

# 假绿判定：检查输出是否满足「退出码 0 + [DONE] 完成标记 + [PASS] 计数非零」三件套。
# 三者缺一即判失败，防「用例没跑起来却报绿」。三处同形态（Lua 段、C++ 单测、骨架自证）
# 收成本函数，判据单点。
# 参数：$1=输出内容 $2=退出码 $3=分段名（记账用）
# 返回：0=通过（已 record_pass） 1=失败（已 record_fail）
check_green() {
	local out="$1" rc="$2" section="$3"
	local pass_n
	pass_n="$(printf '%s\n' "$out" | grep -cF '[PASS]')"
	if [ "$rc" -ne 0 ] || [ "$pass_n" -eq 0 ] || ! printf '%s\n' "$out" | grep -qF "[DONE]"; then
		echo "[FAIL] 假绿嫌疑：$section —— 退出码非零、[PASS] 计数为 0 或缺 [DONE] 完成标记（早退/守卫短路/零断言）"
		record_fail "$section"
		return 1
	fi
	return 0
}

# python3 依赖检查：README 声明的可选软依赖，缺则本段自动跳过。
# 参数：$1=分段名（记账用）
# 返回：0=存在 1=缺失（已 record_skip 并返回 2）
require_python3() {
	local section="$1"
	if ! command -v python3 >/dev/null 2>&1; then
		echo "[SKIP] 无 python3（$section），跳过本段"
		record_skip "$section(缺python3)"
		return 2
	fi
	return 0
}

