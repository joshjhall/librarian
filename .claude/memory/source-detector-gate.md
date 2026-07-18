---
name: source-detector-gate
description: "The #348 slice-A source-detector behavioral gate + coverage lift for the 3 review-audit ports; missing-api name-anchor bug fix"
metadata: 
  node_type: memory
  type: project
  originSessionId: ff1d1649-dc08-48f5-912d-ad612d8dbf3f
  modified: 2026-07-18T19:30:02.872Z
---

Issue #348 (follow-up to #243, umbrella) slice A shipped: the 3 review-audit `patterns.py`
ports driven to 100% line-rate, edge-cases-first, via the #204 two-surface convention.

**New gate**: `tests/validate-source-detectors.sh` (modeled on `validate-docs-detectors.sh`'s
parametrized `emit_rows`/`assert_fires`/`assert_silent` drivers, but content-only — no
git-rooting). Covers check-security (secrets/injection/xss/crypto) + check-code-health
(tech-debt/debug/empty-handler) with per-language + boundary/negative fixtures over BOTH
impls. Wired into `run-all.sh` as stage 9e. check-ai-config already had
`validate-checker-detectors.sh` (#204) so its residuals were coverage-driver-only gaps.

**Coverage lift** (measured, local py3.12+coverage): check-security 84→100, check-code-health
68→100, check-ai-config 93→100, missing-api kept 100; TOTAL 84→89%. Corpus extension lives in
`tests/coverage-python.sh` (SRCDIR block + per-port driver cases + negative-path drivers:
usage-error, file-list-not-found, empty-path, unreadable-file, relative-`plugins/` arm).

**Bug fixed** (issue's "Known follow-up"): check-docs-missing-api decided "private" with a
WHOLE-LINE substring (`"def _" in content` / `*"def _"*` / `*"function _"*`), so a public def
whose trailing comment mentioned `def _x` was silently NOT flagged. Fix = anchor on the def/class
NAME (broaden the `defs` regex to admit `_`, then `re.match` the token and `.startswith("_")`),
in BOTH impls preserving byte-parity. Boundary asserted + fault-injected in the docs gate.

**One genuine pragma**: check-security `scan_file`'s `except OSError` is unreachable — `main()`
readability-probes each path and `continue`s BEFORE calling scan_file (redundant double-open);
only a TOCTOU race hits it. check-code-health does NOT have this (main reads content directly),
which is why it reached 100% cleanly.

**Fault-injection** (the #221 precedent, all red→green): crypto comment-skip guard forced true;
debug `if not test_file` guard dropped; credential denylist emptied; is_test_file segment→substring
(the `contest.py` negative is non-tautological). Recorded in each gate header.

Slice B (remaining, → follow-up issue): the 6 dev-core ports loop-make-it-{work,right,secure,
tested,documented} + drift-detect (66–79%), none of which have a dedicated behavioral gate yet.
See [[umbrella-issue-closes-vs-contributes]] (PR says "Contributes to #348", not "Closes"),
[[coverage-two-surfaces]], [[codebase-audit-prescan-location]].
