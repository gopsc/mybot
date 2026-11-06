"""Long-term memory and dual-agent team tests; no network, no hardware."""
import asyncio
import json
import os
import threading
import time

import pytest

pytest.importorskip("langchain")

from agent_fakes import FunctionModel, ModelResponse, TextPart

from pymybot.agent_contracts import PlanDecision
from pymybot import agent_team
from pymybot.agent_memory_store import (MemoryStore, MemoryStoreError, tokenize)
from pymybot.agent_team import MemoryAgent, Mission, MissionStore, TeamSession, parse_decision


def memory_model(*decisions):
    """A FunctionModel that returns each JSON decision in order."""
    queue = list(decisions)

    def respond(messages, info):
        if not queue:
            raise AssertionError("memory model exhausted")
        value = queue.pop(0)
        text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
        return ModelResponse(parts=[TextPart(text)])

    return FunctionModel(respond)


class FakeExecutor:
    def __init__(self):
        self.stop_event = threading.Event()
        self.cancelled = False
        self.reset_calls = 0

    def cancel(self):
        self.cancelled = True
        self.stop_event.set()

    def reset_stop(self):
        self.reset_calls += 1
        self.stop_event.clear()


class FakeWorker:
    """Minimal worker surface the team relies on."""

    def __init__(self, outputs=("ok",), delay=0.0):
        self.outputs = list(outputs)
        self.delay = delay
        self.asks = []
        self.events = []
        self.on_event = None
        self.role = None
        self.executor = FakeExecutor()
        self.closed = False
        self.history_cleared = False

    async def ask(self, text, *, intent_mode=None):
        if self.delay:
            await asyncio.sleep(self.delay)
        self.asks.append((text, intent_mode))
        if not self.outputs:
            raise RuntimeError("worker exhausted")
        return {"output": self.outputs.pop(0),
                "usage": {"input_tokens": 10, "output_tokens": 5, "requests": 1,
                          "tool_calls": 0}}

    async def start(self):
        return {"robot": "test"}

    async def close(self):
        self.closed = True

    def clear_history(self):
        self.history_cleared = True


# -- memory store ---------------------------------------------------------

def test_tokenize_mixes_ascii_and_cjk():
    tokens = tokenize("BME280 温度 0x76")
    assert "bme280" in tokens and "0x76" in tokens
    assert "温度" in tokens


def test_memory_review_filters_and_forget(tmp_path):
    store = MemoryStore(tmp_path / "memory")
    gotcha = store.append("继电器上电会抖一下", kind="gotcha", tags=["relay"])
    preference = store.append("用户偏好中文", kind="preference", tags=["user"])
    reviewed = store.review(limit=10, kinds=["gotcha"])
    assert [item["id"] for item in reviewed] == [gotcha.id]
    removed = store.forget(tags=["relay"])
    assert [item["id"] for item in removed] == [gotcha.id]
    remaining = store.search("用户", k=2)
    assert remaining and remaining[0].id == preference.id


def test_mission_recovery_does_not_replay_in_flight_work(tmp_path):
    store = MissionStore(tmp_path / "missions")
    mission = store.create("巡检")
    mission.status = "running"
    mission.in_flight = True
    store.save(mission)
    recovered = store.recover()
    assert recovered[0]["status"] == "failed"
    assert "unknown" in recovered[0]["reason"]
    assert store.next_resumable() is None


def test_mission_claim_lease_and_release(tmp_path):
    store = MissionStore(tmp_path / "missions")
    mission = store.create("排队任务")
    claimed = store.claim_next("worker-1", lease_seconds=60)
    assert claimed is not None and claimed.status == "running"
    assert claimed.lease_owner == "worker-1"
    assert store.claim_next("worker-2") is None
    store.release(claimed, status="done")
    assert store.load(mission.id).lease_owner == ""


