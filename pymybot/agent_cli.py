"""CLI frontend for the agent: console approval, stream rendering, entry point.

Extracted from agent.py to keep the core session logic focused. This module
owns all terminal I/O and the ``run_cli_agent`` entry point that the CLI
subcommand dispatches to.
"""
from __future__ import annotations

import asyncio
import os
import sys
import threading
from pathlib import Path

from .agent import (
    AgentConfig,
    AgentConfigurationError,
    AgentError,
    AgentSession,
    create_model,
    describe_failure,
    request_endpoint,
    FILE_WRITE_TOOLS,
    MAX_TEXT,
    _display_text,
)
from .agent_executor import RobotExecutor
from .agent_prompt import DEFAULT_CONTEXT_BYTES
from .agent_skills import SkillsLibrary, default_skills_root
from .errors import AgentInterrupted
from .sandbox import describe_backend
from .security import SecurityError, dumps
from .session_log import create_session_log


async def console_line(prompt, stop):
    """Cancelable console wait; a blocked stdin reader must not hold shutdown open."""
    print(prompt, file=sys.stderr, end="", flush=True)
    loop = asyncio.get_running_loop()
    ready = loop.create_future()

    def finish(value):
        if not ready.done():
            ready.set_result(value)

    def read():
        try:
            line = sys.stdin.readline()
        except (OSError, ValueError):
            line = ""
        try:
            loop.call_soon_threadsafe(finish, line)
        except RuntimeError:
            pass

    threading.Thread(target=read, name="mybot-console", daemon=True).start()
    try:
        while not ready.done():
            if stop.is_set():
                raise AgentInterrupted("Interrupted while waiting for input")
            await asyncio.wait({ready}, timeout=0.05)
        line = ready.result()
        return line.rstrip("\r\n") if line else None
    finally:
        ready.cancel()


async def confirm_console(name, arguments, stop):
    if not sys.stdin.isatty():
        return False
    if name == "prompt:update_prompt":
        description = dumps(arguments)
        if len(description.encode("utf-8")) > 128 * 1024:
            print("Prompt approval denied: diff too large to display completely.", file=sys.stderr)
            return False
        print(_display_text(f"Layer {arguments['layer']} · {arguments['reason']}\n{arguments['diff']}"),
              file=sys.stderr)
        answer = await console_line("Approve prompt replacement and private backup? [y/N] ", stop)
        return answer is not None and answer.strip().lower() in {"y", "yes"}
    description = repr(dumps(arguments))
    limit = 2000
    if len(description) > limit:
        print("Approval denied: arguments too long to display completely; reduce the request.", file=sys.stderr)
        return False
    if name.startswith("mcp:"):
        warning = ("This calls an operator-configured MCP server with host-user permissions, "
                   "NOT in a sandbox; it may act on the host or network.")
    elif name == "shell":
        warning = ("Host shell runs inside the configured sandbox; a workspace jail alone is not "
                   "an OS boundary, and hardware access is not limited by --allow-hardware.")
    elif name == "install_skill":
        warning = "This installs trusted skill code and assets that may influence or execute in later requests."
    elif name == "uninstall_skill":
        warning = "This permanently removes an installed skill and its scripts, references and assets."
    elif name in FILE_WRITE_TOOLS:
        warning = "This changes workspace files, potentially including executable scripts or drivers."
    else:
        warning = "Activation may write to devices."
    answer = await console_line(f"Approve {name} {description}? {warning} [y/N] ", stop)
    return answer is not None and answer.strip().lower() in {"y", "yes"}


class StreamRenderer:
    """Live turn progress on stderr; stdout stays reserved for the final JSON line."""

    def __init__(self, stream=None):
        self.stream = stream if stream is not None else sys.stderr
        self.mid_line = False
        self.text_chars = 0

    def __call__(self, event):
        kind = event.get("type")
        if kind == "text_delta":
            remaining = MAX_TEXT - self.text_chars
            if remaining <= 0:
                return
            text = _display_text(event["text"])[:remaining]
            self.text_chars += len(text)
            self.stream.write(text)
            self.stream.flush()
            self.mid_line = True
        elif kind == "tool_call":
            self._end_line()
            brief = repr(dumps(event["arguments"])) if event.get("arguments") is not None else ""
            if len(brief) > 120:
                brief = brief[:117] + "..."
            self.stream.write(f"→ {_display_text(str(event['tool']))}({brief})\n")
            self.stream.flush()
        elif kind == "tool_result":
            state = event.get("state")
            tail = f" {_display_text(str(state))}" if state else ""
            self.stream.write(f"⇦ {_display_text(str(event['tool']))}{tail}\n")
            self.stream.flush()
        elif kind == "team.message":
            if event.get("agent") != "memory":
                return
            self._end_line()
            self.stream.write(f"[记忆体] {_display_text(str(event.get('text') or ''))}\n")
            self.stream.flush()

    def _end_line(self):
        if self.mid_line:
            self.stream.write("\n")
            self.mid_line = False

    def end_turn(self):
        """Terminate the streamed line; True if any text streamed during this turn."""
        self._end_line()
        streamed = self.text_chars > 0
        self.text_chars = 0
        return streamed


