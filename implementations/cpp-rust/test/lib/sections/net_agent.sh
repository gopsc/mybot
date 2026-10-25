# test/lib/sections/net_agent.sh —— 守门分段 runner（自 run_all.sh 抽出，F3-1）
#
# 抽取原则（零行为变化）：**只搬函数定义**。用例表、调用循环、记账与汇总
# 全部留在 run_all.sh——`count_calls` 数的是 run_all.sh 里的调用点，
# `$SELF` 孤儿检测也以它为准；这些函数只被 run_all.sh source，不单独执行。
# 它们依赖 run_all.sh 的全局量（$SELF/$bin/$tests_bin/$filter/record_*/用例表），
# 因此**只能在 source 之后调用**，且不要在本文件里读 $1 之类的入口参数。

run_one_tcp() {
	echo "----- tcp-action-source (mybot TCP E2E) -----"
	if [ ! -x "$bin" ]; then
		artifact_missing "TCP 动作源" "该用例" "$bin" "$bot_explicit"
		return 2
	fi
	# python3 是 README 声明的可选软依赖（缺则本段自动跳过），仍计入 skip 供汇总可见
	require_python3 "TCP 客户端" || return 2
	local port tcp_rc tcp_out
	port=$((19000 + (RANDOM % 1000)))
	tcp_out="$(BOT="$bin" timeout 40 bash scripts/tcp_e2e.sh "$port" 20 2>&1)"
	tcp_rc=$?
	echo "$tcp_out"
	if [ $tcp_rc -ne 0 ] || ! echo "$tcp_out" | grep -qF "TCP 端到端测试通过"; then
		record_fail "tcp-action-source(TCP)"
	else
		record_pass
	fi
}

run_one_tcp_adv() {
	echo "----- tcp-adversarial (TCP 异常注入) -----"
	if [ ! -x "$bin" ]; then
		artifact_missing "TCP 异常注入" \
			"$(grep -c '^run_scenario [a-z]' scripts/tcp_adversarial.sh) 个场景" \
			"$bin" "$bot_explicit"
		return 2
	fi
	require_python3 "TCP 客户端" || return 2
	local out rc
	out="$(BOT="$bin" timeout 120 bash scripts/tcp_adversarial.sh 2>&1)"
	rc=$?
	echo "$out"
	if [ $rc -ne 0 ] || ! echo "$out" | grep -qF "TCP 异常注入测试通过"; then
		record_fail "tcp-adversarial(异常注入)"
	else
		record_pass
	fi
}

# agent_e2e.sh 的 C++ 模式 runner（run_one_agent_e2e）已随该模式一起删除：
# d384a9b9 把 C++ Agent REPL 换成桩之后 22 个场景全打在桩上，而该表面是有意移除的。
# 它验过的性质分流见 run_all.sh 的 Rust 段注释（工具层 6 条 → mcp_e2e.sh，循环层 → R 段）。

# MCP 后端端到端（scripts/mcp_e2e.sh，方案 F / 拓扑 F3）。
# 2026-09-24（rig 迁移批次 B）：原先这段依赖 Rust sidecar 产物（可选，故按 SKIP 计）；
# MCP 协议层随架构迁移取消后，**本段只剩 C++ 后端 + Python 帧客户端**，不再需要任何
# Rust 产物——缺 build/mybot 才判失败（那是核心产物）。Rust 侧由下面的
# run_one_agent_rust_e2e 接力（那段才按缺产物 SKIP）。
run_one_mcp_e2e() {
	echo "----- mcp-e2e (MCP 后端 + 帧客户端端到端) -----"
	if [ ! -x "$bin" ]; then
		artifact_missing "MCP 端到端" "该段（scripts/mcp_e2e.sh）" "$bin" "$bot_explicit"
		return 2
	fi
	require_python3 "帧客户端" || return 2
	local out rc
	out="$(BOT="$bin" timeout 150 bash scripts/mcp_e2e.sh 2>&1)"
	rc=$?
	echo "$out"
	if [ $rc -ne 0 ] || ! echo "$out" | grep -qF "MCP 端到端测试通过"; then
		record_fail "mcp-e2e(MCP 后端)"
	else
		record_pass
	fi
}

