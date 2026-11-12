# test/lib/sections/lua_e2e.sh —— 守门分段 runner（自 run_all.sh 抽出，F3-1）
#
# 抽取原则（零行为变化）：**只搬函数定义**。用例表、调用循环、记账与汇总
# 全部留在 run_all.sh——`count_calls` 数的是 run_all.sh 里的调用点，
# `$SELF` 孤儿检测也以它为准；这些函数只被 run_all.sh source，不单独执行。
# 它们依赖 run_all.sh 的全局量（$SELF/$bin/$tests_bin/$filter/record_*/用例表），
# 因此**只能在 source 之后调用**，且不要在本文件里读 $1 之类的入口参数。

run_one_e2e() {
	local name="$1" float_ere="$2" count_min="$3"
	echo "----- $name (mybot E2E) -----"
	# 动作时长约 1s，给 30s 上限防挂死；mybot 退出码原样透传
	if [ -n "$timeout_cmd" ]; then
		out="$(cat "scripts/test/$name.mt" | timeout 30 "$bin" --robot="robots/test/$name.sql" 2>&1)"
	else
		out="$(cat "scripts/test/$name.mt" | "$bin" --robot="robots/test/$name.sql" 2>&1)"
	fi
	local rc=$?
	echo "$out"
	local e2e_ok=true
	[ $rc -ne 0 ] && e2e_ok=false
	echo "$out" | grep -qF "VIRTUAL HARDWARE" || e2e_ok=false
	echo "$out" | grep -qE "chunk setup error|chunk load error|setup failed|tick error|cleanup error|解析失败" \
		&& e2e_ok=false
	echo "$out" | grep -qF "joined, total publishes=" || e2e_ok=false
	# 守护持续发布：出现 ≥2 个不同 count 且最大值达标
	local count_max count_uniq
	count_max="$(echo "$out" | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)"
	count_uniq="$(echo "$out" | grep -oE '"count":[0-9]+' | sort -u | wc -l)"
	{ [ -z "$count_max" ] || [ "$count_max" -lt "$count_min" ] || [ "$count_uniq" -lt 2 ]; } && e2e_ok=false
	# raw 快照里 :f 浮点字段保持小数（未被 sign=16 取整补码）
	echo "$out" | grep -qE "$float_ere" || e2e_ok=false
	# EMA 已推进：至少一行 monf 快照 out ≠ raw（首拍种子相同，后续 α 混合必不同）。
	# JSON 键序不固定，逐行各自提取 out/raw 数值做比对。
	local mixed_n=0 o r
	while IFS= read -r line; do
		o="$(printf '%s' "$line" | grep -oE '"out":-?[0-9]+(\.[0-9]+)?' | head -1 | cut -d: -f2)"
		r="$(printf '%s' "$line" | grep -oE '"raw":-?[0-9]+(\.[0-9]+)?' | head -1 | cut -d: -f2)"
		if [ -n "$o" ] && [ -n "$r" ] && [ "$o" != "$r" ]; then
			mixed_n=$((mixed_n + 1))
		fi
	done < <(printf '%s' "$out" | grep -F '"raw"')
	[ "$mixed_n" -ge 1 ] || e2e_ok=false
	if $e2e_ok; then
		record_pass
	else
		record_fail "$name(E2E)"
	fi
}

run_one_parse() {
	local sql="$1" mt="$2" want_rc="$3" expect="$4" forbid="$5" via="${6:-}"
	echo "----- $sql/$mt (no-hw contract) -----"
	local sql_path="$sql" mt_path="$mt"
	[[ "$sql" != */* ]] && sql_path="robots/test/$sql"
	[[ "$mt" != */* ]] && mt_path="scripts/test/$mt"
	if [ "$via" = "I" ]; then
		# --input 文件通道：include 基准 = 脚本所在目录（片段夹具的正确基准）
		if [ -n "$timeout_cmd" ]; then
			out="$($timeout_cmd "$bin" --robot="$sql_path" --input="$mt_path" 2>&1)"
		else
			out="$("$bin" --robot="$sql_path" --input="$mt_path" 2>&1)"
		fi
	elif [ -n "$timeout_cmd" ]; then
		out="$(cat "$mt_path" | timeout 30 "$bin" --robot="$sql_path" 2>&1)"
	else
		out="$(cat "$mt_path" | "$bin" --robot="$sql_path" 2>&1)"
	fi
	local rc=$?
	echo "$out"
	local p_ok=true
	[ "$rc" -ne "$want_rc" ] && p_ok=false
	echo "$out" | grep -qF "$expect" || p_ok=false
	# 可选「禁止出现」断言（用例表第 5 字段）：用于「修复后不再出现的旧症状」
	# （如 $ 引用已释放变量的 Deactive warning、build 期不该发生的 spawned）
	if [ -n "$forbid" ]; then
		echo "$out" | grep -qF "$forbid" && p_ok=false
	fi
	if $p_ok; then
		record_pass
	else
		record_fail "$sql/$mt(no-hw)"
	fi
}

