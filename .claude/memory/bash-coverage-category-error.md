---
name: bash-coverage-category-error
description: "Line coverage is meaningless for the patterns.sh grep-pipeline ports; Codecov should target python + mjs, not bash"
metadata:
  node_type: memory
  type: project
  originSessionId: eb9ed30d-d710-4bd7-99a1-89bc96c3db29
---

Experiment (2026-07-03, issue #186): measured coverage of both impls of
`check-security` on the identical `validate-python-ports.sh` parity fixture.
Python `patterns.py` = **26.2%** (coverage.py, real). Bash `patterns.sh`
(`PATTERNS_FORCE_BASH=1`) = **~14%** via a native PS4 line tracer — but that
number is **instrument noise, not a coverage signal**.

**Why:** the bash impl's detection logic is ~12 `grep -nE 'regex'` blocks — the
matching lives in regex alternations run by an external `grep` subprocess. A
line tracer (and largely `kcov`) sees only the line that *invokes* grep, never
which alternations fired. Both impls emitted byte-identical findings, so the
work happened; the tool just can't see it. Line coverage is the wrong instrument
for grep-pipeline code.

**How to apply:** For #186 (and any future coverage work) target **python
`patterns.py` + `.mjs` validators** — meaningful, in-process coverage. Do NOT
chase a bash coverage %. The bash fallback is already guarded by
`validate-python-ports.sh` byte-parity + `lint-shell-portability.sh`. The only
bash-only surface worth a dedicated unit test is the **version-gate shim** (~9
lines dispatching python-vs-bash — real branching, no python counterpart). See
[[two-runtime-model]]. Tooling: kcov/bashcov aren't packaged in the dev image;
coverage.py installs via pip.
