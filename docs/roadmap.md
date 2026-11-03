# Roadmap

This is a direction document, not a promise. Priorities are reviewed after each
release; security and reproducibility work takes precedence.

## 0.2.x — consolidation

- [x] Community health files, issue forms and PR template.
- [x] Reproducible release workflow with checksums.
- [x] GUI restart/cancellation robustness.
- [ ] More virtual-device fixtures for recently added drivers.
- [ ] English translations for the remaining reference docs.

## 0.3.x — operator experience

- [ ] First-run model setup wizard in the GUI (no shared key, no hidden default).
- [ ] Guided hardware discovery for UART/FTDI devices.
- [x] Action-script editor with syntax highlighting and dry-run (removed in
  0.6.0; the GUI now offers the command panel and a read-only resource browser).
- [ ] Sampling charts and a session timeline in the GUI.
- [x] Bounded conversation transcripts under `~/.mybot/sessions`
  (on by default; `--no-session-log` / `MYBOT_SESSION_LOG=0` disables them).
- [x] Runtime prompt layering (`SOUL` / `USER` / `STATS`), CLI list/restore and
  GUI management; trusted safety hashes, operator-only core, separately approved
  prompt updates with CAS/backups, and optional sanitized host-only STATS.
- [ ] Signed Windows/macOS installers (requires maintainer certificates).

## 0.4.x — runtime and scale

- [x] Standard MCP over stdio: `pymybot mcp` exposes the read-only controller,
  and the agent can call operator-configured external MCP servers.
- [x] Best-effort abort (`abort` / `session.abort` / GUI **急停**) with optional
  Python/Lua `safe()` hooks and a bounded, reverse-order stop path.
- [x] Shared frozen-asset plan for the onedir and onefile PyInstaller specs.
- [x] Runnable `pymybot new` scaffold and a README quick start.
- [ ] Remote MCP transports (HTTP/SSE), after a network threat-model review.
- [ ] Pluggable model providers beyond the current four, without duplicating
  HTTP code.
- [ ] Streaming tool results for long-running actions.
- [ ] Multi-robot sessions with explicit per-robot locks.
- [ ] Stronger cancellation for blocking native I/O (documented limits remain).
- [ ] Optional OpenTelemetry traces for agent/tool latency.

## Before 1.0

- Freeze the `serve` JSON-RPC protocol and publish a JSON schema.
- Publish a compatibility matrix per driver and firmware.
- Complete a security review of the agent’s file/shell/network boundaries.