def test_team_resumes_paused_mission_from_next_step(tmp_path):
    missions = MissionStore(tmp_path / "missions")
    mission = missions.create("继续巡检")
    mission.status = "paused"
    mission.usage["steps"] = 1
    mission.steps = [{"step": 1, "brief": "检查", "report": "已检查", "completed": True}]
    missions.save(mission)
    worker = FakeWorker()
    team = TeamSession(worker, memory_model({"action": "done", "summary": "完成"}),
                       mission_store=missions, memory_store=MemoryStore(tmp_path / "memory"))
    result = asyncio.run(team.run_mission(missions.load(mission.id), source="auto"))
    assert result["status"] == "done" and result["output"] == "完成"
    assert worker.asks == []  # the next planning step said done


def test_team_plan_approval_denies_without_worker(tmp_path):
    reply = {"approved": False}

    async def confirm(name, arguments):
        assert name == "plan:approve"
        return reply

    worker = FakeWorker()
    team = TeamSession(worker, memory_model(), role=None, confirm=confirm,
                       require_plan_approval=True)
    result = asyncio.run(team.ask("检查继电器"))
    assert result["status"] == "blocked"
    assert result["approved"] is False
    assert worker.asks == []


def test_team_reset_stop_clears_executor_event():
    worker = FakeWorker()
    team = TeamSession(worker, memory_model(), role=None)
    team.cancel()
    assert worker.executor.stop_event.is_set()
    team._reset_stop()
    assert not worker.executor.stop_event.is_set()
    assert worker.executor.reset_calls == 1


class StructuredMemoryModel:
    model_name = "structured-test"

    def with_structured_output(self, schema, include_raw=True):
        class Runnable:
            async def ainvoke(inner, messages):
                return {"parsed": PlanDecision(action="done", summary="完成"),
                        "raw": None, "parsing_error": None}
        return Runnable()


def test_memory_agent_prefers_structured_output():
    agent = MemoryAgent(StructuredMemoryModel())
    decision, _ = asyncio.run(agent.decide(goal="检查", step=1, remaining=3, memories=[], report=""))
    assert decision["action"] == "done" and decision["summary"] == "完成"


def test_memory_append_search_and_reload(tmp_path):
    store = MemoryStore(tmp_path / "memory")
    first = store.append("BME280 在 I2C-1 0x76，温度偏高是过采样设置",
                         kind="gotcha", tags=["bme280"], salience=0.8)
    store.append("用户偏好中文回复", kind="preference", tags=["user"], salience=0.9)
    hits = store.search("BME280 温度", k=2)
    assert hits and hits[0].id == first.id
    reopened = MemoryStore(tmp_path / "memory")
    assert reopened.stats()["entries"] == 2
    assert reopened.search("温度")[0].text.startswith("BME280")


def test_memory_duplicate_reinforces_instead_of_repeating(tmp_path):
    store = MemoryStore(tmp_path / "memory")
    first = store.append("继电器 relay0 对应控制器 timer-0", kind="fact", salience=0.5)
    second = store.append("继电器 relay0 对应控制器 timer-0", kind="fact", salience=0.7)
    assert first.id == second.id
    assert second.salience > 0.7
    assert store.stats()["entries"] == 1


def test_memory_rejects_bad_input(tmp_path):
    store = MemoryStore(tmp_path / "memory")
    with pytest.raises(MemoryStoreError):
        store.append("   ")
    with pytest.raises(MemoryStoreError):
        store.append("x" * 5000)
    with pytest.raises(MemoryStoreError):
        store.append("ok", kind="nonsense")


def test_memory_is_bounded_and_compacts(tmp_path):
    store = MemoryStore(tmp_path / "memory", max_entries=3)
    for index in range(6):
        store.append(f"事实 {index}", salience=index / 10)
    assert store.stats()["entries"] == 3
    assert len(MemoryStore(tmp_path / "memory", max_entries=3).stats()["kinds"]) >= 1


