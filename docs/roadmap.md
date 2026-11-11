# Roadmap

This is a direction document, not a promise. Priorities are reviewed after each
release; security and reproducibility work takes precedence.

## 0.7.x — controller only

The agent and desktop removal is done and the repository is a hardware controller:

- [x] Removed the Agent, GUI, roles, runtime prompts and session transcripts. The
  supported entry points are the Python CLI and the MCP stdio server.
- [x] Removed the desktop and agent packaging path; releases publish an sdist, a
  wheel and `SHA256SUMS`.
- [ ] More virtual-device fixtures for recently added drivers.
- [ ] English translations for the remaining reference docs.
- [ ] Remote MCP transports (HTTP/SSE), after a network threat-model review.
- [ ] Streaming tool results for long-running actions.
- [ ] Stronger cancellation for blocking native I/O (documented limits remain).

## 0.2.x — consolidation

- [x] Community health files, issue forms and PR template.
- [x] Reproducible release workflow with checksums.

## 0.3.x — operator experience

- [x] Guided hardware discovery for UART/FTDI devices.

## 0.4.x — runtime and scale

- [x] Standard MCP over stdio: `pymybot mcp` exposes the read-only controller.
- [x] Runnable `pymybot new` scaffold and a README quick start.

## Before 1.0

- Publish a compatibility matrix per driver and firmware.
- Complete a security review of the driver/HAL trust boundary.