run_parse_cases() {
	local spec sql rest mt want_rc f expect forbid via
	for spec in "${parse_cases[@]}"; do
		sql="${spec%%|*}"
		rest="${spec#*|}"
		mt="${rest%%|*}"
		rest="${rest#*|}"
		want_rc="${rest%%|*}"
		rest="${rest#*|}"
		# 剩余字段：expect[|forbid[|via]]（via="I" = --input 文件通道，见用例表注释）
		IFS='|' read -ra f <<< "$rest"
		expect="${f[0]:-}"
		forbid="${f[1]:-}"
		via="${f[2]:-}"
		if [ -n "$filter" ] && [[ "$sql" != *"$filter"* ]] && [[ "$mt" != *"$filter"* ]]; then
			continue
		fi
		run_one_parse "$sql" "$mt" "$want_rc" "$expect" "$forbid" "$via"
	done
}

# 仿真器 IMU/里程计守护采样 e2e（2026-10-16，第一档 sim 桥）：真二进制
# mybot + 两路守护（sim_sensor_daemon）+ sources 聚合 + Monitor 消费。
# GL 壳（mybot-sim）在 CI/无显示环境不可构建，imu/odom 桥由
# test/lib/sim_responder.lua 应答桩顶替（帧格式与 sim/src/{imu,odom}.cpp 一致）。
# 断言：消费 JSON 出现 "v9"（10 值拼接 = imu 5 + odom 5，序 = sources 声明序）。
run_one_sim_nav_e2e() {
	local imu_sock="/tmp/mybot-test-nav-imu-$$.sock"
	local odom_sock="/tmp/mybot-test-nav-odom-$$.sock"
	echo "----- spider_sim_nav (sim imu/odom daemon e2e) -----"
	# 应答桩：imu 两帧（含 airborne=1 帧）、odom 一帧；逐连接循环应答
	"$LUACMD" test/lib/sim_responder.lua "$imu_sock" \
		"OK 1.5 0.75 1.25 -0.5 0" "OK 30 -1.5 0 0 1" 2>/dev/null &
	local rpid1=$!
	"$LUACMD" test/lib/sim_responder.lua "$odom_sock" \
		"OK 1.5 -2.25 90 -0.8 12.75" 2>/dev/null &
	local rpid2=$!
	# 等两个桩 bind 完成（socket 文件出现，最多 2.5s）
	local i
	for i in $(seq 1 50); do
		[ -S "$imu_sock" ] && [ -S "$odom_sock" ] && break
		sleep 0.05
	done
	local out rc
	out="$(cat scripts/spider_sim_nav.mt | \
		MYBOT_SIM_IMU_SOCK="$imu_sock" MYBOT_SIM_ODOM_SOCK="$odom_sock" \
		timeout 30 "$bin" --robot=robots/spider_sim_nav.sql 2>&1)"
	rc=$?
	echo "$out"
	kill "$rpid1" "$rpid2" 2>/dev/null
	wait "$rpid1" "$rpid2" 2>/dev/null
	rm -f "$imu_sock" "$odom_sock"
	local p_ok=true
	[ "$rc" -ne 0 ] && p_ok=false
	echo "$out" | grep -qF '"v9":' || p_ok=false
	echo "$out" | grep -qF 'joined, total publishes=' || p_ok=false
	if $p_ok; then
		record_pass
	else
		record_fail
	fi
}

# mtmerge 离线合成器已移除（2026-10-10）：相关 runner 与 fixture 函数已不再使用。
# 运行端 @Merge 展开的测试由 test/run_all.sh 的 include 段覆盖。