def test_memory_root_rejects_symlink(tmp_path):
    target = tmp_path / "elsewhere"
    target.mkdir()
    link = tmp_path / "memory"
    try:
        link.symlink_to(target, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unavailable")
    with pytest.raises(MemoryStoreError):
        MemoryStore(link)


def test_memory_render_is_bounded(tmp_path):
    store = MemoryStore(tmp_path / "memory")
    store.append("a" * 100, kind="fact")
    rendered = store.render(store.search("a", k=1))
    assert rendered.startswith("- [fact")


# -- decision parsing -----------------------------------------------------

def test_parse_decision_accepts_fences_and_prose():
    decision = parse_decision('prefix ```json\n{"action":"done","summary":"好了"}\n``` suffix')
    assert decision["action"] == "done" and decision["summary"] == "好了"


def test_parse_decision_rejects_invalid():
    assert parse_decision("no json here") is None
    assert parse_decision('{"action":"explode"}') is None
    assert parse_decision('{"action":"continue","brief":"go"}')["action"] == "continue"


def test_auto_loop_proposes_its_own_first_goal(tmp_path):
    """Clicking start with no human input: the memory agent picks the mission."""
    worker = FakeWorker(["巡检完成"])
    model = memory_model(
        {"goal": "巡检继电器", "reason": "刚启动，先做只读巡检"},
        {"action": "continue", "brief": "执行继电器巡检", "reasoning": "先看状态"},
        {"action": "done", "summary": "巡检完成"},
    )
    team = TeamSession(worker, model, memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=MissionStore(tmp_path / "missions"), max_steps=4)

    async def scenario():
        await team.auto_start(max_missions=1, pause=0)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not team.auto_status()["running"]:
                break
            await asyncio.sleep(0.02)
        status = team.auto_status()
        await team.close()
        return status

    status = asyncio.run(scenario())
    assert "cap" in status["state"]
    assert worker.asks[0][0] == "执行继电器巡检"
    goals = [json.loads(path.read_text(encoding="utf-8"))["goal"]
             for path in (tmp_path / "missions").glob("*.json")]
    assert goals == ["巡检继电器"]


def test_propose_prompt_prefers_physical_goals_over_filesystem_work():
    """Goal steering belongs to the memory agent, which never sees 010_core.md.

    Its prompt used to offer 工作区维护 as one of four goal categories and never
    mentioned sensing, so an unattended run with an empty role description picked
    the cheapest verifiable goal: inventorying the workspace and writing reports.
    """
    text = agent_team._PROPOSE_SYSTEM
    assert "工作区维护" not in text
    assert "物理世界" in text
    assert "清点目录" in text
    assert "不要改用文件任务" in text


# -- mission store --------------------------------------------------------

def test_mission_roundtrip_and_next_pending(tmp_path):
    store = MissionStore(tmp_path / "missions")
    mission = store.create("检查继电器")
    assert MissionStore(tmp_path / "missions").load(mission.id).goal == "检查继电器"
    pending = store.next_pending()
    assert pending is not None and pending.id == mission.id
    mission.status = "done"
    store.save(mission)
    assert store.next_pending() is None


# -- team loop ------------------------------------------------------------

def test_team_runs_plan_act_reflect_and_remembers(tmp_path):
    worker = FakeWorker(["relay0 自检通过"])
    model = memory_model(
        {"action": "continue", "brief": "执行 relay0 自检", "reasoning": "先验证硬件"},
        {"action": "done", "summary": "relay0 正常", "reasoning": "自检通过",
         "memories": [{"text": "relay0 自检通过", "kind": "fact", "salience": 0.8}]},
    )
    store = MemoryStore(tmp_path / "memory")
    events = []
    team = TeamSession(worker, model, memory_store=store,
                       mission_store=MissionStore(tmp_path / "missions"),
                       on_event=events.append, max_steps=3)
    result = asyncio.run(team.ask("检查 relay0"))
    assert result["status"] == "done"
    assert result["output"] == "relay0 正常"
    assert worker.asks == [("执行 relay0 自检", "off")]
    assert store.search("relay0")[0].text == "relay0 自检通过"
    speakers = {event.get("agent") for event in events if event["type"] == "team.message"}
    assert {"memory", "worker"} <= speakers
    assert any(event["type"] == "mission.end" for event in events)


def test_team_stops_at_step_budget(tmp_path):
    worker = FakeWorker(["done-ish"])
    model = memory_model({"action": "continue", "brief": "继续"})
    team = TeamSession(worker, model, memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=MissionStore(tmp_path / "missions"), max_steps=1)
    result = asyncio.run(team.ask("永远做不完"))
    assert result["status"] == "paused"
    assert "step budget" in result["reason"]


def test_team_reports_blocked_without_acting(tmp_path):
    worker = FakeWorker([])
    model = memory_model({"action": "blocked", "summary": "缺少结构文件", "reasoning": "没有 robot"})
    team = TeamSession(worker, model, memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=MissionStore(tmp_path / "missions"))
    result = asyncio.run(team.ask("跑一个不存在的机器人"))
    assert result["status"] == "blocked"
    assert worker.asks == []
    assert "缺少结构文件" in result["output"]


def test_team_falls_back_when_memory_model_is_garbage(tmp_path):
    worker = FakeWorker(["已检查"])
    model = memory_model("这不是 JSON", "这不是 JSON")
    team = TeamSession(worker, model, memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=MissionStore(tmp_path / "missions"), max_steps=4)
    result = asyncio.run(team.ask("检查环境"))
    # A broken decision degrades to a deterministic continue-then-done loop.
    assert result["status"] == "done"
    assert len(worker.asks) == 1
    assert list((tmp_path / "missions").glob("*.json"))


def test_team_cancel_interrupts_mission(tmp_path):
    worker = FakeWorker(["first", "second"], delay=0.05)
    model = memory_model(
        {"action": "continue", "brief": "第一步"},
        {"action": "continue", "brief": "第二步"},
    )
    team = TeamSession(worker, model, memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=MissionStore(tmp_path / "missions"), max_steps=5)

    async def scenario():
        task = asyncio.create_task(team.ask("长任务"))
        await asyncio.sleep(0.02)
        team.cancel()
        with pytest.raises(Exception):
            await task

    asyncio.run(scenario())
    assert team.auto_status()["running"] is False


def test_team_auto_loop_drains_queue_and_stops_at_cap(tmp_path):
    worker = FakeWorker(["done-1", "done-2"])
    model = memory_model(
        {"action": "done", "summary": "done-1"},
        {"action": "done", "summary": "done-2"},
    )
    team = TeamSession(worker, model, memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=MissionStore(tmp_path / "missions"), max_steps=2)

    async def scenario():
        await team.auto_start("任务一", "任务二", max_missions=1, pause=0)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not team.auto_status()["running"]:
                break
            await asyncio.sleep(0.02)
        status = team.auto_status()
        await team.close()
        return status

    status = asyncio.run(scenario())
    assert status["running"] is False
    assert "cap" in status["state"]
    assert worker.closed is True


# -- integration with the real worker ------------------------------------

def test_team_drives_a_real_agent_session(tmp_path):
    """The worker half is the real LangGraph AgentSession, not a stub."""
    from agent_fakes import FunctionModel as _FM
    from pymybot.agent import AgentConfig, AgentSession

    class Executor(FakeExecutor):
        async def start(self, *, deadline=None):
            return {"robot": "test", "hardware": []}

        async def close(self):
            pass

        def protect_prompts(self, *args):
            pass

    worker_model = _FM(lambda messages, info: ModelResponse(parts=[TextPart("继电器自检通过")]))
    decisions = [
        {"action": "continue", "brief": "执行继电器自检", "reasoning": "先验证"},
        {"action": "done", "summary": "继电器正常",
         "memories": [{"text": "继电器自检通过", "kind": "fact"}]},
    ]
    memory = memory_model(*decisions)
    worker = AgentSession(Executor(), worker_model, AgentConfig(intent_mode="off"))
    team = TeamSession(worker, memory, memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=MissionStore(tmp_path / "missions"))
    result = asyncio.run(team.ask("检查继电器"))
    assert result["status"] == "done"
    assert result["output"] == "继电器正常"
    assert worker.turns, "the worker must keep its own conversation history"
    saved = (tmp_path / "missions").glob("*.json")
    assert list(saved), "mission state must be persisted"
    asyncio.run(team.close())


# -- CLI default -----------------------------------------------------------

def test_cli_runs_the_team_by_default(tmp_path, monkeypatch, capsys):
    """`pymybot agent` must run the dual-agent team with no single-agent path."""
    import pymybot.agent as agent_module
    from pymybot import cli
    from pymybot.roles import create_role

    class Executor:
        def __init__(self, *args, stop_event=None, **kwargs):
            self.stop_event = stop_event or threading.Event()
            self.closed = False

        async def start(self, *, deadline=None):
            return {"robot": "test", "hardware": []}

        async def call(self, name, arguments, *, timeout):
            return {"ok": True, "executed": False, "state": "completed", "data": {}}

        def cancel(self):
            self.stop_event.set()

        def protect_prompts(self, *args):
            pass

        async def close(self):
            self.closed = True

    class Client:
        async def close(self):
            pass

    decisions = iter([
        {"action": "continue", "brief": "执行自检", "reasoning": "先验证"},
        {"action": "done", "summary": "自检完成"},
    ])

    def respond(messages, info):
        text = " ".join(str(part.content) for message in messages
                        for part in getattr(message, "parts", ()) if hasattr(part, "content"))
        if "长期记忆" in text:
            return ModelResponse(parts=[TextPart(json.dumps(next(decisions), ensure_ascii=False))])
        return ModelResponse(parts=[TextPart("执行完毕")])

    role = create_role("team-role")
    from pymybot import agent_cli
    monkeypatch.setattr(agent_cli, "RobotExecutor", Executor)
    monkeypatch.setattr(agent_cli, "create_model", lambda config: (FunctionModel(respond), Client()))

    code = cli.main(["--no-gui", "--role", role.name, "--task", "检查继电器"])
    payload = json.loads(capsys.readouterr().out)
    assert code == 0
    assert payload["agents"] == ["memory", "worker"]
    assert payload["output"] == "自检完成"
    assert payload["mission"] and payload["status"] == "done"


def test_worker_failure_is_visible_and_counted_as_an_attempt(tmp_path):
    worker = FakeWorker([])  # first ask raises "worker exhausted"
    model = memory_model({"action": "continue", "brief": "动手"})
    events = []
    mission_store = MissionStore(tmp_path / "missions")
    team = TeamSession(worker, model, memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=mission_store, on_event=events.append, max_steps=2)
    with pytest.raises(Exception):
        asyncio.run(team.ask("做点什么"))
    assert team.last_mission is not None
    assert team.last_mission.status == "failed"
    assert team.last_mission.usage["attempts"] == 1
    assert team.last_mission.usage["steps"] == 0
    end = next(event for event in events if event["type"] == "mission.end")
    assert "worker exhausted" in end["reason"]
    assert any(event["type"] == "team.message" and event.get("agent") == "worker"
               and "执行体" in event["text"] for event in events)


def test_proposal_failure_is_not_reported_as_no_goal(tmp_path):
    def respond(messages, info):
        raise RuntimeError("model offline")

    team = TeamSession(FakeWorker(), FunctionModel(respond),
                       memory_store=MemoryStore(tmp_path / "memory"),
                       mission_store=MissionStore(tmp_path / "missions"), max_steps=1)

    async def scenario():
        await team.auto_start(max_missions=1, pause=0)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not team.auto_status()["running"]:
                break
            await asyncio.sleep(0.02)
        status = team.auto_status()
        await team.close()
        return status

    status = asyncio.run(scenario())
    assert "proposal failed" in status["state"]
    assert "model offline" in status["state"]
