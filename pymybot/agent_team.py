"""Dual-agent autonomous core.

The old single agent mixed two jobs: remembering and acting. This module splits
them into two cooperating agents that talk to each other inside one role:

* the **memory agent** (记忆体) owns long-term memory, planning and reflection.
  It never touches hardware, files, shell or the network.
* the **worker agent** (执行体) owns the tool surface (skills, files, shell,
  web, camera, MCP) but is deliberately blind: it only sees the brief it is
  given plus its own short conversation window.

A bounded loop alternates them — plan, act, reflect, repeat — until the mission
is done, blocked, cancelled or out of budget. ``serve_forever`` drains queued
missions while the operator is away; every automatic continuation is capped by
mission count, steps, wall-clock and tokens.

Events are tagged with ``agent`` (``"memory"``, ``"worker"`` or ``"system"``)
so the GUI and CLI can render both voices.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import threading
import time

from langchain_core.exceptions import ContextOverflowError
from langchain_core.messages import HumanMessage, SystemMessage
from pydantic import ValidationError

from .agent_contracts import GoalProposal, PlanDecision
from .agent_memory_store import MemoryStore, MemoryStoreError
from .agent_telemetry import current_trace_id, span
from .errors import AgentInterrupted
from .security import SecurityError, checked_text

MAX_GOAL = 16 * 1024
MAX_BRIEF = 8 * 1024
MAX_REPORT = 12 * 1024
MAX_MEMORY_TEXT = 2000
MAX_MISSIONS = 200
MAX_MISSION_BYTES = 256 * 1024
MISSION_STATUSES = ("pending", "running", "done", "blocked", "paused", "failed", "cancelled")
ACTIONS = ("continue", "done", "blocked")
MISSION_FORMAT = 1

_SYSTEM = """你是 mybot 双智能体里的「记忆体」（memory agent）。
你负责长期记忆、规划与反思，永远不直接操作硬件、文件、Shell 或网络；那些工作由「执行体」完成。

规则：
1. 只输出一个 JSON 对象，不要 Markdown 代码围栏，不要额外解释。
2. 决定必须具体：给执行体的 brief 要写清目标、约束、验收标准和参考记忆。
3. 执行体回报后先判断是否真的达成目标，再决定 continue / done / blocked。
4. 只有确实需要再动一次手时才 continue；信息不足时让执行体去查，不要凭空假设。
5. 从本轮抽取可复用的长期记忆（事实、决定、偏好、坑），宁少勿滥，每条一句话。
6. 不确定就 blocked，并说明缺什么；不要编造执行结果。

JSON 结构：
{"action":"continue|done|blocked",
 "brief":"给执行体的下一步指令（continue 时必填）",
 "reasoning":"一句话判断依据",
 "summary":"给用户的最终答复（done/blocked 时必填）",
 "memories":[{"text":"一句话事实","kind":"fact|decision|preference|gotcha|summary|task","tags":["标签"],"salience":0.7}],
 "next_goal":"可选：无人值守时建议的下一个目标，没有就留空"}
"""

_PLAN = """任务目标：
{goal}

第 {step} 步，剩余步数 {remaining}。

长期记忆（可能与任务相关）：
{memories}

本次任务已经发生的交互：
{history}

执行体最近一次回报：
{report}

请输出 JSON。若这是第一步，brief 写完整的执行指令；若是继续，brief 只写下一步。"""


_PROPOSE_SYSTEM = """你是 mybot 双智能体里的「记忆体」。现在没有人类输入，你需要自拟下一个任务目标。
规则：
1. 只输出一个 JSON 对象，不要 Markdown 代码围栏。
2. 目标必须具体、可验收、一个任务内能完成；不要重复刚完成或明确失败的目标。
3. 若上一轮状态是 failed 或 blocked，优先提出一个修复目标：换一种做法、先诊断原因，
   或把任务拆小；同样的做法不要重复。修复确实不可行时，改为提出另一个有价值、可执行的
   目标：执行体可以改变环境（安装缺失依赖、编写结构 SQL、维护技能与工作区），
   "环境不会自行变化"不等于无事可做。
4. 目标要让机器人感知或作用于物理世界：用摄像头观察环境、采样传感器、扫描总线、
   驱动执行器，或通过技能执行硬件动作。文件与 shell 只是记录证据、交付结果的手段，
   不是目标本身：不要提出清点目录、生成清单文件、搭建目录骨架、重构无关文件这类
   纯文件任务。
5. 不要发明与当前角色无关的文件或配置；长期记忆由系统自动保存在 memory/ 与
   missions/，不要创建 memory.json 这类重复文件。物理接口不可用时（缺设备、缺依赖、
   无结构 SQL），不要改用文件任务代替，按规则 6 留空 goal，并在 reason 里说明缺什么、
   运维者可以启用什么。
