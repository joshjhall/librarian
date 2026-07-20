---
name: issue-426-harness-rm-rf
description: "#426 CRITICAL/large — read-only reviewer subagents could run destructive shell (rm -rf) against the LIVE tree; FULLY CLOSED (2026-07-20): belt+origin-lock PR #449 + PreToolUse bash-guard hook PR #450 (closed #448). Both #426 and #448 CLOSED."
metadata: 
  node_type: memory
  type: project
  originSessionId: de55e24b-986b-4be4-9eac-43fc9c6a1593
  modified: 2026-07-20T23:17:22.176Z
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

**#448 — PreToolUse bash-guard hook (MERGED PR #450 → main `09cd74e`, closed #448
AND #426, 2026-07-20, interactive).** The deferred tool-level enforcement for the
agents that resisted a simple allowlist (checker/audit-* run `bash patterns.sh`;
default orchestrate poll agent runs gh/glab/git):

- **Reusable CC hook fact (verified empirically, CC 2.1.215):** a PreToolUse hook
  gets JSON on stdin carrying snake_case `agent_id` + `agent_type` ONLY for a
  SUBAGENT Bash call; a main-session call has NO `agent_id`. Full schema:
  `session_id, transcript_path, cwd, prompt_id, permission_mode, effort,
  hook_event_name, tool_name, tool_input.command, tool_use_id` (+agent_* for
  subagents). Deny = exit-0 + JSON
  `{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
  permissionDecisionReason}}` (camelCase OUTPUT). To VERIFY the field: register a
  probe hook in ~/.claude/settings.json PreToolUse that `cat >> capture.jsonl`,
  trigger a subagent Bash call, inspect, then RESTORE settings. A plugin hook
  fires SESSION-WIDE (can't scope to subagents at the matcher level) → the script
  branches on agent_id itself.
- **Design (operator-locked):** fail-OPEN + loud stderr on parse failure (never
  false-block the main session's teardown rm; a permanent no-op is caught because
  the test asserts the positive-block path). Pure-bash fallback enforces w/o jq.
  Registered by adding a `PreToolUse`/`matcher:"Bash"` block to the EXISTING
  `plugins/workflow/hooks/hooks.json` (no manifest edit; `Hooks (2)` after).
  Template = golem-notify.sh but INVERTED exit contract (must be able to deny).
- **Tokenizer reality:** a regex/glob shell tokenizer is a PRAGMATIC 2nd layer,
  NOT a shell parser. FOUR adversarial rounds found 9 bypasses (5→2→2→1):
  separators incl bare `&`+newline, quoted/escaped heads `"rm"`/`\rm`, `/tmp/..`
  traversal + `*/tmp/*` substring, only-last-redirect, `-r` mis-skip, command-wide
  mktemp var (must bind to the EXACT `d=$(mktemp -d)` varname, statement-level
  split), compound keywords `if/then/case/while` (strip like env/sudo), git global
  opts `git -C <dir> clean`. Fixes cross-regressed → operator called "fix common,
  DOCUMENT exotic OOS" (indirection/xargs/eval/base64|sh/non-std-binaries). Don't
  chase convergence on a glob tokenizer; document the tail.
- **Gotchas hit:** typos gate blocks push on a regex-jargon abbreviation it reads
  as a misspelling (reword the comment); conform
  descriptionLength=72 (subject "PreToolUse Bash-guard blocks…" too long, shorten);
  check-ai-config hook-safety flags a guard's OWN `rm`/`git reset --hard` tokens +
  the `IFS=:` colon-parity differential tripwire ([[check-docs-staleness-ifs-colon-parity]])
  fires on a scanned comment line ending in `:` — reword comments to dodge both.

**Live-risk note:** while golems run pre-PR reviews against their worktrees, the

# 426 trigger is live but SPECIFIC (reviewer reproduces via a subdir with an

unresolved-`..` rm -rf) — rare enough not to halt the batch, but the reason to
prioritize #426 next.
