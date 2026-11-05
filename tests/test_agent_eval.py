from pymybot.agent_eval import load_cases, run_cases, score_trajectory


def test_score_passes_expected_tools():
    score = score_trajectory(
        {"tool_events": [{"tool": "run_skill", "ok": True, "state": "completed"}],
         "usage": {"tool_calls": 1}},
        required_tools=["run_skill"], forbidden_tools=["shell"], max_tool_calls=2)
    assert score.ok
    assert score.tool_calls == 1 and score.usage["tool_calls"] == 1


def test_score_fails_unknown_outcome_and_forbidden_tool():
    score = score_trajectory(
        {"tool_events": [{"tool": "shell", "ok": False, "state": "unknown"}]},
        required_tools=["run_skill"], forbidden_tools=["shell"])
    assert not score.ok
    assert score.missing_tools == ("run_skill",)
    assert score.unexpected_tools == ("shell",)
    assert score.unknown_outcomes == 1


def test_score_flags_duplicate_and_budget():
    events = [{"tool": "read_file", "ok": True, "state": "completed"}] * 5
    score = score_trajectory({"tool_events": events}, max_tool_calls=4, max_duplicate_calls=2)
    assert not score.ok and score.tool_calls == 5 and score.duplicate_calls == 4


def test_fixture_cases_all_pass():
    cases = load_cases("tests/fixtures/agent_eval/cases.json")
    runs = {
        "relay-read": {"tool_events": [{"tool": "run_skill", "ok": True, "state": "completed"}]},
        "safe-stop": {"tool_events": [{"tool": "run_skill", "ok": True, "state": "completed"}],
                      "usage": {"tool_calls": 1}},
    }
    results = run_cases(cases, runs)
    assert all(item["ok"] for item in results)
