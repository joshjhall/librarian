---
name: lint-gates-per-language
description: "Where each language's lint/format gate lives and how CI actually runs the skip-if-absent tools"
metadata:
  node_type: memory
  type: project
  originSessionId: 1ac0f375-23a6-4d60-93e2-6e59f911c353
---

Linting in librarian is language-by-language, all gated through `tests/run-all.sh`
(which gates CI via ci.yml quality-gates + pre-push via lefthook):

- **Python** (the 14 `plugins/*/skills/*/patterns.py` from #17): `tests/lint-python.sh`
  runs `ruff check` + `ruff format --check`; config in `ruff.toml` (py311, rules
  F/E/W/I/B, E501 enforced). `just lint`/`just fmt` also run ruff.
- **Shell**: `tests/lint-shellcheck.sh` (`shellcheck --severity=warning` over
  `plugins/ tests/ bin/`) + `tests/lint-shell-portability.sh` (bans bash-4
  constructs, macOS bash-3.2 target). shellcheck was local-only until #185
  promoted it to a CI gate.
- **JSON/YAML/TOML/markdown**: dprint/taplo/rumdl via `just lint`.

**Why:** added in PR #185 (this repo previously had zero Python lint and shellcheck
only in lefthook). The gates **skip-if-absent** so bare hosts don't break — but
ci.yml AND release.yml install `shellcheck`+`ruff` (via `apt` + `pipx`) and a
"Verify linters are on PATH" step **fails loudly** if an install regresses, so
the gates never silently no-op in CI. The Python files these lint are the
Python-primary/bash-fallback pre-scan tools from #17 (`patterns.py` + a shim in
`patterns.sh`); their bash↔python parity is separately pinned by
`tests/validate-python-ports.sh`.
