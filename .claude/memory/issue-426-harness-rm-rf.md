---
name: issue-426-harness-rm-rf
description: "#426 CRITICAL/large — read-only reviewer subagents can run destructive shell (rm -rf) against the LIVE tree; SHIPPED belt+origin-lock (interactive, 2026-07-20): 4 READONLY constants strengthened + code-reviewer Bash scope-locked + lint-readonly-harness.sh gate; deferred rest to #448"
metadata: 
  node_type: memory
  type: project
  originSessionId: de55e24b-986b-4be4-9eac-43fc9c6a1593
  modified: 2026-07-20T20:51:12.990Z
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

**MERGED PR #449 → main `3258263` (2026-07-20, squash + branch pruned, CI green
incl. the flaky quality-gates runner — no hang this time). Issue #426 kept OPEN
(status/in-progress removed, progress comment posted), closes when #448 lands.
Interactive with operator, scope = "belt + scope-lock code-reviewer":**

- Strengthened all 4 read-only prompt constants (destructive-shell ban +
  `mktemp -d` sandbox + canonicalize/no-`..`): ship-issue `READONLY`,
  code-reviewer `READONLY` (byte-identical twin), codebase-audit `READONLY`,
  orchestrate `READONLY_POLL`. Each fragment kept on its own `+`-concat line.
- **Tool-level lock on the ORIGIN agent only:** `code-reviewer.md` frontmatter
  Bash → per-subcommand read-only allowlist `Bash(git diff:*) Bash(git log:*)
  Bash(git show:*) Bash(git rev-parse:*) Bash(git ls-files:*) Bash(wc:*)`.
  Scoped-Bash IS honored by the runtime (proof: installed deslop-agent.md uses
  `Bash(git:*)`). Per-subcommand on purpose — `Bash(git:*)` would leave `git
  clean`/`reset --hard`/`checkout --` open.
- **Required companion:** `lint-skills-agents.sh` `test_agent_tool_values`
  exact-matched each comma-split token vs `VALID_TOOLS`, so a scoped token
  FAILED — fixed by stripping `(...)` suffix (`base="${tool%%(*}"`) before the
  membership check; added `test_agent_tool_values_guard`.
- Prose-only bans added to the DEFERRED agents (checker + 6 audit-* + light
  debugger) — they run `bash patterns.sh` so can't take a simple allowlist.
- **Regression gate:** new `tests/lint-readonly-harness.sh` (models
  lint-shell-portability.sh) awk-extracts each of the 4 const blocks and asserts
  fragments `git clean`/`mktemp -d`/`unresolved` present; wired into run-all.sh
  after the shell-portability stage. Full suite green (38 stages), packaging
  sanity-checked (code-reviewer still discovered w/ scoped tools).
- **Deferred → #448** (`type/feature`, Contributes to #426): tool-level lock for
  checker/audit-*/default-orchestrate-agent + a PreToolUse Bash-matcher sandbox
  hook (the fail-loud pre-execution guard #426 item 4). NOT closing #426 until

  #448 or an explicit operator call — the class isn't fully closed.

**Live-risk note:** while golems run pre-PR reviews against their worktrees, the

# 426 trigger is live but SPECIFIC (reviewer reproduces via a subdir with an

unresolved-`..` rm -rf) — rare enough not to halt the batch, but the reason to
prioritize #426 next.