6. 没有值得继续做的事时把 goal 留空，不要为了运行而编造任务。
JSON 结构：{"goal":"下一个任务目标或空串","reason":"一句话依据"}
"""

_PROPOSE = """角色描述：
{role}

长期记忆：
{memories}

上一轮任务：
{last}

请输出 JSON。"""


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _clip(text, limit):
    text = str(text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _failure_detail(exc):
    """Name a failure without echoing provider bodies (they may contain secrets)."""
    name = type(exc).__name__
    status = getattr(exc, "status_code", None)
    if status is None:
        status = getattr(getattr(exc, "response", None), "status_code", None)
    if status is not None:
        return f"{name} (HTTP {status})"
    text = _clip(str(exc).strip(), 300)
    return f"{name}: {text}" if text else name


def _message_text(message):
    content = getattr(message, "content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                parts.append(str(block.get("text", "")))
        return "".join(parts)
    return str(content or "")


def _usage(message):
    usage = getattr(message, "usage_metadata", None)
    if not isinstance(usage, dict):
        return 0, 0
    return int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0)


def parse_goal(text):
    """Parse the memory agent's self-proposed next goal; empty means stop."""
    if not isinstance(text, str):
        return ""
    body = text.strip()
    if body.upper() == "STOP":
        return ""
    if body.startswith("```"):
        body = body.strip("`")
        if body.startswith("json"):
            body = body[4:]
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end <= start:
        return ""
    try:
        data = json.loads(body[start:end + 1])
    except (ValueError, TypeError):
        return ""
    if not isinstance(data, dict):
        return ""
    goal = data.get("goal")
    if not isinstance(goal, str):
        return ""
    goal = goal.strip()
    if goal.casefold() in {"", "stop", "none", "null", "无"}:
        return ""
    return _clip(goal, MAX_GOAL)


def parse_decision(text):
    """Parse the memory agent's JSON, tolerating fences and surrounding prose."""
    if not isinstance(text, str):
        return None
    body = text.strip()
    if body.startswith("```"):
        body = body.strip("`")
        if body.startswith("json"):
            body = body[4:]
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        data = json.loads(body[start:end + 1])
    except (ValueError, TypeError):
        return None
    if not isinstance(data, dict):
        return None
    action = data.get("action")
    if action not in ACTIONS:
        return None
    brief = data.get("brief") if isinstance(data.get("brief"), str) else ""
    summary = data.get("summary") if isinstance(data.get("summary"), str) else ""
    reasoning = data.get("reasoning") if isinstance(data.get("reasoning"), str) else ""
    memories = []
    raw = data.get("memories")
    if isinstance(raw, list):
        for item in raw[:8]:
            if isinstance(item, dict) and isinstance(item.get("text"), str) and item["text"].strip():
                memories.append({
                    "text": _clip(item["text"].strip(), MAX_MEMORY_TEXT),
                    "kind": item.get("kind") if item.get("kind") in
                    ("fact", "decision", "preference", "gotcha", "summary", "task") else "fact",
                    "tags": [str(tag)[:32] for tag in (item.get("tags") or [])[:8]
                             if isinstance(tag, (str, int))],
                    "salience": item.get("salience", 0.6),
                })
    return {"action": action, "brief": _clip(brief, MAX_BRIEF),
            "summary": _clip(summary, MAX_REPORT),
            "reasoning": _clip(reasoning, 1000),
            "memories": memories,
            "next_goal": _clip(data.get("next_goal") or "", MAX_GOAL) or ""}