# F3-5 余部①：原 run_include_observation 拆成按用例调用的 runner——
# 条数由 run_all.sh 侧 count_calls run_include_case 数调用点推导（调用点必须
# 留在 run_all.sh：count_calls 数的就是它）。断言体零行为变化，只是按名分派。
run_include_case() {
	local name="$1" banner="$2" label="$3"
	echo "----- $banner ($label 观察面) -----"
	local out rc ok
	out="$(cat "scripts/test/$name.mt" | timeout 30 "$bin" --robot=robots/test/include_demo.sql 2>&1)"
	rc=$?
	echo "$out"
	ok=true
	[ "$rc" -ne 0 ] && ok=false
	if [ "$name" = "include_main" ]; then
		local v
		for v in 100 110 200 210 220; do
			echo "$out" | grep -qF "test=$v" || ok=false
		done
		echo "$out" | grep -qF "test=0" && ok=false
		echo "$out" | grep -qF '"slept":200' || ok=false
	else
		# include_diamond：include-once 生效的直接证据——skip 注记恰好一条
		local skip_n
		skip_n="$(echo "$out" | grep -cF "already included")"
		[ "$skip_n" -eq 1 ] || ok=false
		local v
		for v in 100 200 300; do
			echo "$out" | grep -qF "test=$v" || ok=false
		done
	fi
	if $ok; then
		record_pass
	else
		record_fail "$banner($label)"
	fi
}

# mtmerge 离线合成器已移除（2026-10-10）：run_one_mtmerge_phase 不再使用。

# F3-5 余部①：三条观察面抽成同型 runner，条数由 count_calls 数调用点推导。
run_one_trig_obs() {
	local name="$1" label="$2"
	echo "----- $name ($label 观察面) -----"
	local out rc ok
	out="$(cat "scripts/test/$name.mt" | BOT4CJ_DEBUG=1 $timeout_cmd "$bin" --robot="robots/test/$name.sql" 2>&1)"
	rc=$?
	echo "$out"
	ok=true
	[ "$rc" -ne 0 ] && ok=false
	if [ "$name" = "trig_basic" ]; then
		local src_line sink_line
		src_line="$(printf '%s\n' "$out" | grep -nF 'Relay: test=300 note=src' | head -1 | cut -d: -f1)"
		sink_line="$(printf '%s\n' "$out" | grep -nF 'Relay: test=300 note=sink' | head -1 | cut -d: -f1)"
		if [ -z "$src_line" ] || [ -z "$sink_line" ]; then
			ok=false
		elif [ "$src_line" -ge "$sink_line" ]; then
			ok=false
		fi
		echo "$out" | grep -qF '"relay-src":{"delay":300}' || ok=false
		echo "$out" | grep -F 'Forward to controller:' | grep -qF '"relay-src"' && ok=false
	elif [ "$name" = "trig2_basic" ]; then
		local s1_line s2_line sk_line
		s1_line="$(printf '%s\n' "$out" | grep -nF 'Relay: test=300 note=s1' | head -1 | cut -d: -f1)"
		s2_line="$(printf '%s\n' "$out" | grep -nF 'Relay: test=301 note=s2' | head -1 | cut -d: -f1)"
		sk_line="$(printf '%s\n' "$out" | grep -nF 'Relay: test=301 note=sink' | head -1 | cut -d: -f1)"
		if [ -z "$s1_line" ] || [ -z "$s2_line" ] || [ -z "$sk_line" ]; then
			ok=false
		elif [ "$s1_line" -ge "$s2_line" ] || [ "$s2_line" -ge "$sk_line" ]; then
			ok=false
		fi
		echo "$out" | grep -qF '"relay-src1":{"delay":300}' || ok=false
		echo "$out" | grep -qF '"relay-src2":{"delay":301}' || ok=false
	else
		# ctrl2_basic：两个 controller 都被转发（各自的 Controller result dump 带名字）
		echo "$out" | grep -qF 'Controller result (dummy-0)' || ok=false
		echo "$out" | grep -qF 'Controller result (timer-b)' || ok=false
		# 扇出广播：payload 只构建一次（同一份数据发给每个 controller）
		[ "$(printf '%s\n' "$out" | grep -cF 'Forward to controller:')" = "1" ] || ok=false
	fi
	if $ok; then
		record_pass
	else
		record_fail "$name($label 观察面)"
	fi
}
