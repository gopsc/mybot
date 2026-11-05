"""Run deterministic agent trajectory regressions.

Examples:
  python -m tools.agent_eval --cases tests/fixtures/agent_eval/cases.json \
      --runs tests/fixtures/agent_eval/runs.json
"""
from __future__ import annotations

import argparse
import json
import sys

from pymybot.agent_eval import load_cases, run_cases


def main(argv=None):
    parser = argparse.ArgumentParser(description="Score recorded agent trajectories")
    parser.add_argument("--cases", required=True, help="JSON/JSONL regression cases")
    parser.add_argument("--runs", required=True, help="JSON object mapping case name to a run result")
    args = parser.parse_args(argv)
    cases = load_cases(args.cases)
    with open(args.runs, encoding="utf-8") as stream:
        runs = json.load(stream)
    if not isinstance(runs, dict):
        raise SystemExit("runs must be a JSON object mapping names to trajectories")
    results = run_cases(cases, runs)
    print(json.dumps({"ok": all(item.get("ok") for item in results), "results": results},
                     ensure_ascii=False, indent=2))
    return 0 if all(item.get("ok") for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
