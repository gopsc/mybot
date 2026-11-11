# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| current minor line | Yes |
| older lines | No |

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

- remote code execution, path traversal or sandbox escape in the controller
  Runtime, the MCP server or the asset APIs;
- ways to bypass the hardware or execution gates (`--allow-hardware`,
  `--allow-execution`);
- credential leakage in logs, errors, releases or packaged assets;
- denial of service that survives cancellation/timeouts in a way that leaves
  hardware in an unsafe state;
- SQL/MT/Lua parser bugs that cross the documented trust boundaries;
- supply-chain or release-integrity problems.

Out of scope by design:

- **Drivers are trusted in-process code.** Python drivers can import arbitrary
  modules and use native I/O directly; LuaJIT FFI is available to Lua drivers.
  Only run reviewed drivers. The `Shell` HAL driver is gated by
  `--allow-hardware`, but it is not a sandbox. This is documented, not a
  vulnerability.
- **Hardware can move.** `active`, `build`, `destroy`, `sample` and action
  scripts may write to devices even when they only appear to read.
- **A public binary cannot keep a secret.** We do not ship shared credentials;
  a release asset must not contain one.
- Missing hardening on a machine that is already fully compromised.

## Security model

pymybot follows these rules:

1. Static commands never activate hardware.
2. Physical devices, non-loopback HTTP and the host shell require an explicit
   opt-in (`--allow-hardware`).
3. The MCP server is read-only by default; `--allow-execution` is a separate
   opt-in, and `--allow-hardware` requires it.
4. An exception after an action has been dispatched latches “result unknown”;
   the command is never retried or rolled back automatically.
5. Releases are built from a tagged public commit; artifacts publish SHA-256
   checksums.

See [`../references/security.md`](../references/security.md) for the detailed threat model.

## Dependency and release hygiene

- Dependencies are pinned to compatible ranges and updated through Dependabot.
- CI runs the test suite on every pull request and release tag.
- Release artifacts include a `SHA256SUMS` file.
- Do not redistribute withdrawn release assets; a withdrawn asset may contain an
  unpublished source tree or a shared credential.

## Known limitations

- Python's `faulthandler` is disabled on Windows because LuaJIT raises Lua
  errors as SEH exceptions; see `docs/history/windows-faulthandler.md`.
- Cancellation stops new work and kills known child trees, but it is not a
  physical emergency stop.
- Python drivers are not a sandbox: imports and direct native I/O are
  unrestricted, and budgets and cancellation are cooperative.
