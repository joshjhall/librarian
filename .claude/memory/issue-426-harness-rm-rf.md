---
name: issue-426-harness-rm-rf
description: "#426 CRITICAL/large — read-only reviewer subagents can run destructive shell (rm -rf) against the LIVE tree; a ship-issue review deleted real .worktrees/ via unresolved `..`; HELD for interactive (you+me), NOT an autonomous golem"
metadata: 
  node_type: memory
  type: project
  originSessionId: de55e24b-986b-4be4-9eac-43fc9c6a1593
  modified: 2026-07-20T01:00:52.583Z
---

**#426 (severity/critical, effort/large, review-audit+workflow+security, type/bug)** —
a **read-only** reviewer subagent in ship-issue's adversarial pre-PR review
**deleted the host repo's real `.worktrees/`** by running `rm -rf` with an
unresolved `..` against the LIVE working tree while *reproducing* a bug
(ironically the very unresolved-`..` class it was reviewing). From a subdir,
`git rev-parse --git-common-dir` returns a RELATIVE path (`../../.git`);
`dirname` + `rm -rf "$root/.worktrees"` resolved `../..` to the real repo root.

**Root cause (class bug, not one-off):** the harness `READONLY` prompt enumerates
VCS/file mutations (edit/write/commit/branch/push) but says NOTHING about
destructive SHELL exec (`rm`, `git clean`, `mv`, `truncate`, `> file`), and never
confines reproduction to a scratch sandbox. So a Bash-capable "read-only" agent
can `rm -rf` the repo and be technically compliant. Same wording + same
reproduce-to-verify pattern across MULTIPLE harnesses/agents:

- `plugins/workflow/skills/ship-issue/workflow.js:376` (origin)
- `plugins/review-audit/skills/codebase-audit/workflow.js:391` (twin READONLY)
- `plugins/workflow/skills/orchestrate/workflow.js` + every Bash-capable
  review/analysis agent (audit-*, code-reviewer, checker, silent-failure-hunter…)

**Proposed direction:** (1) strengthen every READONLY prompt to ban destructive
shell + confine any reproduction to a fresh `mktemp -d` (never the working tree),
always canonicalize paths (`cd … && pwd`) before destructive ops; (2) PREFER a
tool-level guardrail over prose (read-only Bash allowlist, or wrap destructive
cmds with a target-resolves-under-$TMPDIR check) — prose alone is what failed;
(3) AUDIT the whole harness + Bash-capable-agent surface for the same exposure.

**DISPOSITION: HELD for interactive (operator decision 2026-07-19).** NOT an
autonomous golem — (a) critical caps at L3, (b) it edits the review harness every
golem's own pre-PR review depends on (a golem fixing its own reviewer is a
footgun), (c) safety-critical wants human eyes on plan AND diff. Same shape as
[[broker-inbox-gate-resolution]]'s #227 hold. In tracks.json `deferred`. Pick up
with the operator after the current throughput batch winds down.

**Live-risk note:** while golems run pre-PR reviews against their worktrees, the

# 426 trigger is live but SPECIFIC (reviewer reproduces via a subdir with an

unresolved-`..` rm -rf) — rare enough not to halt the batch, but the reason to
prioritize #426 next.