@dataclass
class Mission:
    id: str
    goal: str
    status: str = "pending"
    created: str = field(default_factory=_now)
    updated: str = field(default_factory=_now)
    steps: list = field(default_factory=list)
    usage: dict = field(default_factory=lambda: {"steps": 0, "attempts": 0, "input_tokens": 0,
                                                 "output_tokens": 0, "seconds": 0.0})
    answer: str = ""
    reason: str = ""
    next_goal: str = ""
    # Durable execution state: a persisted in-flight marker prevents replaying
    # a step whose hardware outcome is unknown after a process restart.
    in_flight: bool = False
    approved: bool | None = None
    lease_owner: str = ""
    lease_until: float = 0.0
    trace_id: str = ""

    def as_dict(self):
        return {"version": MISSION_FORMAT, "id": self.id, "goal": self.goal,
                "status": self.status, "created": self.created, "updated": self.updated,
                "steps": self.steps[-50:], "usage": self.usage, "answer": self.answer,
                "reason": self.reason, "next_goal": self.next_goal,
                "in_flight": self.in_flight, "approved": self.approved,
                "lease_owner": self.lease_owner, "lease_until": self.lease_until,
                "trace_id": self.trace_id}

    @classmethod
    def from_dict(cls, data):
        if not isinstance(data, dict) or not isinstance(data.get("goal"), str):
            raise ValueError("invalid mission")
        mission = cls(id=str(data.get("id") or secrets.token_hex(6))[:32],
                      goal=_clip(data["goal"], MAX_GOAL),
                      status=data.get("status") if data.get("status") in MISSION_STATUSES else "pending")
        mission.created = str(data.get("created") or _now())
        mission.updated = str(data.get("updated") or _now())
        steps = data.get("steps")
        mission.steps = [step for step in steps[-50:] if isinstance(step, dict)] if isinstance(steps, list) else []
        usage = data.get("usage")
        if isinstance(usage, dict):
            mission.usage = {"steps": int(usage.get("steps") or 0),
                             "attempts": int(usage.get("attempts") or 0),
                             "input_tokens": int(usage.get("input_tokens") or 0),
                             "output_tokens": int(usage.get("output_tokens") or 0),
                             "seconds": float(usage.get("seconds") or 0.0)}
        mission.answer = str(data.get("answer") or "")[:MAX_REPORT]
        mission.reason = str(data.get("reason") or "")[:1000]
        mission.next_goal = str(data.get("next_goal") or "")[:MAX_GOAL]
        mission.in_flight = bool(data.get("in_flight"))
        approved = data.get("approved")
        mission.approved = approved if isinstance(approved, bool) else None
        mission.lease_owner = str(data.get("lease_owner") or "")[:64]
        try:
            mission.lease_until = float(data.get("lease_until") or 0.0)
        except (TypeError, ValueError):
            mission.lease_until = 0.0
        mission.trace_id = str(data.get("trace_id") or "")[:32]
        return mission


class MissionStore:
    """Bounded on-disk mission log beside one role."""

    def __init__(self, root, *, limit=MAX_MISSIONS):
        self.root = Path(root)
        self.limit = int(limit)
        self._lock = threading.RLock()
        if self.root.exists() and self.root.is_symlink():
            raise SecurityError("Mission root must not be a symbolic link")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.root, 0o700)
        except OSError:
            pass

    def _path(self, ident):
        return self.root / f"{ident}.json"

    def create(self, goal):
        mission = Mission(id=secrets.token_hex(6), goal=goal)
        self.save(mission)
        return mission

    def save(self, mission):
        data = json.dumps(mission.as_dict(), ensure_ascii=False, allow_nan=False,
                          indent=1).encode("utf-8")
        if len(data) > MAX_MISSION_BYTES:
            mission.steps = mission.steps[-10:]
            data = json.dumps(mission.as_dict(), ensure_ascii=False, allow_nan=False,
                              indent=1).encode("utf-8")
        with self._lock:
            path = self._path(mission.id)
            temporary = self.root / f".{path.name}.{secrets.token_hex(8)}.tmp"
            descriptor = None
            try:
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "wb") as stream:
                    descriptor = None
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                if descriptor is not None:
                    os.close(descriptor)
                try:
                    temporary.unlink()
                except FileNotFoundError:
                    pass
            self._prune()

    def _prune(self):
        files = sorted((item for item in self.root.glob("*.json") if item.is_file()),
                       key=lambda item: item.stat().st_mtime, reverse=True)
        for extra in files[self.limit:]:
            try:
                extra.unlink()
            except OSError:
                pass

    def load(self, ident):
        path = self._path(str(ident))
        if path.is_symlink() or not path.is_file():
            raise SecurityError("Mission file must be a regular file")
        if path.stat().st_size > MAX_MISSION_BYTES:
            raise SecurityError("Mission file exceeds its size limit")
        data = json.loads(path.read_text(encoding="utf-8"))
        return Mission.from_dict(data)

    def list(self, limit=20):
        result = []
        files = sorted((item for item in self.root.glob("*.json") if item.is_file()),
                       key=lambda item: item.stat().st_mtime, reverse=True)
        for path in files[:max(0, int(limit))]:
            try:
                if path.stat().st_size > MAX_MISSION_BYTES:
                    continue
                result.append(Mission.from_dict(json.loads(path.read_text(encoding="utf-8"))))
            except (OSError, ValueError):
                continue
        return result

    def next_pending(self):
        for mission in reversed(self.list(limit=self.limit)):
            if mission.status == "pending":
                return mission
        return None

    def recover(self):
        """Classify work interrupted by a process restart, without replaying it.

        A mission marked ``running`` while ``in_flight`` may already have
        dispatched hardware actions. It becomes ``failed`` so an operator must
        inspect the robot; a mission that died between steps is safely resumable.
        """
        changed = []
        for mission in self.list(limit=self.limit):
            if mission.status != "running":
                continue
            mission.in_flight = bool(mission.in_flight)
            if mission.in_flight:
                mission.status = "failed"
                mission.reason = "process restarted after dispatch; outcome unknown"
                mission.answer = ""
            else:
                mission.status = "paused"
                mission.reason = "process restarted before the next step"
            mission.updated = _now()
            mission.lease_owner = ""
            mission.lease_until = 0.0
            self.save(mission)
            changed.append(mission.as_dict())
        return changed

    def next_resumable(self):
        for mission in reversed(self.list(limit=self.limit)):
            if mission.status == "paused" and not mission.in_flight:
                return mission
        return None

    def claim_next(self, owner, *, lease_seconds=3600):
        """Atomically claim the oldest pending/resumable mission for one worker.

        The process is single-role and single-owner today, but the lease fields
        make the queue durable and ready for a future multi-process worker.
        """
        owner = str(owner or "worker")[:64]
        with self._lock:
            for mission in reversed(self.list(limit=self.limit)):
                if mission.status not in {"pending", "paused"} or mission.in_flight:
                    continue
                if mission.status == "paused" and mission.lease_until > time.time():
                    continue
                mission.status = "running"
                mission.lease_owner = owner
                mission.lease_until = time.time() + max(1.0, float(lease_seconds))
                mission.updated = _now()
                self.save(mission)
                return mission
        return None

    def release(self, mission, *, status=None, reason=""):
        mission.lease_owner = ""
        mission.lease_until = 0.0
        if status:
            mission.status = status
            mission.reason = _clip(reason or mission.reason, 1000)
        mission.updated = _now()
        self.save(mission)
        return mission


