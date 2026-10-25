#!/usr/bin/env bash
# sim_agent_demo.sh —— 轻量方案：起 sim + backend + mybot-agent 三层链路，把 agent
# 的输出实时打到终端，**不改 sim 渲染**（窗口内叠文字要新增字体图集+overlay，是另一档工作量）。
#
# 终端上同时看到两路：
#   * agent 的「说」——stdout 流式叙述。run_task_once 里 out! 逐 delta flush（见
#     agent/src/repl/mod.rs:529），故经 tee 边上屏边落盘；
#   * agent 的「做」——backend 审计日志（--audit-log）每派发一个工具落一行 JSON，
#     后台 tail -F 经格式化器打成「[tool] 名字 ok 耗时」单行。工具轮 stdout 往往静默
#     （模型那轮只发工具调用、正文为空），这一路正好补上「它此刻在干什么」。
#   * 另外 sim 窗口标题自带最近一条动作（CommandBridge::lastLine()），无需本脚本参与。
#
# 为什么合一路不会串行：工具调用轮 agent 正文为空（repl/mod.rs:523 跳过空文本），
# 那段时间只有 [tool] 行；最终叙述轮不再调工具，那段时间只有流式正文。两路天然错开。
#
# 用法：
#   bash scripts/sim_agent_demo.sh                       # 缺省探索任务（读 prompts/sim_obstacle_nav/）
#   PROMPTS_DIR=prompts/other_task bash scripts/sim_agent_demo.sh
#   TASK="朝 +x 方向前进，绕过挡路的障碍" bash scripts/sim_agent_demo.sh
#   LLM_CFG=/path/other.json ROBOT=robots/spider_sim.sql bash scripts/sim_agent_demo.sh
#
# 环境可覆盖：SIM_BIN BOT_BIN AGENT_BIN LLM_CFG ROBOT PROMPTS_DIR TASK MYBOT_SIM_SOCK MYBOT_SIM_CAPTURE_SOCK MYBOT_SIM_SCENE
#   MYBOT_HOME  —— 状态目录（对话历史 + 地图）；缺省 $HOME/.mybot
#   DEMO_RESUME —— =1 时演示**续接**上一次对话（缺省每次 --new-session，避免历史灌上下文烧 token）
# 退出：agent 跑完或 Ctrl-C，自动拆链路、清 socket；日志目录路径退出时打印（保留）。
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

# 状态目录：MYBOT_HOME > $HOME/.mybot。agent 的对话历史与 sim 的地图都落这里，
# 与两侧代码同一条取值链（规则单点：docs/reference.md 的 MYBOT_HOME 行；三处拼法
# 的一致由 test/run_all_selftest.sh 钉住）。首次自动建目录（0700）。
MYBOT_HOME="${MYBOT_HOME:-${HOME:-}/.mybot}"
if [ -z "$MYBOT_HOME" ] || [ "$MYBOT_HOME" = "/.mybot" ]; then
	echo "无 HOME（且未给 MYBOT_HOME），无法定位状态目录" >&2
	exit 1
fi
mkdir -p "$MYBOT_HOME" "$MYBOT_HOME/maps" || exit 1
chmod 700 "$MYBOT_HOME" 2>/dev/null || true
export MYBOT_HOME
LAST_ROBOT="$MYBOT_HOME/last_robot"

SIM_BIN="${SIM_BIN:-$root/sim/build/mybot-sim}"
BOT_BIN="${BOT_BIN:-$root/build/mybot}"
AGENT_BIN="${AGENT_BIN:-$root/agent/target/release/mybot-agent}"
LLM_CFG="${LLM_CFG:-$root/mybot.llm.json}"
# 机器人：命令行/环境 ROBOT > 上次用的（last_robot）> 缺省 spider_sim
if [ -z "${ROBOT:-}" ]; then
	ROBOT="$(cat "$LAST_ROBOT" 2>/dev/null || true)"
fi
ROBOT="${ROBOT:-robots/spider_sim.sql}"
PROMPTS_DIR="${PROMPTS_DIR:-$root/prompts/sim_obstacle_nav}"
# TASK 优先用环境变量；否则按序号拼接 PROMPTS_DIR 下所有 .md 文件
if [ -z "${TASK:-}" ]; then
	TASK="$(cat "$PROMPTS_DIR"/*.md 2>/dev/null)"
	if [ -z "$TASK" ]; then
		echo "提示词目录不存在或为空: $PROMPTS_DIR" >&2
		exit 1
	fi
