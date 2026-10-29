# Support

## Where to ask

| Need | Channel |
| --- | --- |
| Bug with a reproducible failure | GitHub issue (bug report form) |
| Feature idea / design question | GitHub issue (feature request form) |
| Usage question | GitHub Discussions, or a question issue if Discussions are unavailable |
| Security vulnerability | Private advisory — see [`SECURITY.md`](SECURITY.md) |
| Commercial / hardware integration | Contact the repository owner |

## What to include

- Version or commit (`pymybot --version`, `git rev-parse HEAD`).
- OS, Python version and install method.
- The exact command and the full JSON/error output (remove credentials).
- Whether hardware is connected; if not, use the virtual-bus or `loop://`
  example and say so.

## What we cannot support

- Running untrusted Lua or shell commands safely.
- Hardware we do not have; we can help debug drivers, but cannot guarantee a
  device works without a maintainer or contributor test.
- Model providers or endpoints we cannot reach.
- Recovering a robot from an action that has already been dispatched; the
  runtime reports “result unknown” instead of pretending to roll back.

## Response expectations

This is a volunteer-maintained project. Issues are triaged as time permits.
Security reports take priority. Please do not ping maintainers repeatedly in
multiple channels.