class MemoryAgent:
    """Planning/reflection half: one model call per decision, no tools.

    Provider-native structured output is attempted first. If the model or the
    installed integration cannot produce a validated object, the same prompt is
    retried once with the schema error, then the documented free-text JSON
    parser is used. A malformed response never becomes a tool call. An endpoint
    that rejects the structured request itself with HTTP 400 (some
    OpenAI-compatible servers refuse the response_format/tool_choice shape)
    drops schema binding once per session and uses the text parser.
    """

    def __init__(self, model, *, timeout=60.0, structured=True):
        self.model = model
        self.timeout = float(timeout)
        self.structured = structured
        self._plan_runnable = self._make_runnable(PlanDecision)
        self._goal_runnable = self._make_runnable(GoalProposal)

    def _make_runnable(self, schema):
        factory = getattr(self.model, "with_structured_output", None)
        # Scripted/test models inherit the mixin but do not have a provider
        # model name; attempting schema binding there corrupts their tool list.
        if not callable(factory) or not self.structured or not hasattr(self.model, "model_name"):
            return None
        try:
            return factory(schema, include_raw=True)
        except TypeError:
            try:
                return factory(schema)
            except Exception:
                return None
        except Exception:
            return None

    async def _invoke(self, messages, runnable, parser):
        """Try schema-constrained output, repair once, then fall back to text."""
        if runnable is not None:
            try:
                return await self._invoke_structured(messages, runnable, parser)
            except Exception as exc:
                if not self._downgradable(exc):
                    raise
                self._plan_runnable = None
                self._goal_runnable = None
        message = await asyncio.wait_for(
            self.model.ainvoke(list(messages)), timeout=self.timeout)
        return parser(_message_text(message)), message

    @staticmethod
    def _downgradable(exc):
        """A 400 rejects the structured request shape, not the task; a context
        overflow is a hard limit no request shape can fix."""
        if isinstance(exc, ContextOverflowError):
            return False
        return getattr(exc, "status_code", None) == 400

    async def _invoke_structured(self, messages, runnable, parser):
        current = list(messages)
        for attempt in range(2):
            try:
                result = await asyncio.wait_for(runnable.ainvoke(current), timeout=self.timeout)
            except asyncio.TimeoutError:
                raise
            except (ValueError, ValidationError, NameError) as exc:
                # A 200 response with an unparsable/unsupported structured
                # payload is a parser failure and gets one repair attempt.
                # NameError covers LangChain integrations that fail to
                # resolve their own annotations on newer Python versions.
                error = type(exc).__name__
            except Exception:
                # Provider/transport failures are not parser failures. Do
                # not turn them into hidden extra model requests; the
                # configured provider retry setting owns that policy.
                raise
            else:
                raw = result.get("raw") if isinstance(result, dict) else None
                parsed = result.get("parsed") if isinstance(result, dict) else result
                error = result.get("parsing_error") if isinstance(result, dict) else None
                if parsed is not None and not error:
                    data = parsed.model_dump() if hasattr(parsed, "model_dump") else parsed
                    return parser(json.dumps(data, ensure_ascii=False)), raw
                error = error or "schema validation failed"
            if attempt == 0:
                current = [*messages, HumanMessage(
                    "The previous answer failed schema validation: "
                    f"{_clip(str(error), 300)}. Return only one JSON object matching the schema.")]
        # Structured output is unusable; one plain call remains the fallback.
        message = await asyncio.wait_for(
            self.model.ainvoke(list(messages)), timeout=self.timeout)
        return parser(_message_text(message)), message

    async def decide(self, *, goal, step, remaining, memories, report, history=()):
        lines = []
        for item in history[-4:]:
            lines.append(f"- 第{item.get('step', '?')}步 指令: {_clip(item.get('brief', ''), 200)}")
            lines.append(f"  回报: {_clip(item.get('report', ''), 300)}")
        prompt = _PLAN.format(goal=_clip(goal, MAX_GOAL), step=step, remaining=remaining,
                              memories=MemoryStore.render(memories) or "（无）",
                              history="\n".join(lines) or "（尚无）",
                              report=_clip(report, MAX_REPORT) or "（尚无回报）")
        decision, message = await self._invoke(
            [SystemMessage(_SYSTEM), HumanMessage(prompt)], self._plan_runnable, parse_decision)
        return decision, message

    async def propose(self, *, role="", memories=(), last=None):
        last_text = "（尚未运行过任务）"
        if last is not None:
            last_text = f"目标: {last.goal}\n状态: {last.status}\n结论: {last.answer or last.reason}"
        prompt = _PROPOSE.format(role=_clip(role, 2000) or "（未提供）",
                                 memories=MemoryStore.render(memories) or "（无）",
                                 last=_clip(last_text, 2000))
        goal, message = await self._invoke(
            [SystemMessage(_PROPOSE_SYSTEM), HumanMessage(prompt)], self._goal_runnable, parse_goal)
        return goal, message


