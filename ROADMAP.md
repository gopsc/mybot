# Roadmap

This is a direction document, not a promise. Priorities are reviewed after each
release; security and reproducibility work takes precedence.

## 0.2.x — consolidation

- [x] Monorepo layout for Python, Cangjie and C++17 + Rust editions.
- [x] Community health files, issue forms and PR template.
- [x] Reproducible release workflow with checksums.
- [x] GUI restart/cancellation robustness.
- [ ] More virtual-device fixtures for recently added drivers.
- [ ] English translations for the remaining reference docs.

## 0.3.x — operator experience

- [ ] First-run model setup wizard in the GUI (no shared key, no hidden default).
- [ ] Guided hardware discovery for UART/FTDI devices.
- [ ] Action-script editor with syntax highlighting and dry-run.
- [ ] Sampling charts and a session timeline in the GUI.
- [ ] Signed Windows/macOS installers (requires maintainer certificates).

## 0.4.x — runtime and scale

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
- Decide whether the Cangjie and C++/Rust editions follow the repository version
  or keep independent version lines.
