# Convention audit — the biweekly cadence

On-demand companion to `SKILL.md`. Load this when running the scheduled
convention sweep, or when checking what the `ship-issue` review stopped covering.

## Read this first: half of this is enforced, half is a ritual

The cadence is **split**, and the two halves have different guarantees. Do not
cite this page as evidence that convention coverage as a whole is guaranteed —
but it is no longer true that nothing runs (#907, landed 2026-09-05).

**The deterministic half RUNS on a schedule.**
`.github/workflows/ai-config-prescan.yml` — this repo's first scheduled workflow
— executes `check-ai-config`'s deterministic `patterns.py`/`patterns.sh` on the
1st and 15th of each month, plus `workflow_dispatch` on demand. It needs no LLM,
no credentials and no API spend, so it genuinely runs. It is a **ratchet**
against `tests/ai-config-prescan.baseline`: the 11 findings already in the tree
are recorded as known-and-deferred, and the job fails on the 12th. Its own
output says it covers the deterministic half only, so a green run cannot be
mistaken for a passing full sweep.

**The LLM-judgment half remains an operator ritual** — it still depends on a
human remembering it. A cron `.yml` **cannot invoke a Claude Code skill**, and
the alternative that could (a headless `claude -p`) has no auth path in CI
today: no `ANTHROPIC_*` secret and no `claude` invocation in any workflow, so it
would mean introducing credentials plus unbounded recurring spend. Rejected
on #907 as disproportionate. What stays manual is everything a detector cannot
model — cross-file consistency judgment, and the ad-hoc prose conventions
enumerated under **What nothing covers** below.

The naming follows from the same reasoning that kept #551 from adding a cron job
at all: the scheduled workflow is called an **ai-config pre-scan**, never a
convention audit, because a job named for the full sweep while performing only
its mechanical half is exactly the gate-header-claims-an-unimplemented-check
failure this repo has been bitten by before.

## The ritual

Cadence: **every two weeks.** This is the operator-run sweep — the half nothing
triggers. Run it by hand:

```text
/review-audit:codebase-audit categories=ai-config
```

The scheduled pre-scan is spelled `1,15 * *` (the 1st and 15th) rather than a
true fortnight, because GitHub cron cannot express "every 14 days" — it has no
interval field, only calendar matches. Twice monthly is ~14–16 days apart, close
enough for this purpose and stated here rather than rounded off. If you run the
manual sweep near those dates the deterministic findings will already be
reported; the value you add is the judgment half.

Pairs with **`check-ai-config`** via the `checker` agent (`model: sonnet`), not
the `audit-ai-config` agent (`model: opus`). That is the deliberate answer to
the #551 open question about whether the pairing is actually cheaper at
this cadence: the opus agent is the more thorough scanner, but the sonnet
`check-*` path keeps the replacement genuinely cheaper than the per-PR dimension
it replaces. Escalate to `audit-ai-config` only when a sweep surfaces something
that needs the deeper lens.

## What this covers

From `check-ai-config`'s own categories — but **the two halves do not reach the
same ones**, so read the marker before assuming the schedule has you covered:

- **sched** — reachable by the scheduled pre-scan (and deepened by the manual sweep)
- **manual only** — the scheduled job can *never* report this; only the sweep sees it

The scheduled job scans tracked `plugins/**/*.md` only, and three of
`check-ai-config`'s detectors gate on other filenames: `mcp-misconfiguration`
needs `*.json`, `hook-safety` needs `*.json`/`*.sh`, `harness-logic` needs
`*workflow.js`, and `claude-md-drift` needs a `CLAUDE.md`/`AGENTS.md` (this repo
keeps both at the root, outside `plugins/`). Those categories come back clean
from the schedule **by construction**, not because the tree is clean.

That narrowing is deliberate and measured, not an oversight: broadening the
corpus to 192 files raises the row count from 11 to 42, and **all 31 additional
rows are false positives** — `hook-safety` matching `rm -rf` inside comments and
inside `bash-guard.sh`'s own deny-list literals, and `mcp-misconfiguration`
flagging the `$schema` identifier of six JSON Schema files. Baselining 31 false
rows would train the reader to ignore the ledger, which costs more than the
coverage gains. `bin/ai-config-prescan.sh`'s header carries the full measurement
and the conditions for revisiting it.

- **manual only** — `claude-md-drift` — `CLAUDE.md` / `AGENTS.md` claims that no
  longer match the tree, including backtick-quoted relative paths that do not
  resolve. (Both files live at the repo root, outside the scanned `plugins/`.)
- **sched** — `config-inconsistency` — skill/agent markdown citing a
  `<plugin>:<name>` cross-reference that does not resolve
- **sched** — `agent-frontmatter` / `skill-frontmatter` — missing fields, wrong
  model tier for the task, write tools on a read-only agent, descriptions that do
  not match behavior. *This is the only category the schedule finds anything in
  today (the 11 baselined rows).*
- **manual only** — `mcp-misconfiguration` (needs `*.json`), `hook-safety`
  (needs `*.json` / `*.sh`)
- **manual only** — `harness-logic` — the `adversarial-review` bug-class
  checklist over `workflow.js` harnesses

## What the per-PR gates already cover

Do not re-check these in the sweep; they block merge on their own, every PR. The
authoritative table is in the `workflow` plugin's
`ship-issue/conventions-coverage.md` — in brief: `lint-shellcheck.sh`,
`lint-shell-portability.sh`, `lint-action-pins.sh`, `lint-skills-agents.sh`,
`lint-command-refs.sh`, `lint-worktree-recipes.sh`,
`lint-workflow-js-generated.sh`, `lint-prose-budget.sh`, `lint-python.sh`, and
`conform` on commit scopes.

## What nothing covers

- **Ad-hoc prose conventions in `CLAUDE.md` that no linter models** — a naming
  preference or "prefer X over Y" that lives only as a sentence. Neither the
  gates nor `check-ai-config`'s categories model it.
- **Cross-file consistency judgment against a live diff** — the demoted reviewer
  could see that a new file diverged from its siblings *in the change that
  introduced it*. An audit sees the tree, and sees it later.
- **Latency** — a violation caught biweekly may already sit in several merged
  PRs. This is why the demoted set was kept narrow.

This is not equivalent coverage and is not claimed to be. It is a cheaper,
later, tree-shaped substitute for a per-PR, diff-shaped reviewer, with the
mechanical majority left on the blocking gates where it belongs.
