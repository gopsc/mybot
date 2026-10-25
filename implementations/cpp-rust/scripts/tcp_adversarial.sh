#!/usr/bin/env bash
# scripts/tcp_adversarial.sh — TCP 动作源异常注入端到端（审计覆盖缺口 #2）
#
# scripts/tcp_e2e.sh 只覆盖 happy path（整脚本一次 sendall + EOF）；本脚本
# 专盯异常形态：半包慢发、中途 RST 断连、空闲挂死、二进制垃圾帧、口令负路径。
# 每个场景独立起服务端（随机端口），断言服务端退出码与日志锚点，
# 且必须带看门狗——「挂死不退」本身就是被断言的故障形态之一。
#
# 用法：BOT=./build/mybot ./scripts/tcp_adversarial.sh [port_base]
# 依赖：$BOT 可执行、python3（客户端）、robots/relay-test.sql、scripts/relay-test.mt

set -u

BOT="${BOT:-./build/mybot}"
PORT_BASE="${1:-$((21000 + RANDOM % 2000))}"
SCRIPT="scripts/relay-test.mt"
IDLE_SEC=2		# 空闲挂死场景用短超时，其余场景用缺省

fail_scenarios=""
pass_scenarios=0

if [[ ! -x "$BOT" ]]; then
	echo "错误：找不到可执行文件 '$BOT'（需先编译）"
	exit 1
fi
if [[ ! -f "robots/relay-test.sql" || ! -f "$SCRIPT" ]]; then
	echo "错误：缺少 robots/relay-test.sql 或 $SCRIPT"
	exit 1
fi
if ! command -v python3 &>/dev/null; then
	echo "错误：需要 Python 3 作为 TCP 客户端"
	exit 1
fi

# ---- 场景执行器：起服务端 → 跑场景客户端 → 看门狗收尸 → 断言 ----
# 用法: run_scenario <名称> <期望rc模式:zero|nonzero> <日志必须含|-> [<日志必须不含>] -- <服务端args...>
# 场景客户端由 run_scenario_client 里的 python3 代码按 $SCENARIO 分派。
run_scenario() {
	local name="$1" rc_mode="$2" expect="$3" forbid="$4"; shift 4
	[ "${1:-}" = "--" ] && shift
	local port=$((PORT_BASE + RANDOM % 500))
	local srv_log
	srv_log="$(mktemp "${TMPDIR:-/tmp}/tcp_adv_server.XXXXXX.log")"

	echo "----- $name (tcp-adversarial, port=$port) -----"
	"$BOT" --robot=robots/relay-test.sql --tcp "$port" --tcp-idle "$IDLE_SEC" "$@" \
		> "$srv_log" 2>&1 &
	local srv_pid=$!

	# 等服务端真正 bind+listen 再让客户端连：否则客户端会落进「进程已起、端口未监听」
	# 的时间窗，拿到 ConnectionRefused 后被误判成「服务端挂死」（ASan 构建启动慢时尤甚，
	# 实测偶发）。用 /proc/net/tcp 的 LISTEN(0A) 状态探测，**不产生额外连接**——
	# 连一下再断会污染 token_retry / token_bruteforce 这类按失败次数计数的场景。
	local port_hex ready=0
	port_hex="$(printf '%04X' "$port")"
	for _ in $(seq 1 100); do
		if grep -qE ":$port_hex 00000000:0000 0A" /proc/net/tcp 2>/dev/null; then
			ready=1
			break
		fi
		sleep 0.05
	done
	if [ "$ready" -ne 1 ]; then
		echo "   ✗ 服务端未在 5s 内进入监听状态"
		kill -KILL "$srv_pid" 2>/dev/null
		wait "$srv_pid" 2>/dev/null
		rm -f "$srv_log"
		fail_scenarios="$fail_scenarios $name(未就绪)"
		return 1
	fi

	# 场景客户端；SCENARIO/PORT 环境变量传给 python3
	SCENARIO="$name" PORT="$port" SCRIPT="$SCRIPT" TOKEN_FILE="$srv_log" \
		python3 - <<'PYEOF'
import os, random, socket, struct, sys, time

scenario = os.environ["SCENARIO"]
port = int(os.environ["PORT"])
script = open(os.environ["SCRIPT"], "rb").read()
random.seed(hash(scenario) & 0xFFFF)

def connect():
    s = socket.socket()
    s.settimeout(5)
    s.connect(("127.0.0.1", port))
    return s

if scenario == "slow_drip":
    # 半包慢发：1~16 字节随机分片，片间 5ms——服务端必须正确重组完整脚本
    s = connect()
    step = random.randint(1, 16)
    for i in range(0, len(script), step):
        s.sendall(script[i:i + step])
        time.sleep(0.005)
    s.shutdown(socket.SHUT_WR)
    time.sleep(0.2)
    s.close()

elif scenario == "mid_rst":
    # 中途 RST：发 30 字节后 SO_LINGER=0 强制 RST——服务端读路径须按错误
    # 结束（ECONNRESET → 读错误日志），不得挂死也不得裸崩
    s = connect()
    s.sendall(script[:30])
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()

elif scenario == "idle_silent":
    # 空闲挂死：连上后一个字节都不发——--tcp-idle 到期必须按输入结束退出
    s = connect()
    time.sleep(3.5)
    s.close()

elif scenario == "garbage_binary":
    # 二进制垃圾帧：随机字节（含 NUL）灌入——解析必须清晰报错退出，
    # 不裸崩（SIGSEGV=139/SIGABRT=134 都算失败）
    s = connect()
    s.sendall(bytes(random.randrange(256) for _ in range(256)))
    s.shutdown(socket.SHUT_WR)
    time.sleep(0.2)
    s.close()

elif scenario == "token_retry":
    # C-M1 回归：口令失败不再终止进程——1 次错口令被拒后，第 2 个连接
    # 用正确口令 + 脚本必须被接受（服务端回 accept 等待）
    s = connect()
    s.sendall(b"wrongtok\n")
    time.sleep(0.2)
    s.close()
    time.sleep(0.5)
    s = connect()
    s.sendall(b"tok_real\n")
    s.sendall(script)
    s.shutdown(socket.SHUT_WR)
    time.sleep(0.2)
    s.close()

elif scenario == "token_bruteforce":
    # C-M1 上限：连续 5 次错误口令后服务端放弃等待并以非 0 退出（防无限爆破）
    for _ in range(5):
        s = connect()
        s.sendall(b"wrongtok\n")
        time.sleep(0.2)
        s.close()

elif scenario == "token_overlong":
    # 超长凭据行：> token+1 字节且无换行——fail-closed 拒绝（审计 #6 回归）；
    # 同样打满 5 次让服务端按爆破上限退出
    for _ in range(5):
        s = connect()
        s.sendall(b"x" * 64)
        time.sleep(0.5)
        s.close()

elif scenario == "auth_limit_custom":
    # F-1（2026-09-22）：--tcp-max-auth-attempts 2 生效——2 次错口令即放弃，
    # 不必等到缺省的 5 次（若选项未生效，第 2 次后服务端仍在等，看门狗会
    # 在 25s 后判超时挂死，本场景借「更快失败」证明新阈值真的接管了判定）
    for _ in range(2):
        s = connect()
        s.sendall(b"wrongtok\n")
        time.sleep(0.2)
        s.close()

else:
    print(f"未知场景 {scenario}", file=sys.stderr)
    sys.exit(1)
PYEOF
	local cli_rc=$?

	# 看门狗：25s 未退出则 SIGKILL（rc=137 → 断言必失败）
	local i rc=0
	for i in $(seq 1 25); do
		if ! kill -0 "$srv_pid" 2>/dev/null; then break; fi
		sleep 1
	done
	if kill -0 "$srv_pid" 2>/dev/null; then
		echo "   ✗ 服务端超时未退出（挂死即故障）"
		kill -KILL "$srv_pid" 2>/dev/null
		wait "$srv_pid" 2>/dev/null
		rm -f "$srv_log"
		fail_scenarios="$fail_scenarios $name(挂死)"
		return 1
	fi
	wait "$srv_pid" 2>/dev/null || rc=$?
	echo "   服务端 rc=$rc 客户端 rc=$cli_rc"
	grep -E "服务端|失败|错误|error|Error" "$srv_log" | tail -3 || true

	local ok=true
	if [ "$rc_mode" = "zero" ] && [ "$rc" -ne 0 ]; then ok=false; fi
	if [ "$rc_mode" = "nonzero" ] && [ "$rc" -eq 0 ]; then ok=false; fi
	# 裸崩形态（SIGSEGV/SIGABRT）任何场景都算失败
	if [ "$rc" -ge 128 ]; then ok=false; fi
	if [ "$expect" != "-" ] && ! grep -qF "$expect" "$srv_log"; then ok=false; fi
	if [ "$forbid" != "-" ] && grep -qF "$forbid" "$srv_log"; then ok=false; fi

	if $ok; then
		pass_scenarios=$((pass_scenarios + 1))
	else
		fail_scenarios="$fail_scenarios $name"
		echo "   ✗ 断言失败（期望 rc $rc_mode / 锚点 '$expect' / 禁止 '$forbid'）"
		cat "$srv_log"
	fi
	rm -f "$srv_log"
}

