---
name: issue-435-check-lifecycle
description: "Shipped PR #456 — new check-lifecycle scanner; how to add a check-* domain + the 3-cycle review that caught real integration gaps"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4df7b207-ab76-496a-b989-5b11ae708557
  modified: 2026-07-21T02:19:14.988Z
---

**#435 → PR #456 MERGED (e4b38cb, 2026-07-21, L3 auto-merge squash — self-merge
was NOT blocked this time, unlike [[auto-mode-blocks-self-merge]]):** added a generic `check-lifecycle` scanner
skill to `review-audit` (resource-lifetime lens: unreaped-subprocess /
terminate-without-kill / unclosed-handle / unpaired-listener across
Swift/Python/JS/Go, MEDIUM certainty = candidates; unjoined-worker +
unbounded-growth are LLM-only pass-2). Mirrors `check-code-health` 6-file shape
(patterns.py primary + byte-identical patterns.sh fallback).

**Adding a new check-* built-in DOMAIN is more than the skill dir.** The full
registration surface (adversarial review found the ones I missed):

- skill dir `skills/check-<name>/` (SKILL/contract/metadata/thresholds/patterns.*)
- `codebase-audit/orchestration-protocol.md` — Step 2 routing table + built-in
  domain list + Step 2.5 pre-scan **collection filter**
- `codebase-audit/workflow.js` — `mapPrompt` routing hint AND `scanPrompt`
  parenthetical (the live per-scan instruction text — easy to miss)
- `agents/checker.md` Step 3 pre-scan collection
- `codebase-audit/metadata.yml` `audit/<name>` label + `issue-templates.md`
  Category Labels row
- `plugins/review-audit/README.md` skill list + count
- test gate `tests/validate-<name>-detectors.sh` wired into `run-all.sh` +
  `coverage-python.sh` corpus arm (default arm only runs the generic FILE_LIST,
  so per-language branches go unmeasured without a dedicated case arm)

**MEDIUM-certainty pre-scan is a NEW pattern.** check-security/check-code-health
hardcode `CERTAINTY="HIGH"`; the collection logic in checker.md +
orchestration-protocol.md was written as "collect HIGH + deterministic" — which
would SILENTLY DROP a MEDIUM-emitting scanner. Fix = collect by `method ==
deterministic` (any certainty); HIGH → auto-include fast path, MEDIUM/LOW → Pass-2
candidate. Generalize all THREE description sites (checker.md, orchestration
Step 2.5, workflow.js scanPrompt) in lockstep.

**Whole-repo differential gate is the parity teeth.** `patterns.py`↔`patterns.sh`
must be byte-identical; `validate-prescan-differential.sh` diffs both over the
WHOLE repo tree (plugins/tests/bin/.github/docs), so a broad new regex (e.g.
`\bexec\s*\(`) that newly matches the repo's own .js must match IDENTICALLY in
both impls. Verify it early. patterns.sh needs `+x` (lint-skills-agents gate) but
patterns.py stays non-exec.

**Single-line regex can't be defer-aware.** unclosed-handle anchors on `= open(`
so Python `with open()` self-excludes — but a following-line Go `defer f.Close()`
is invisible, so the handle STILL fires as a MEDIUM candidate (pass-2 resolves).
Don't claim boundary-awareness the regex lacks; pin the known-FP trade-offs
(`regex.exec()`, generic `.on()`) as positive fixtures so a future tightening is
deliberate.

**3-cycle adversarial review earned its keep here** (convergence 4→3→1 blocking):
cycle-1 partial (wall-ceiling stop, recovered via recover-journal-partials.sh);
cycles 2+3 full pipeline. Real integration gaps found that all local gates passed:
the MEDIUM-drop wiring bug, the missing `audit/lifecycle` label, the scanPrompt
third-site drift, the Go-defer doc overclaim. See [[issue-426-harness-rm-rf]] for
the read-only-review harness safety context. Wall-timeout: each cycle L3 got 1
extension to a 40-min ceiling; ~40min/cycle is normal for a 15-file diff.