class TeamSession:
    """Memory agent + worker agent + bounded autonomous loop."""

    is_team = True

    def __init__(self, worker, model, *, role=None, memory_store=None, mission_store=None,
                 on_event=None, max_steps=8, max_seconds=1800.0, max_tokens=400_000,
                 tick=0.0, confirm=None, require_plan_approval=False, structured=True):
        self.worker = worker
        self.model = model
        self.role = role if role is not None else getattr(worker, "role", None)
        if self.role is not None:
            root = Path(self.role.root)
        else:
            from .roles import roles_root
            root = roles_root().parent
        self.store = memory_store or MemoryStore(root / "memory")
        self.missions = mission_store or MissionStore(root / "missions")
        self.memory = MemoryAgent(model, structured=structured)
        self.confirm = confirm
        self.require_plan_approval = bool(require_plan_approval)
        self.max_steps = max(1, int(max_steps))
        self.max_seconds = max(1.0, float(max_seconds))
        self.max_tokens = max(1024, int(max_tokens))
        self.tick = max(0.0, float(tick))
        self._on_event = None
        self.on_event = on_event
        self._stop = threading.Event()
        self._running: Mission | None = None
        self._lock = threading.Lock()
        self._auto_task = None
        self._auto_state = "idle"
        self._pause_seconds = 1.0
        self._auto_error = ""
        self.last_mission: Mission | None = None

    # -- worker proxies (serve/GUI keep working) ---------------------------
    @property
    def executor(self):
        return self.worker.executor

    @property
    def events(self):
        return self.worker.events

    @property
    def prompt_version(self):
        return self.worker.prompt_version

    @property
    def on_event(self):
        return self._on_event

    @on_event.setter
    def on_event(self, callback):
        self._on_event = callback
        if callback is None:
            self.worker.on_event = None
            return
        self.worker.on_event = lambda event: callback({**event, "agent": "worker"})

    def _emit(self, event):
        if self._on_event is not None:
            trace_id = current_trace_id()
            if trace_id:
                event = {**event, "trace_id": trace_id}
            self._on_event(event)

    def _speak(self, agent, text):
        text = _clip(str(text or "").strip(), MAX_BRIEF)
        if not text:
            return
        self._emit({"type": "team.message", "agent": agent, "text": text})

    def _check(self):
        stop_event = getattr(self.worker.executor, "stop_event", None)
        if self._stop.is_set() or (stop_event is not None and stop_event.is_set()):
            raise AgentInterrupted("Mission stopped by the operator")

    async def start(self):
        await self.worker.start()

    def clear_history(self):
        self.worker.clear_history()

    async def close(self):
        self._stop.set()
        if self._auto_task is not None:
            self._auto_task.cancel()
            try:
                await self._auto_task
            except (asyncio.CancelledError, Exception):
                pass
            self._auto_task = None
        await self.worker.close()

    def cancel(self):
        self._stop.set()
        self.worker.executor.cancel()

    stop = cancel

    def _reset_stop(self):
        self._stop = threading.Event()
        reset = getattr(self.worker.executor, "reset_stop", None)
        if callable(reset):
            reset()

    # -- public entry ------------------------------------------------------
    async def ask(self, goal):
        """Run one mission to completion; used by ``agent.ask`` and CLI seeds."""
        checked_text(goal, MAX_GOAL)
        if not goal.strip():
            raise ValueError("Task must not be empty")
        with self._lock:
            if self._running is not None:
                raise RuntimeError("Another mission is running in this role")
        self._reset_stop()
        return await self.run_mission(self.missions.create(goal.strip()))

    def _recall(self, goal):
        try:
            memories = self.store.search(goal, k=8)
        except (MemoryStoreError, OSError):
            memories = []
        if memories:
            self._speak("memory", f"召回 {len(memories)} 条长期记忆")
        return memories

    def memory_review(self, limit=50, *, kinds=None, tags=None):
        return {"entries": self.store.review(limit, kinds=kinds, tags=tags),
                "stats": self.store.stats()}

    def forget_memory(self, ids=None, *, kinds=None, tags=None):
        removed = self.store.forget(ids, kinds=kinds, tags=tags)
        self._emit({"type": "memory.forget", "agent": "system", "count": len(removed)})
        return {"removed": removed, "count": len(removed)}

    def mission_review(self, limit=20):
        return {"missions": [item.as_dict() for item in self.missions.list(limit=limit)]}

    async def submit(self, goal):
        """Queue a mission for the unattended loop."""
        checked_text(goal, MAX_GOAL)
        mission = self.missions.create(goal.strip())
        self._emit({"type": "mission.queued", "agent": "system", "mission": mission.id})
        return mission.as_dict()

    async def _approve_plan(self, mission, source):
        """Approve one mission goal before the worker can dispatch anything."""
        if not self.require_plan_approval or mission.approved is True:
            return True
        self._emit({"type": "plan.request", "agent": "system", "mission": mission.id,
                    "goal": mission.goal, "source": source})
        reply = await self.confirm("plan:approve", {
            "mission": mission.id, "goal": mission.goal, "source": source}) if self.confirm else False
        approved = (isinstance(reply, dict) and reply.get("approved") is True) or reply is True
        self._emit({"type": "plan.result", "agent": "system", "mission": mission.id,
                    "approved": bool(approved)})
        return bool(approved)

    async def run_mission(self, mission, *, source="operator"):
        with self._lock:
            if self._running is not None:
                raise RuntimeError("Another mission is running in this role")
            self._running = mission
        if mission.in_flight:
            mission.status = "failed"
            mission.reason = "in-flight step has an unknown outcome; inspect before retrying"
            mission.updated = _now()
            self.missions.save(mission)
            with self._lock:
                self._running = None
            return {"output": "", "status": mission.status, "mission": mission.id,
                    "steps": mission.usage["steps"], "usage": dict(mission.usage),
                    "reason": mission.reason, "next_goal": mission.next_goal,
                    "intent": None, "agents": ["memory", "worker"]}
        mission.status = "running"
        mission.lease_owner = mission.lease_owner or "team"
        mission.lease_until = time.time() + max(1.0, self.max_seconds)
        mission.trace_id = current_trace_id() or mission.trace_id
        mission.updated = _now()
        self.missions.save(mission)
        self._emit({"type": "mission.start", "agent": "system", "mission": mission.id,
                    "goal": mission.goal, "resumed": mission.usage["steps"] > 0,
                    "trace_id": mission.trace_id or None})
        started = time.monotonic()
        start_step = mission.usage["steps"] + 1
        report = _clip(str((mission.steps[-1] or {}).get("report") or ""), MAX_REPORT) if mission.steps else ""
        history = [{"step": item.get("step"), "brief": item.get("brief"), "report": item.get("report")}
                   for item in mission.steps[-4:] if isinstance(item, dict)]
        answer = mission.answer
        reason = ""
        with span("agent.mission", mission_id=mission.id, goal=_clip(mission.goal, 200),
                  resumed=start_step > 1, source=source):
            try:
                approved = await self._approve_plan(mission, source)
                mission.approved = bool(approved)
                self.missions.save(mission)
                if not approved:
                    mission.status, reason = "blocked", "operator denied the mission plan"
                    answer = reason
                    self._speak("memory", reason)
                else:
                    memories = self._recall(mission.goal)
                    for step in range(start_step, self.max_steps + 1):
                        self._check()
                        elapsed = time.monotonic() - started
                        if elapsed > self.max_seconds:
                            mission.status, reason = "paused", "mission time budget exhausted"
                            break
                        if mission.usage["input_tokens"] + mission.usage["output_tokens"] > self.max_tokens:
                            # Token usage is cumulative, so a resume can never
                            # make progress; blocked removes the mission from
                            # the claim pool instead of hot-spinning the loop.
                            mission.status, reason = "blocked", (
                                "mission token budget exhausted; "
                                "raise missionTokens or split the goal")
                            answer = reason
                            self._speak("memory", reason)
                            break
                        decision, message = await self._decide(mission, step, memories, report, history)
                        input_tokens, output_tokens = _usage(message)
                        mission.usage["input_tokens"] += input_tokens
                        mission.usage["output_tokens"] += output_tokens
                        action = decision["action"]
                        self._remember(decision["memories"], mission, step)
                        if action == "blocked":
                            mission.status, reason = "blocked", decision["reasoning"] or "memory agent blocked"
                            answer = decision["summary"] or reason
                            self._speak("memory", f"受阻：{answer}")
                            break
                        if action == "done":
                            mission.status = "done"
                            answer = decision["summary"] or report
                            mission.next_goal = decision["next_goal"]
                            self._speak("memory", answer)
                            break
                        brief = decision["brief"] or mission.goal
                        self._speak("memory", brief)
                        self._emit({"type": "team.step", "agent": "system", "step": step,
                                    "remaining": self.max_steps - step})
                        self._check()
                        # Persist before dispatch: a crash after this point is
                        # reported as an unknown outcome and never replayed.
                        mission.usage["attempts"] += 1
                        mission.in_flight = True
                        self.missions.save(mission)
                        result = await self.worker.ask(brief, intent_mode="off")
                        mission.in_flight = False
                        report = _clip(str(result.get("output") or ""), MAX_REPORT)
                        self._speak("worker", report)
                        history.append({"step": step, "brief": brief, "report": report})
                        usage = result.get("usage") or {}
                        mission.usage["input_tokens"] += int(usage.get("input_tokens") or 0)
                        mission.usage["output_tokens"] += int(usage.get("output_tokens") or 0)
                        mission.steps.append({"step": step, "brief": brief, "report": report,
                                              "action": action, "completed": True})
                        mission.usage["steps"] += 1
                        mission.updated = _now()
                        self.missions.save(mission)
                    else:
                        # Steps are cumulative across resumes (start_step picks
                        # up where the last attempt stopped), so an exhausted
                        # step budget can never advance either.
                        mission.status, reason = "blocked", f"step budget exhausted ({self.max_steps})"
                    if mission.status == "running":
                        mission.status = "done"
            except AgentInterrupted:
                mission.status, reason = "cancelled", "stopped by operator"
                raise
            except asyncio.CancelledError:
                mission.status, reason = "cancelled", "cancelled"
                raise
            except BaseException as exc:
                mission.status, reason = "failed", _failure_detail(exc)
                self._speak("worker", f"执行体未能完成任务：{reason}")
                self._emit({"type": "mission.error", "agent": "system", "mission": mission.id,
                            "reason": reason})
                raise
            finally:
                mission.updated = _now()
                mission.usage["seconds"] = round(time.monotonic() - started, 3)
                mission.lease_owner = ""
                mission.lease_until = 0.0
                if mission.status == "done" and not mission.answer:
                    mission.answer = _clip(answer or report, MAX_REPORT)
                mission.reason = _clip(reason or mission.reason, 1000)
                self.missions.save(mission)
                self.last_mission = mission
                self._emit({"type": "mission.end", "agent": "system", "mission": mission.id,
                            "status": mission.status, "usage": mission.usage,
                            "answer": mission.answer, "reason": mission.reason,
                            "trace_id": mission.trace_id or None})
                with self._lock:
                    self._running = None
        return {"output": mission.answer or answer, "status": mission.status,
                "mission": mission.id, "steps": mission.usage["steps"],
                "usage": dict(mission.usage), "reason": mission.reason,
                "next_goal": mission.next_goal, "intent": None,
                "approved": mission.approved, "agents": ["memory", "worker"],
                "trace_id": mission.trace_id or None}

    async def _decide(self, mission, step, memories, report, history=()):
        remaining = self.max_steps - step
        self._emit({"type": "team.thinking", "agent": "memory", "step": step})
        decision, message = await self.memory.decide(
            goal=mission.goal, step=step, remaining=remaining,
            memories=memories, report=report, history=history)
        if decision is None:
            self._speak("memory", "记忆体输出不是合法 JSON，改用确定性回退")
            return self._fallback(step, report), message
        return decision, message

    def _fallback(self, step, report):
        if step >= self.max_steps:
            return {"action": "done", "brief": "", "reasoning": "fallback: step budget reached",
                    "summary": report, "memories": [], "next_goal": ""}
        if not report:
            return {"action": "continue", "brief": "先检查当前环境与可用能力，再给出下一步。",
                    "reasoning": "fallback: first step", "summary": "", "memories": [],
                    "next_goal": ""}
        return {"action": "done", "brief": "", "reasoning": "fallback: no decision JSON",
                "summary": report, "memories": [], "next_goal": ""}

    def _remember(self, memories, mission, step):
        mission_id = mission.id if mission is not None else ""
        for item in memories or ():
            try:
                self.store.append(item["text"], kind=item.get("kind", "fact"),
                                  tags=item.get("tags") or (), salience=item.get("salience", 0.6),
                                  mission=mission_id, step=step)
            except (MemoryStoreError, OSError):
                continue

    # -- unattended mode ---------------------------------------------------
    async def auto_start(self, *goals, max_missions=20, max_seconds=6 * 3600, pause=1.0):
        """Run the autonomous dialogue: seeds, queued missions, then self-proposals."""
        self._reset_stop()
        if self._auto_task is not None and not self._auto_task.done():
            raise RuntimeError("Unattended loop is already running")
        self._pause_seconds = max(0.0, float(pause))
        # Reclassify work interrupted by a previous process before claiming it.
        self.missions.recover()
        for goal in goals:
            if isinstance(goal, str) and goal.strip():
                await self.submit(goal)
        self._auto_state = "running"
        self._auto_task = asyncio.create_task(
            self._auto_loop(int(max_missions), float(max_seconds)),
            name="mybot-auto")

    async def _auto_loop(self, max_missions, max_seconds):
        started = time.monotonic()
        completed = 0
        try:
            while not self._stop.is_set():
                if completed >= max_missions:
                    self._auto_state = f"stopped: mission cap {max_missions} reached"
                    return
                if time.monotonic() - started > max_seconds:
                    self._auto_state = "stopped: time cap reached"
                    return
                mission = self.missions.claim_next(f"auto-{os.getpid()}", lease_seconds=self.max_seconds)
                if mission is None:
                    # No human input: the memory agent chooses the next objective.
                    self._auto_state = "thinking"
                    mission = await self._propose_mission()
                    if mission is not None:
                        mission = self.missions.claim_next(
                            f"auto-{os.getpid()}", lease_seconds=self.max_seconds) or mission
                    if mission is None:
                        # Keep a concrete proposal error; only a clean empty
                        # proposal means there is nothing left to do.
                        if self._auto_state == "thinking":
                            self._auto_state = "stopped: memory agent proposed no further goal"
                        return
                self._auto_state = "running"
                try:
                    result = await self.run_mission(mission, source="auto")
                except AgentInterrupted:
                    break
                except Exception:
                    completed += 1
                    continue
                completed += 1
                self._emit({"type": "team.mission", "agent": "system",
                            "status": result.get("status"), "mission": result.get("mission")})
                if self._stop.is_set():
                    break
                # A finished mission may propose the next one; queue it only
                # while the automatic budget still has room.
                nxt = (result or {}).get("next_goal") or ""
                if nxt.strip() and isinstance(nxt, str) and len(nxt) <= MAX_GOAL:
                    await self.submit(nxt)
                if self._pause_seconds:
                    if await self._sleep(self._pause_seconds):
                        break
        except asyncio.CancelledError:
            self._auto_state = "stopped"
            raise
        finally:
            if self._auto_state.startswith("running") or self._auto_state in {"idle", "thinking"}:
                self._auto_state = "stopped"
            self._emit({"type": "team.stopped", "agent": "system", "state": self._auto_state})

    async def _propose_mission(self):
        """Ask the memory agent for the next concrete goal; None means stop."""
        role = self.role.description if self.role is not None else ""
        last = self.last_mission
        query = " ".join(part for part in (role, last.answer if last is not None else "") if part)
        memories = self._recall(query.strip()) if query.strip() else []
        self._emit({"type": "team.thinking", "agent": "memory", "step": 0})
        goal = ""
        try:
            goal, _message = await self.memory.propose(role=role, memories=memories, last=last)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            detail = _failure_detail(exc)
            self._auto_state = f"stopped: memory proposal failed: {detail}"
            self._speak("memory", f"自拟目标失败：{detail}")
            return None
        if not goal and last is None:
            # A fresh start must do something: a bounded, read-only bootstrap.
            goal = "检查当前环境与可用能力，并把机器人状态写入长期记忆。"
        if not goal:
            if last is not None and last.status in {"failed", "blocked"}:
                self._speak("memory",
                            f"上一轮 {last.status}，未提出修复目标："
                            f"{_clip(last.reason or last.answer or '原因未知', 200)}")
            return None
        self._speak("memory", f"下一个目标：{goal}")
        self._emit({"type": "team.propose", "agent": "memory", "goal": goal})
        return self.missions.create(goal)

    async def _sleep(self, seconds):
        deadline = time.monotonic() + max(0.0, seconds)
        while time.monotonic() < deadline:
            if self._stop.is_set():
                return True
            await asyncio.sleep(min(1.0, max(0.05, deadline - time.monotonic())))
        return self._stop.is_set()

    async def auto_stop(self):
        self._stop.set()
        task = self._auto_task
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._auto_task = None
        self._auto_state = "stopped"
        return self.auto_status()

    def auto_status(self):
        task = self._auto_task
        try:
            memory = self.store.stats()
        except (MemoryStoreError, OSError):
            memory = None
        return {"state": self._auto_state,
                "running": bool(task is not None and not task.done()),
                "mission": self._running.id if self._running is not None else None,
                "memory": memory}
