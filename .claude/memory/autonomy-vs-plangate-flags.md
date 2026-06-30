---
name: autonomy-vs-plangate-flags
description: next-issue has two orthogonal flag families — autonomy (--autonomous) vs plan-gate (--skip-plan); and three unrelated --auto spellings that must not be renamed
metadata:
  node_type: memory
  type: project
  originSessionId: 5ab6fd65-c6c6-433d-a590-2ec30160b58e
---

`/next-issue` + `/next-issue-ship` carry two **independent** flag families:

- **Autonomy** — run unattended to a PR. Flag: `--autonomous` (PR #72 / #22).
  `--auto` is a **deprecated alias** kept for one release. Also triggered by
  `NEXT_ISSUE_AUTONOMOUS=1`. Sets `autonomous: true` in the state file.
- **Plan-gate** — whether to keep the plan checkpoint. Flags: `--plan-gate`
  (alias `--no-skip-plan`) forces the checkpoint; `--force-auto` (alias
  `--skip-plan`, PR #68 / #20) skips it. On `severity/critical`, `--force-auto`
  needs a second consent `FORCE_AUTO_CRITICAL=1`.

A run can be autonomous AND plan-gated at once (medium+/critical issue running
unattended but pausing at the plan). Don't conflate the two — that's why #22
renamed `--auto`→`--autonomous` rather than the originally-suggested
`--skip-plan` (which #20 had since claimed for the plan-gate family).

**Three `--auto` spellings that are NOT the autonomy flag — never rename them:**
`gh pr merge --auto` (GitHub auto-merge), `--permission-mode auto` (Claude Code
harness flag), `/codebase-audit --auto-fix` (different skill).

Note: librarian intentionally did NOT relocate the containers `--auto` lint
invariants (they validate containers product content), so flag-name changes
here are docs + bundled scripts only — no test invariant gates them. See
[[conform-scope-enum]] for the commit-scope rules when touching these files.
