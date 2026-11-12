#!/usr/bin/env bash
# scripts/tcp_e2e.sh — TCP 端到端回环测试
#
# 验证 actionsource.cpp 的 TCP 动作源：
#   1. 启动服务端（--tcp <port>，需已编译出可执行文件）
#   2. Python 客户端连接 → 发送 relay-test.mt
#   3. 客户端关闭连接（EOF）→ 服务端 run() 完成
#   4. 验证服务端退出码为 0 且输出包含预期日志
#
# 用法：./scripts/tcp_e2e.sh [port] [timeout_sec]
# 依赖：bot4cj 可执行文件（$BOT，缺省 ./build/mybot）、Python 3、
#       robots/relay-test.sql、scripts/relay-test.mt

set -euo pipefail

PORT="${1:-19240}"
TIMEOUT="${2:-15}"
BOT="${BOT:-./build/mybot}"

echo "=== TCP 端到端回环测试 ==="
echo "端口: ${PORT}  超时: ${TIMEOUT}s  可执行: ${BOT}"

if [[ ! -x "$BOT" ]]; then
	echo "错误：找不到可执行文件 '${BOT}'（需先编译）"
	echo "提示：BOT=./your-bot-binary $0"
	exit 1
fi
if [[ ! -f "robots/relay-test.sql" || ! -f "scripts/relay-test.mt" ]]; then
	echo "错误：缺少 robots/relay-test.sql 或 scripts/relay-test.mt"
	exit 1
fi
if ! command -v python3 &>/dev/null; then
	echo "错误：需要 Python 3 作为 TCP 客户端"
	exit 1
fi

# F-28：日志用 mktemp 私有文件（固定 /tmp 路径可预测、并行互踩、
# `>` 跟随符号链接）；trap 保证所有退出路径都清理。
SRV_LOG="$(mktemp "${TMPDIR:-/tmp}/tcp_e2e_server.XXXXXX.log")"
trap 'rm -f "$SRV_LOG"' EXIT

echo "[1/3] 启动服务端：${BOT} --robot=robots/relay-test.sql --tcp ${PORT}"
"$BOT" --robot=robots/relay-test.sql --tcp "$PORT" > "$SRV_LOG" 2>&1 &
SRV_PID=$!

echo "[2/3] 客户端轮询连接（拒绝=未就绪，0.5s 重试，最多 10s）并发送 relay-test.mt"
# 注意：就绪探测绝不能真的建立 TCP 连接再断开——服务端 accept() 取走的是
# 第一个连接，探测连接会被当成动作客户端：它立即 FIN，服务端读到空脚本
# 必报 "No @Action matrix found"。故由发送客户端自己做「连接被拒则重试」，
# accept 到的第一个连接即真正携带脚本的连接。
python3 - <<PYEOF
import socket, time, sys
content = open("scripts/relay-test.mt", "r").read()
data = content.encode()
last = None
for i in range(20):
    s = socket.socket()
    s.settimeout(5)
    try:
        s.connect(("127.0.0.1", ${PORT}))
        break
    except OSError as e:
        last = e
        s.close()
        time.sleep(0.5)
else:
    print(f"   连接服务端失败：{last}", file=sys.stderr)
    sys.exit(1)
s.sendall(data)
s.shutdown(socket.SHUT_WR)
time.sleep(0.5)
s.close()
print(f"   客户端已连接并发送 {len(data)} 字节 relay-test.mt")
PYEOF

echo "[3/3] 等待服务端退出并验证输出"
for i in $(seq 1 "${TIMEOUT}"); do
	if ! kill -0 "$SRV_PID" 2>/dev/null; then break; fi
	sleep 1
done
if kill -0 "$SRV_PID" 2>/dev/null; then
	echo "   ✗ 服务端超时未退出（>${TIMEOUT}s）"
	cat "$SRV_LOG"
	kill "$SRV_PID" 2>/dev/null || true
	exit 1
fi

# F-28：服务端退出码必须为 0（旧实现丢弃退出码，只靠字符串匹配判成败）
SRV_RC=0
wait "$SRV_PID" || SRV_RC=$?
if [ "$SRV_RC" -ne 0 ]; then
	echo "   ✗ 服务端退出码非 0（rc=$SRV_RC）"
	cat "$SRV_LOG"
	exit 1
fi

if grep -q "TCP 客户端已连接" "$SRV_LOG"; then
	echo "   ✓ 服务端成功接受 TCP 连接"
else
	echo "   ✗ 服务端未接受连接"; cat "$SRV_LOG"; exit 1
fi
if grep -qE "Aborted|ERR" "$SRV_LOG"; then
	echo "   ✗ 服务端执行出错"; cat "$SRV_LOG"; exit 1
fi

echo ""
echo "=== TCP 端到端测试通过 ==="
cat "$SRV_LOG"
