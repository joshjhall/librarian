# Convention audit — the biweekly cadence

On-demand companion to `SKILL.md`. Load this when running the scheduled
convention sweep, or when checking what the `ship-issue` review stopped covering.

## Read this first: the cadence is unenforced by construction

**Nothing makes this run.** This repo has **no scheduled workflow at all** —
verified on 2026-09-04: `ci.yml` and `code-scanning.yml` trigger on
`push` / `pull_request` / `workflow_dispatch`, `release.yml` on a semver tag, and
none of the three carries a `schedule:` key.

So of AC#2's "equivalent coverage runs on a documented scheduled cadence", the
**documented** half is satisfied by this file and the **scheduled** half is not
satisfied by anything. This is an operator ritual that depends on a human
remembering it.

That is a deliberate choice over the alternative, not an oversight: a cron
`.yml` **cannot invoke a Claude Code skill**, so a scheduled job here could only
re-run the deterministic linters that already gate every PR — a workflow whose
name claims a convention audit while performing none. A gate header claiming an
unimplemented check is the failure mode this repo has been bitten by before.

The enforcement gap is tracked in **#907**. Until it is closed, treat this
page as a checklist someone must pick up, and do not cite it as evidence that
convention coverage is guaranteed.

## The ritual

Cadence: **every two weeks.**

```text
/review-audit:codebase-audit categories=ai-config
```

Pairs with **`check-ai-config`** via the `checker` agent (`model: sonnet`), not
the `audit-ai-config` agent (`model: opus`). That is the deliberate answer to
the #551 open question about whether the pairing is actually cheaper at
this cadence: the opus agent is the more thorough scanner, but the sonnet
`check-*` path keeps the replacement genuinely cheaper than the per-PR dimension
it replaces. Escalate to `audit-ai-config` only when a sweep surfaces something
that needs the deeper lens.

## What this covers

From `check-ai-config`'s own categories:

- `claude-md-drift` — `CLAUDE.md` / `AGENTS.md` claims that no longer match the
  tree, including backtick-quoted relative paths that do not resolve
- `config-inconsistency` — skill/agent markdown citing a `<plugin>:<name>`
  cross-reference that does not resolve
- `agent-frontmatter` / `skill-frontmatter` — missing fields, wrong model tier
  for the task, write tools on a read-only agent, descriptions that do not match
  behavior
- `mcp-misconfiguration`, `hook-safety`
- `harness-logic` — the `adversarial-review` bug-class checklist over
  `workflow.js` harnesses

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
