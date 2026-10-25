# Contributing

Thanks for improving pymybot. This repository contains three editions; the
Python reference edition is at the root, and the Cangjie and C++17 + Rust
editions live under `implementations/`. Read the relevant edition README before
changing code.

## Before you start

- Search existing issues and discussions first.
- For a bug, open an issue with a minimal reproduction, expected/actual
  behaviour, OS, Python/Cangjie/Rust version and relevant logs.
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

For the agent and GUI:

```sh
.venv/bin/pip install -e ".[agent,test]"
.venv/bin/python -m pymybot            # GUI
.venv/bin/python -m pymybot --no-gui   # terminal
```

See [`docs/development.md`](docs/development.md) for linting, packaging and
frozen-build commands. Edition-specific prerequisites are in each
`implementations/*/README.md`.

## Branches and commits

- `main` is the only long-lived branch. Work on a short-lived topic branch.
- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`,
  `ci:`, `chore:`. The scope is optional but encouraged, e.g.
  `fix(gui): ...`.
- Keep each commit focused. Do not mix formatting-only changes with behaviour
  changes.
- Rebase on `main` before opening a pull request; do not merge `main` into the
  topic branch.
- Do not commit generated build output, editor state, credentials or model
  API keys.

## Pull requests

A pull request should include:

- a clear problem statement and the chosen approach;
- tests that fail before the fix and pass after it (for behaviour changes);
- documentation updates when the operator-facing behaviour changes;
- a note on security/privacy impact for anything touching shell, files,
  network, hardware, prompts or credentials.

The PR template contains the full checklist. CI must be green before merge.
Maintainers may squash-merge. Review is expected from at least one other
maintainer; self-merge is reserved for repository-maintenance work explicitly
authorized by the project owner.

## Testing expectations

- Python: `python -m pytest` (the suite must not require hardware).
- New drivers: add a `tests/fixtures/virt/<driver>_virt.{sql,mt}` end-to-end
  case, or explain why the device cannot be modelled.
- GUI/server changes: add tests that run without a display where possible.
- Packaging changes: run `python -I scripts/ci_smoke.py wheel`.
- Cangjie/C++/Rust: run the edition's own test target as documented in its
  README.

Never weaken a test to make it pass. If a test exposes a real bug, fix the bug
or document the limitation in the issue.

## Security and privacy

- Never commit API keys, tokens, certificates or personal data.
- Do not add a shared built-in credential. A public binary cannot keep a secret;
  require user-provided credentials or an operator-controlled proxy.
- Tools that can write files, execute shell commands, access hardware or send
  data to a model require explicit operator approval and must remain opt-in.
- Report vulnerabilities privately per [`SECURITY.md`](SECURITY.md).

## Documentation style

- Chinese is the primary language for the reference edition; English summaries
  live in `README.en.md` and selected docs.
- Prefer concrete commands, screenshots and tables over marketing prose.
- Link to existing references instead of duplicating large sections.
- Keep line-oriented Markdown; avoid hard wrapping inside paragraphs.

## License

By contributing you agree that your contribution is licensed under the MIT
License in [`LICENSE`](LICENSE).
