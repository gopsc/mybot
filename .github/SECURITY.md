# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.2.x | Yes |
| < 0.2 | No |

Security fixes are released on the current minor line. Older releases may be
asked to upgrade.

## Reporting a vulnerability

Please do **not** open a public issue for an exploitable vulnerability.

Use GitHub's private vulnerability reporting:

<https://github.com/gopsc/mybot/security/advisories/new>

If that form is unavailable, contact the maintainers through the repository
owner's GitHub profile and ask for a private channel. Include:

- affected version/commit;
- reproduction steps or a proof of concept;
- impact and required preconditions;
- whether the issue is already public.

We aim to acknowledge reports within 3 business days, agree on a disclosure
timeline, and credit reporters unless they prefer otherwise.

## Scope

In scope:

- remote code execution, path traversal or sandbox escape in the Python agent
  tools, workspace, `serve` backend or frozen GUI;
- approval bypasses that let a model execute hardware, shell or file actions
  without the operator's explicit consent;
- credential leakage in logs, errors, transcripts, releases or packaged assets;
- denial of service that survives cancellation/timeouts in a way that leaves
  hardware in an unsafe state;
- SQL/MT/Lua parser bugs that cross the documented trust boundaries;
- supply-chain or release-integrity problems.

Out of scope by design:

- **The workspace jail is not an OS sandbox.** The agent shell only runs inside
  bubblewrap, with the runtime and bundled prompt roots mounted read-only. If
  that cannot be set up — Windows included — it refuses to run instead of
  falling back to the workspace jail. The `Shell` HAL driver is outside that
  sandbox either way. This is documented, not a vulnerability.
- **Lua is trusted code.** LuaJIT FFI is available to drivers; only run reviewed
  drivers. This is documented.
- **Hardware can move.** `active`, `build`, `destroy`, `sample` and action
  scripts may write to devices even when they only appear to read.
- **A public binary cannot keep a secret.** We do not ship shared API keys; use
  your own endpoint/key or an operator-controlled proxy.
- Missing hardening on a machine that is already fully compromised.

## Security model

pymybot follows these rules:

1. Static commands never activate hardware.
2. Physical devices, non-loopback HTTP and the host shell require an explicit
   opt-in (`--allow-hardware` / GUI approval).
3. Agent tools default to read-only; action, file-write and shell tools require
   per-session pre-authorisation or a confirmation dialog.
4. File tools stay inside an explicitly configured workspace, reject links,
   traversal and special files, and bound reads/writes.
5. Model prompts, tool arguments and tool results are untrusted data. They are
   never executed as code and are sanitised before terminal output.
6. Releases are built from a tagged public commit; artifacts publish SHA-256
   checksums.

See [`../docs/security.md`](../docs/security.md) for the detailed threat model.

## Dependency and release hygiene

- Dependencies are pinned to compatible ranges and updated through Dependabot.
- CI runs the test suite on every pull request and release tag.
- Release artifacts include a `SHA256SUMS` file.
- Do not use the `gui-v1` asset from 2026-10-25; it was withdrawn because it
  contained an unpublished source tree and a shared credential.

## Known limitations

- Python's `faulthandler` is disabled on Windows because LuaJIT raises Lua
  errors as SEH exceptions; see `docs/history/windows-faulthandler.md`.
- Cancellation stops new work and kills known child trees, but it is not a
  physical emergency stop.
- The agent's model context is not encrypted at rest in memory; do not send
  secrets to a third-party model.
