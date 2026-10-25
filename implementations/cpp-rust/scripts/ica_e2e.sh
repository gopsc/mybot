#!/usr/bin/env bash
# Offline two-process ICA integration check using the virtual relay and fake model.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# 产物路径可由调用方覆盖（守门分段 run_one_ica_e2e 会把它指向自己认的那份），
# 与 scripts/agent_e2e.sh 的 BOT 同口径。
BOT="${BOT:-build/mybot}"
AGENT_BIN="${AGENT_BIN:-agent/target/release/mybot-agent}"
[ -x "$AGENT_BIN" ] || { echo "缺 $AGENT_BIN（先 bash scripts/build_agent.sh --release）"; exit 1; }
[ -x "$BOT" ] || { echo "缺后端 $BOT（先 cmake --build build）"; exit 1; }
tmp=$(mktemp -d)
backend_pid=''
server_pid=''
cleanup() {
  [[ -n "$backend_pid" ]] && kill "$backend_pid" 2>/dev/null || true
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  [[ -n "$backend_pid" ]] && wait "$backend_pid" 2>/dev/null || true
  [[ -n "$server_pid" ]] && wait "$server_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -m 700 "$tmp/run"
# 会话持久化缺省开启：状态目录隔离到临时目录，别让这段离线校验往真实 ~/.mybot 写历史
# （与 scripts/agent_e2e.sh 同口径，那里也是无条件 export 覆盖外部值）。
export MYBOT_HOME="$tmp/mybot-home"
port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)
python3 scripts/fake_llm_server.py "$port" "$tmp/request.json" ica-flow >"$tmp/server.log" 2>&1 &
server_pid=$!
"$BOT" --robot=robots/relay-test.sql --mcp-backend \
  --mcp-socket "$tmp/run/mcp.sock" --scripts-dir scripts \
  --audit-log "$tmp/backend-audit.jsonl" >"$tmp/backend.log" 2>&1 &
backend_pid=$!
for _ in $(seq 1 100); do
  [[ -S "$tmp/run/mcp.sock" ]] && break
  sleep .1
done
[[ -S "$tmp/run/mcp.sock" ]] || { cat "$tmp/backend.log"; exit 1; }
for _ in $(seq 1 100); do
  if python3 - "$port" <<'PY' >/dev/null 2>&1
import socket, sys
socket.create_connection(('127.0.0.1', int(sys.argv[1])), .1).close()
PY
  then break; fi
  sleep .1
done
BOT4CJ_ICA=1 BOT4CJ_LLM_KEY=e2e-rust-key timeout 60 \
  "$AGENT_BIN" --socket "$tmp/run/mcp.sock" \
  --llm-endpoint "http://127.0.0.1:$port/v1/chat/completions" \
  --llm-model e2e-model --llm-config none \
  --task '检查虚拟继电器并执行一次动作' >"$tmp/out" 2>"$tmp/err" || {
    cat "$tmp/out" "$tmp/err" "$tmp/server.log" "$tmp/backend.log"
    exit 1
  }
python3 - "$tmp/request.json" "$tmp/backend-audit.jsonl" "$tmp/out" <<'PY'
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text())
tools = [m.get('content', '') for m in request.get('messages', []) if m.get('role') == 'tool']
assert len(tools) >= 5, tools
assert '动作未执行' in tools[0], tools[0]
assert '已登记行动候选 F1' in tools[2], tools[2]
assert '行动回执已经到达' in tools[3], tools[3]
assert 'possible_match' in tools[4], tools[4]
audit = pathlib.Path(sys.argv[2]).read_text()
assert audit.count('run_action_script') == 1, audit
assert 'ICA-E2E-完成' in pathlib.Path(sys.argv[3]).read_text()
print('ICA two-process flow passed: denied first action; inspected state; proposed, executed, compared; exactly one backend action.')
PY
