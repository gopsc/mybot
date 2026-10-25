# test/lib/agent_stale.sh —— mybot-agent（Rust）产物新鲜度判据的唯一事实源
#
# 为什么单拎一份：同一条「agent/src、agent/Cargo.toml、agent/Cargo.lock 里有文件新于
# 产物 ⇒ 产物陈旧」此前在 test/lib/sections/net_agent.sh 的 agent-rust-e2e 与 ica-e2e
# 两段各手写一遍（S17，2026-09-26），scripts/git-hooks/pre-push 又要写第三遍。取材面
# 一旦变化——例如新增 agent/build.rs 或 agent/tests/——漏改任一处，那一处就会把旧产物
# 判成「新鲜」而静默放行。故三处共用本文件。
#
# 与 C++ 侧判据（run_all.sh 顶部「产物陈旧判据」，取材面 src/、test/cpp/、CMakeLists.txt）
# 刻意分成两份：两套构建系统各有自己的编译期输入，并成一条会让任一侧的取材面变化误伤
# 另一侧（改 Rust 却要求重编 C++，反之亦然）。跨构建不做代码生成是既定纪律。
#
# 本文件只定义函数、无副作用，可被 run_all.sh 与 git 钩子分别 source。

# agent_stale_file <产物路径>
#   产物比某个 Rust 侧编译期输入旧 ⇒ 打印第一个这样的输入路径（退出码仍为 0）；
#   产物新鲜、或产物不存在 ⇒ 不打印任何东西。
#   「产物不存在」由各调用方自己处置（守门按 [SKIP] 计并提示重建命令、pre-push 判红），
#   三处文案与降级策略各不相同，故不在这里合并成一个返回值。
agent_stale_file() {
	local bin="$1"
	[ -x "$bin" ] || return 0
	find agent/src agent/Cargo.toml agent/Cargo.lock -type f \
		-newer "$bin" -print -quit 2>/dev/null
}