# Rust agent（agent/，包名 mybot-agent）端到端：scripts/agent_e2e.sh 现在**只有
# 这一种模式**——C++ Agent REPL 移除后，该脚本的 C++ 段已整体删除（见上面的分流说明），
# `--rust` 保留为兼容空参。拓扑是「mybot --mcp-backend + mybot-agent」两个进程。
# mybot-agent 是**可选**产物：C++ 回归路径不强制构建它（评估 §5.3 同一口径——只给
# Rust 单独加 CI job，不给全部 job 加 Rust），故缺它按 SKIP 计（不是假绿、也不是失败）；
# 缺 build/mybot 仍判失败（本段的后端就是它，且那是核心产物）。
run_one_agent_rust_e2e() {
	echo "----- agent-rust-e2e (mybot-agent 端到端) -----"
	if [ ! -x "$bin" ]; then
		artifact_missing "Rust agent 端到端" "该段（scripts/agent_e2e.sh --rust）" "$bin" "$bot_explicit"
		return 2
	fi
	require_python3 "假模型服务" || return 2
	local agent_bin="agent/target/release/mybot-agent"
	if [ ! -x "$agent_bin" ]; then
		echo "[SKIP] 无 mybot-agent 产物 $agent_bin（先 bash scripts/build_agent.sh --release；Rust 段是可选 CI job），跳过本段"
		record_skip "agent-rust-e2e(缺mybot-agent产物)"
		return 2
	fi
	# ---- Rust 产物陈旧守卫（S17，2026-09-26）----
	# run_all.sh 顶部的陈旧守卫只看 src/、test/cpp/、CMakeLists.txt，**不查 agent/**：
	# 改完 Rust 源码忘跑 scripts/build_agent.sh，就会用**上一轮的 mybot-agent**跑本段。
	# 本轮亲历：旧产物不认识 --resume，agent_e2e.sh 打出 86 条与真因无关的 [FAIL]，
	# 极易被误判为产品回归。与 C++ 守卫不同——那里判失败（核心产物必重建），这里判
	# **SKIP**：mybot-agent 是可选产物，且本机可能没装 cargo 无法自动重建，响亮提示 +
	# 跳过比一片误导红更稳。逃生口 BOT_ALLOW_STALE=1 与 C++ 守卫共用同一语义。
	# 取材面（哪些路径算 Rust 侧编译期输入）单点在 test/lib/agent_stale.sh，
	# 与 ica-e2e 段、scripts/git-hooks/pre-push 共用；pre-push 那边判**红**（本机能装
	# cargo 就不该让两段静默消失），SKIP 语义只属于本守门入口，两处差异是刻意的。
	if [ -z "${BOT_ALLOW_STALE:-}" ]; then
		local _agent_stale
		_agent_stale="$(agent_stale_file "$agent_bin")"
		if [ -n "$_agent_stale" ]; then
			echo "[SKIP] mybot-agent 产物早于 Rust 源码（例如 $_agent_stale），跑旧产物会得到一批与真因无关的 FAIL。"
			echo "       请先重建： bash scripts/build_agent.sh --release"
			echo "       确实要跑旧产物： BOT_ALLOW_STALE=1 bash test/run_all.sh"
			record_skip "agent-rust-e2e(mybot-agent产物陈旧)"
			return 2
		fi
	fi
	# 与 CI（.gitlab-ci.yml 的 agent job）的口径差异是**刻意的**，别只改一边：
	#   * 环境隔离的单点在 agent_e2e.sh 自己（脚本内 export BOT4CJ_LLM_CONFIG=none、
	#     MYBOT_HOME 指向它的临时目录），CI 命令前那个 BOT4CJ_LLM_CONFIG=none 只是冗余保险；
	#   * 外层 timeout 本地 90 / CI 180——CI 机器慢，本地 90 实测够用（脚本内部每次
	#     调用另有 timeout 60/20 兜底）。
	local out rc
	out="$(BOT="$bin" timeout 90 bash scripts/agent_e2e.sh --rust 2>&1)"
	rc=$?
	echo "$out"
	if [ $rc -eq 125 ] && echo "$out" | grep -qF '[SKIP]'; then
		record_skip "agent-rust-e2e(缺python3)"
	elif [ $rc -ne 0 ] || ! echo "$out" | grep -qF "mybot-agent 端到端测试通过"; then
		record_fail "agent-rust-e2e(mybot-agent)"
	else
		record_pass
	fi
}

# ICA 证据账本两进程离线校验（scripts/ica_e2e.sh，BOT4CJ_ICA=1 的实验特性）。
# 此前该脚本只有 docs/ica.md 提到、没有任何守门调用它——离线脚本没人跑就会静默腐烂
# （改坏了也没人知道），故接进 agent 段。产物依赖与 agent-rust-e2e 完全相同
# （build/mybot 必需 → 缺则失败；mybot-agent 可选 → 缺/陈旧则 SKIP），判据同口径。
# 脚本自身无条件把 MYBOT_HOME 指向它的临时目录，故这里不需要再包一层。
run_one_ica_e2e() {
	echo "----- ica-e2e (ICA 证据账本两进程) -----"
	if [ ! -x "$bin" ]; then
		artifact_missing "ICA 两进程" "该段（scripts/ica_e2e.sh）" "$bin" "$bot_explicit"
		return 2
	fi
	require_python3 "假模型服务" || return 2
	local agent_bin="agent/target/release/mybot-agent"
	if [ ! -x "$agent_bin" ]; then
		echo "[SKIP] 无 mybot-agent 产物 $agent_bin（先 bash scripts/build_agent.sh --release），跳过本段"
		record_skip "ica-e2e(缺mybot-agent产物)"
		return 2
	fi
	# 陈旧守卫同 S17 口径：跑旧产物会得到一批与真因无关的 FAIL，响亮提示 + 跳过比一片误导红更稳
	# （判据取材面单点 test/lib/agent_stale.sh，与 agent-rust-e2e 段共用）
	if [ -z "${BOT_ALLOW_STALE:-}" ] && [ -n "$(agent_stale_file "$agent_bin")" ]; then
		echo "[SKIP] mybot-agent 产物早于 Rust 源码，请先重建： bash scripts/build_agent.sh --release"
		echo "       确实要跑旧产物： BOT_ALLOW_STALE=1 bash test/run_all.sh"
		record_skip "ica-e2e(mybot-agent产物陈旧)"
		return 2
	fi
	local out rc
	out="$(BOT="$bin" AGENT_BIN="$agent_bin" timeout 90 bash scripts/ica_e2e.sh 2>&1)"
	rc=$?
	echo "$out"
	if [ $rc -ne 0 ] || ! echo "$out" | grep -qF "ICA two-process flow passed"; then
		record_fail "ica-e2e(ICA 两进程)"
	else
		record_pass
	fi
}

