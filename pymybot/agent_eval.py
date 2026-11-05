"""Deterministic trajectory scoring for agent regression evaluation.

This is not an LLM judge: it scores the machine-readable tool receipts and
usage that every harness run already emits. That keeps CI offline, cheap and
reproducible, while catching unsafe retries, wrong tool selection and budget
overruns.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
import json
from pathlib import Path


@dataclass(frozen=True)
class TrajectoryScore:
    ok: bool
    tool_calls: int
    required_tools: tuple[str, ...]
    forbidden_tools: tuple[str, ...]
    missing_tools: tuple[str, ...]
    unexpected_tools: tuple[str, ...]
    unknown_outcomes: int
    failed_tools: int
    duplicate_calls: int
    usage: dict

    def as_dict(self):
        return asdict(self)


def _events(result):
    events = result.get("tool_events") if isinstance(result, dict) else None
    if not isinstance(events, list):
        events = result if isinstance(result, list) else []
    return [event for event in events if isinstance(event, dict) and isinstance(event.get("tool"), str)]


def score_trajectory(result, *, required_tools=(), forbidden_tools=(), max_tool_calls=None,
                     max_duplicate_calls=3):
    """Score one run against explicit expectations.

    ``unknown`` outcomes are always failures: a harness must never claim a
    dispatched action was undone or safe to retry. Identical consecutive tool
    names are counted conservatively because event records do not include
    arguments; callers that need exact duplicate detection should store their
    own argument fingerprints.
    """
    events = _events(result)
    names = [event["tool"] for event in events]
    required = tuple(required_tools)
    forbidden = tuple(forbidden_tools)
    missing = tuple(name for name in required if name not in names)
    unexpected = tuple(name for name in forbidden if name in names)
    unknown = sum(1 for event in events if event.get("state") == "unknown")
    failed = sum(1 for event in events if event.get("ok") is False
                 and event.get("state") != "not_executed")
    duplicates = 0
    run_length = 1
    for previous, current in zip(names, names[1:]):
        if previous == current:
            run_length += 1
            if run_length > 1:
                duplicates += 1
        else:
            run_length = 1
    over_budget = max_tool_calls is not None and len(events) > int(max_tool_calls)
    too_many_duplicates = duplicates > int(max_duplicate_calls)
    ok = (not missing and not unexpected and unknown == 0 and failed == 0
          and not over_budget and not too_many_duplicates)
    return TrajectoryScore(
        ok=ok, tool_calls=len(events), required_tools=required, forbidden_tools=forbidden,
        missing_tools=missing, unexpected_tools=unexpected, unknown_outcomes=unknown,
        failed_tools=failed, duplicate_calls=duplicates,
        usage=dict(result.get("usage") or {}) if isinstance(result, dict) else {},
    )


def load_cases(path):
    """Load JSON or JSONL regression cases from one file."""
    text = Path(path).read_text(encoding="utf-8")
    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = [json.loads(line) for line in text.splitlines() if line.strip()]
    if isinstance(parsed, dict):
        parsed = parsed.get("cases") or []
    if not isinstance(parsed, list):
        raise ValueError("eval cases must be a list or an object with a cases list")
    return [case for case in parsed if isinstance(case, dict) and isinstance(case.get("name"), str)]


def run_cases(cases, trajectories):
    """Score named cases against a mapping of name -> recorded run result."""
    results = []
    for case in cases:
        name = case["name"]
        run = trajectories.get(name)
        if run is None:
            results.append({"name": name, "ok": False, "error": "trajectory missing"})
            continue
        score = score_trajectory(
            run,
            required_tools=case.get("required_tools") or (),
            forbidden_tools=case.get("forbidden_tools") or (),
            max_tool_calls=case.get("max_tool_calls"),
            max_duplicate_calls=case.get("max_duplicate_calls", 3),
        )
        results.append({"name": name, **score.as_dict()})
    return results
