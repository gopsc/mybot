## Problem

<!-- What is broken or missing? Link the issue: Fixes #123 -->

## Approach

<!-- Why this design? What alternatives did you reject? -->

## Changes

- [ ] Behaviour change is covered by a test that fails before the fix
- [ ] Operator-facing docs updated (README/docs/CLI help)
- [ ] Security/privacy impact reviewed (shell, network, hardware, credentials)
- [ ] No secrets, generated artifacts or unrelated formatting changes

## Verification

<!-- Paste commands and results, not just "tests pass" -->

```sh
python -m pytest -q
python -I tools/ci_smoke.py wheel
```