# 1. 半包慢发：正常播放结束，rc=0，无读错误（回环无需口令）
run_scenario slow_drip zero "TCP 客户端已连接" "读错误" --

# 2. 中途 RST：读路径按错误结束，日志点名读错误，退出码非 0
# （客户端不发口令行直接发脚本，RST 落在脚本读取段——回环无需口令）
run_scenario mid_rst nonzero "读错误" -

# 3. 空闲挂死：idle 超时按输入结束退出（空脚本解析报错 → rc≠0），不挂死
run_scenario idle_silent nonzero "空闲超过" -

# 4. 二进制垃圾：解析清晰报错退出（含 NUL 也不截断放行），rc≠0 且非裸崩
# （垃圾字节的词法报错文本不固定，只锚退出码与「非信号崩」；服务器日志照打）
run_scenario garbage_binary nonzero - -

# 5. 口令失败重试：1 次错口令被拒 → 正确口令的后续连接被接受，rc=0（C-M1 回归）
run_scenario token_retry zero "TCP 口令校验通过" - --tcp-token tok_real

# 6. 口令爆破上限：连续 5 次错误口令后放弃等待，rc≠0（防无限爆破）
run_scenario token_bruteforce nonzero "连续 5 次校验失败" - --tcp-token tok_real

# 7. 超长凭据行：fail-closed 拒绝（审计 #6 防线），同样按爆破上限退出
run_scenario token_overlong nonzero "凭据行超长" - --tcp-token tok_real

# 8. F-1（2026-09-22）：--tcp-max-auth-attempts 2 生效——2 次失败即放弃
# （不是缺省的 5 次），日志点名新阈值本身
run_scenario auth_limit_custom nonzero "连续 2 次校验失败" - --tcp-token tok_real --tcp-max-auth-attempts 2

echo ""
if [ -n "$fail_scenarios" ]; then
	echo "=== TCP 异常注入测试失败:$fail_scenarios ==="
	exit 1
fi
echo "=== TCP 异常注入测试通过（$pass_scenarios 个场景全绿） ==="
