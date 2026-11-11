# Contributing

Thanks for improving pymybot. The controller Runtime lives in
`skills/hardware-controller/scripts/pymybot/`; the root `pymybot/` package is a
version and import shim. Read the relevant docs before changing code.

## Before you start

- Search existing issues and discussions first.
- For a bug, open an issue with a minimal reproduction, expected/actual
  behaviour, OS, Python version and relevant logs.
- For a feature, open an issue that states the use case and the operator
  experience before writing code. Security-sensitive features need a design
  discussion first.
- Small fixes (typos, broken links, isolated doc corrections) may go straight
  to a pull request.

## Development setup

```sh
git clone https://github.com/gopsc/mybot.git
cd mybot
python -m venv .venv
.venv/bin/pip install -e ".[test]"
.venv/bin/python -m pytest
```

For MCP work, add the optional SDK:

```sh
.venv/bin/pip install -e ".[mcp,test]"
```

See [`../docs/development.md`](../docs/development.md) for linting and packaging
commands.

## Branches and commits

- The default branch (`gui-mybot`; the owner may rename it to `main`) is the only
  long-lived branch. Work on a short-lived topic branch.
- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`,
  `ci:`, `chore:`. The scope is optional but encouraged, e.g.
  `fix(driver): ...`.
- Keep each commit focused. Do not mix formatting-only changes with behaviour
  changes.
- Rebase on the default branch before opening a pull request; do not merge the
  default branch into the topic branch.
- Do not commit generated build output, editor state or credentials.

## Pull requests

A pull request should include:

- a clear problem statement and the chosen approach;
- tests that fail before the fix and pass after it (for behaviour changes);
- documentation updates when the operator-facing behaviour changes;
- a note on security/privacy impact for anything touching shell, network,
  hardware or credentials.

The PR template contains the full checklist. CI must be green before merge.
Maintainers may squash-merge. Review is expected from at least one other
maintainer; self-merge is reserved for repository-maintenance work explicitly
authorized by the project owner.

## Testing expectations

- Python: `python -m pytest` (the suite must not require hardware).
- New drivers: add a `tests/fixtures/virt/<driver>_virt.{sql,mt}` end-to-end
  case, or explain why the device cannot be modelled.
- MCP/server changes: add tests that exercise the stdio protocol without
  hardware.
- Packaging changes: run `python -I tools/ci_smoke.py wheel`.

Never weaken a test to make it pass. If a test exposes a real bug, fix the bug
or document the limitation in the issue.

## Security and privacy

- Never commit API keys, tokens, certificates or personal data.
- Do not add a shared built-in credential. A public binary cannot keep a secret.
- Capabilities that can move hardware, run shell commands or reach non-loopback
  networks require an explicit opt-in (`--allow-hardware` / `--allow-execution`)
  and must remain opt-in.
- Report vulnerabilities privately per [`SECURITY.md`](SECURITY.md).

## Documentation style

- Chinese is the primary language for the project; English summaries
  live in [`docs/README.en.md`](../docs/README.en.md) and selected docs.
- Prefer concrete commands and tables over marketing prose.
- Link to existing references instead of duplicating large sections.
- Keep line-oriented Markdown; avoid hard wrapping inside paragraphs.

## License

By contributing you agree that your contribution is licensed under the MIT
License in [`../LICENSE`](../LICENSE).