fi

SIM_SOCK="${MYBOT_SIM_SOCK:-/tmp/mybot-sim.sock}"
CAP_SOCK="${MYBOT_SIM_CAPTURE_SOCK:-/tmp/mybot-sim-capture.sock}"
SENSOR_SOCK="${MYBOT_SIM_SENSOR_SOCK:-/tmp/mybot-sim-sensor.sock}"

# ---- preflight：缺任一要件就如实报错退出，不起半条链路 ----
miss=0
for b in "$SIM_BIN" "$BOT_BIN" "$AGENT_BIN"; do
	[ -x "$b" ] || { echo "缺可执行文件: $b" >&2; miss=1; }
done
[ -f "$LLM_CFG" ] || { echo "缺 LLM 配置: $LLM_CFG（含 endpoint/model/api_key）" >&2; miss=1; }
[ -f "$ROBOT" ] || { echo "缺结构脚本: $ROBOT" >&2; miss=1; }
[ "$miss" -eq 0 ] || exit 1
command -v python3 >/dev/null 2>&1 || { echo "缺 python3（审计格式化器）" >&2; exit 1; }

# preflight 全过：把本次用的结构脚本记进 last_robot（原子写，0600）。单写者是本
# 脚本——agent 与后端都不碰它，下次不带 ROBOT 就续用同一只机器人。
tmp="$LAST_ROBOT.tmp.$$"
if printf '%s\n' "$ROBOT" >"$tmp" 2>/dev/null && chmod 600 "$tmp" 2>/dev/null; then
	mv -f "$tmp" "$LAST_ROBOT" 2>/dev/null || rm -f "$tmp"
else
	rm -f "$tmp"
fi

RUN="$(mktemp -d /tmp/sim-agent-demo.XXXXXX)"
chmod 700 "$RUN"
MCP_SOCK="$RUN/mcp.sock"
BAUD="$RUN/backend-audit.jsonl"
AOUT="$RUN/agent.log"
SIM_LOG="$RUN/sim.log"
BOT_LOG="$RUN/backend.log"

SIM_PID=""; BOT_PID=""; FEED_PID=""
cleanup() {
	trap - EXIT INT TERM
	# FEED_PID 是那个子壳的 PID，而 tail 与 python3 是它的**子进程**：只 kill 子壳，两者会被
	# reparent 到 init 接着跑——每次 demo 泄漏两个进程，且它们握着 stdout 管道不放，脚本早已
	# 退出、读管道的一方却等不到 EOF。故先杀子进程、再杀子壳。
	if [ -n "$FEED_PID" ]; then
		pkill -P "$FEED_PID" 2>/dev/null
		kill "$FEED_PID" 2>/dev/null
	fi
	[ -n "$BOT_PID" ] && kill -TERM "$BOT_PID" 2>/dev/null
	[ -n "$SIM_PID" ] && kill -TERM "$SIM_PID" 2>/dev/null
	[ -n "$BOT_PID" ] && wait "$BOT_PID" 2>/dev/null
	[ -n "$SIM_PID" ] && wait "$SIM_PID" 2>/dev/null
	rm -f "$SIM_SOCK" "$CAP_SOCK" "$SENSOR_SOCK"
	echo
	echo "日志保留在: $RUN"
	echo "  agent 输出(说): $AOUT"
	echo "  工具审计(做):   $BAUD"
	echo "  sim/backend:    $SIM_LOG / $BOT_LOG"
}
trap cleanup EXIT INT TERM

wait_sock() { # $1=socket $2= tries $3=名字 $4=日志
	local _
	for _ in $(seq 1 "$2"); do
		[ -S "$1" ] && return 0
		sleep 0.1
	done
	echo "$3 未就绪（$4 尾部）:" >&2
	tail -5 "$4" 2>/dev/null | sed 's/^/    /' >&2
	return 1
}

# 残留 socket 会让 sim 绑定失败——这三个是 sim 自己的，起前清掉安全。
rm -f "$SIM_SOCK" "$CAP_SOCK" "$SENSOR_SOCK"