async def _conversation(session, args, stop, renderer=None):
    """Run one seeded mission, or the self-directed loop when no seed is given."""
    if args.task is not None:
        result = await session.ask(args.task)
        if renderer is not None:
            renderer.end_turn()
        return {"mode": "agent", **result, "tool_events": session.events}
    await session.auto_start(max_missions=getattr(args, "max_missions", 20))
    print("mybot autonomous run started; Ctrl+C to stop.", file=sys.stderr)
    try:
        while session.auto_status().get("running") and not stop.is_set():
            await asyncio.sleep(0.5)
    finally:
        status = await session.auto_stop()
    if stop.is_set():
        raise AgentInterrupted("Interrupted; already dispatched actions are not rolled back")
    return {"mode": "agent", "autonomous": True, "status": status,
            "tool_events": session.events}


async def run_cli_agent(args, stop):
    executor = client = session = session_log = None
    failure = result = None
    cleanup_errors = []
    try:
        if getattr(args, "robot", None) and not Path(args.robot).is_file():
            raise AgentConfigurationError(
                f"Robot structure not found: {args.robot}; no model request was sent")
        try:
            from .roles import load_role
            role = load_role(args.role) if getattr(args, "role", None) else None
        except (OSError, SecurityError) as exc:
            raise AgentConfigurationError(f"Cannot load role: {exc}; no model request was sent") from None
        mcp_config = (str(role.mcp_config) if role is not None and role.mcp_config.is_file()
                      else getattr(args, "mcp_config", None) if role is None else None)
        config = AgentConfig(model=args.model or os.environ.get("MYBOT_MODEL", ""),
                             base_url=args.base_url or os.environ.get("MYBOT_BASE_URL"),
                             api_key_env=args.api_key_env, timeout=args.timeout,
                             history_bytes=args.max_history_bytes,
                             max_context_tokens=getattr(args, "max_context_tokens", None),
                             context_reserve_tokens=getattr(args, "context_reserve_tokens", 2048),
                             allow_actions=args.allow_actions,
                             allow_file_writes=args.allow_file_writes,
                             allow_shell=getattr(args, "allow_shell", False),
                             mcp_config=mcp_config,
                             allow_mcp_tools=getattr(args, "allow_mcp_tools", False),
                             prompt_file=getattr(args, "prompt_file", None),
                             context_bytes=getattr(args, "context_bytes", DEFAULT_CONTEXT_BYTES),
                             intent_mode=getattr(args, "intent", "auto"),
                             sandbox_mode=getattr(args, "sandbox", "auto"),
                             enable_web=getattr(args, "web", False),
                             allow_web=getattr(args, "allow_web", False),
                             search_endpoint=getattr(args, "search_endpoint", "") or "",
                             auto_stats=not getattr(args, "no_prompt_stats", False),
                             hot_turns=getattr(args, "hot_turns", 3),
                             warm_turns=getattr(args, "warm_turns", 10))
        try:
            from .mcp_client import load_servers
            mcp_servers = load_servers(config.mcp_config)
        except Exception as exc:
            raise AgentConfigurationError(
                f"Cannot load MCP configuration: {exc}; no model request was sent") from None
        model, client = create_model(config)
        session_log = create_session_log(enabled=not getattr(args, "no_session_log", False),
                                         robot=args.robot or "", model=config.model, mode="cli",
                                         role=role.name if role is not None else "")
        try:
            skills_dir = role.skills_dir if role is not None else (args.skills_dir or default_skills_root())
            skills = SkillsLibrary(skills_dir, required=role is not None or args.skills_dir is not None)
        except SecurityError as exc:
            raise AgentConfigurationError(
                f"Cannot load skills configuration: {exc}; no model request was sent") from None
        workspace_dir = str(role.workspace_dir) if role is not None else args.workspace_dir
        executor = RobotExecutor(args.robot, module_paths=args.module_path,
                                 scripts_dir=args.scripts_dir, allow_hardware=args.allow_hardware,
                                 stop_event=stop,
                                 vars=getattr(args, "bindings", None),
                                 skills=skills, workspace_dir=workspace_dir, enable_shell=args.enable_shell,
                                 sandbox=config.sandbox_mode)
        if args.enable_shell:
            print(f"Shell enabled: {describe_backend(config.sandbox_mode)}; "
                  f"approval is still separate.", file=sys.stderr)

        async def confirm(name, arguments):
            return await confirm_console(name, arguments, stop)

        renderer = StreamRenderer()
        worker = AgentSession(executor, model, config, confirm=confirm,
                              skills=skills, session_log=session_log,
                              workspace=workspace_dir is not None,
                              enable_shell=args.enable_shell,
                              mcp_servers=mcp_servers, role=role)
        from .agent_team import TeamSession
        session = TeamSession(worker, model, role=role, on_event=renderer,
                              max_steps=getattr(args, "team_steps", 8),
                              max_seconds=getattr(args, "mission_timeout", 1800.0),
                              max_tokens=getattr(args, "mission_tokens", 400_000))
        result = await _conversation(session, args, stop, renderer)
    except BaseException as exc:
        failure = exc
    finally:
        resources = (session, client) if session is not None else (executor, client)
        for resource in resources:
            if resource is not None:
                try:
                    await resource.close()
                except BaseException as exc:
                    cleanup_errors.append(type(exc).__name__)
                    failure = failure or exc
        if session is None and session_log is not None:
            session_log.close()
    if failure is not None:
        if not isinstance(failure, (AgentError, AgentInterrupted, KeyboardInterrupt, asyncio.CancelledError)):
            failure = AgentError(f"Agent failed ({describe_failure(failure, request_endpoint(client))}); check configuration or tool receipts. "
                                 "Already dispatched actions are not rolled back or automatically retried")
        failure.tool_events = session.events if session is not None else []
        failure.cleanup_errors = cleanup_errors
        raise failure from None
    return result