echo "=== 1/3 起仿真器 sim（窗口会出现；标题显示最近动作）==="
# 场景：不给 MYBOT_SIM_SCENE 时由 sim 自己的缺省决定（$MYBOT_HOME/maps/default.scene，
# 缺失则从仓库 sim/scenes 播种一份）。agent/人搬动过的环境**退出时自动写回**那份地图
# （sim 捕获本脚本 cleanup 的 SIGTERM 优雅退出并 saveScene；S 键 / save 指令仍可手动
# 写回），下次跑 demo 从改过的环境继续；仓库 sim/scenes/* 从此只读，不再被弄脏。
# 想指定别的布局：MYBOT_SIM_SCENE=my_map（裸名 → maps/my_map.scene）或显式路径。
# 裸名有个**额外的**前提：sim 还要能找到同名模板（编译期 MYBOT_SIM_SCENES_DIR，即源码树
# sim/scenes；未命中回退 exe 相对 ../scenes/）用于首次播种，找不到就打一行「未找到模板 …」
# 并**静默退回内置默认场景**——只在 $MYBOT_HOME/maps/ 放一个 my_map.scene 是不够的。
# 要跑一个不在 sim/scenes 里的布局，传绝对路径（含 / 即绕开模板查找）。
if [ -n "${MYBOT_SIM_SCENE:-}" ]; then
	MYBOT_SIM_SCENE="$MYBOT_SIM_SCENE" "$SIM_BIN" >"$SIM_LOG" 2>&1 &
else
	"$SIM_BIN" >"$SIM_LOG" 2>&1 &
fi
SIM_PID=$!
wait_sock "$SIM_SOCK" 60 "sim 命令桥" "$SIM_LOG" || exit 1

echo "=== 2/3 起后端 mybot --mcp-backend（robot=$ROBOT, 审计=$BAUD）==="
# MYBOT_SIM_CAPTURE_SOCK 让 Camera.lua 从 sim 抓实时帧（capture_image 工具的图源）。
# MYBOT_SIM_SENSOR_SOCK 让 Sim.lua 的 range() 函数从 sim 读测距数据。
MYBOT_SIM_CAPTURE_SOCK="$CAP_SOCK" MYBOT_SIM_SENSOR_SOCK="$SENSOR_SOCK" \
	"$BOT_BIN" --robot="$ROBOT" --mcp-backend \
	--mcp-socket "$MCP_SOCK" --scripts-dir scripts --audit-log "$BAUD" \
	>"$BOT_LOG" 2>&1 &
BOT_PID=$!
wait_sock "$MCP_SOCK" 80 "后端 MCP" "$BOT_LOG" || exit 1

echo "=== 3/3 起 agent（实时输出在下；[tool]=审计逐工具调用，其余=agent 流式正文）==="
# 工具调用实时喂：tail -F 审计 → python 格式化器打成单行。先 touch 免 tail 报无文件。
touch "$BAUD"
(
	tail -n +1 -F "$BAUD" 2>/dev/null | python3 -u -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    k = d.get("kind")
    if k == "tool":
        ok = "ok" if d.get("ok") else "FAIL"
        ms = d.get("ms", "")
        name = d.get("tool", "?")
        extra = d.get("summary") or ""
        extra = (" | " + str(extra)[:80]) if extra else ""
        sys.stdout.write("[tool] %s %s %sms%s\n" % (name, ok, ms, extra))
        sys.stdout.flush()
    elif k == "session":
        sys.stdout.write("[session] %s\n" % d.get("status", ""))
        sys.stdout.flush()
'
) &
FEED_PID=$!

# agent 在前台：stdout(流式叙述)+stderr(就绪行/重试) 合流，经 tee 上屏并落盘。
# 缺省 --new-session：演示是「每次新任务」，把上一次对话灌进上下文既干扰又烧 token。
# 想验证「重启记得上次对话」，用 DEMO_RESUME=1 去掉该开关（stderr 会打印会话落点）。
NEW_SESSION_FLAG="--new-session"
[ "${DEMO_RESUME:-0}" = "1" ] && NEW_SESSION_FLAG=""
BOT4CJ_LLM_KEY="${BOT4CJ_LLM_KEY:-}" "$AGENT_BIN" --socket "$MCP_SOCK" \
	--llm-config "$LLM_CFG" $NEW_SESSION_FLAG --task "$TASK" 2>&1 | tee "$AOUT"
rc=${PIPESTATUS[0]}

echo
if [ "$rc" -eq 0 ]; then
	echo "=== agent 跑完（rc=0）。拆链路中… ==="
else
	echo "=== agent 退出码 $rc（见上方输出与 $BOT_LOG）。拆链路中… ==="
fi
exit "$rc"
