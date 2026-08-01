---
name: review-wedge-root-cause
description: "Why golems keep wedging in unbounded ship-issue reviews (3× in one batch) — root cause is #307's wall-time bound being PROSE not code, compounded by a stale /opt install; filed as #327"
metadata:
  node_type: memory
  type: project
  originSessionId: 10478e43-b9c4-4a7c-a620-83c6efd01629
  modified: 2026-08-01T04:13:40.208Z
---

Golems repeatedly wedge in the `/ship-issue` pre-PR `next-issue-review` harness:
a spinning reviewer agent runs 20–50min / 200–300k sub-workflow tokens, golem
never opens a PR. Seen 3× in the batch-5 burndown (golem-266, golem-252,
golem-263) — each needed an orchestrator takeover (kill → commit any uncommitted
work → rebase → `run-all.sh` → push+PR).

**ROOT CAUSE (two layers), filed as #327:**

1. **The #307 wall-time bound is PROSE, not code.** #307 (`deaa769`) added
   `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` (20min +1 ext) but wired it in as
   skill-instruction TEXT in ship-issue's `.md` files — the model must *choose*
   to background-invoke the harness, poll `TaskOutput`, and `TaskStop` at the
   ceiling. No mechanical enforcement. A model deep in review doesn't reliably
   self-stop. Same class as the pre-0.6 `MAX_CYCLES`-in-prose cap-drift
   (observed live on golem-266). `git grep
   LIBRARIAN_WORKFLOW_WALL_TIMEOUT origin/main` → only `.md` +
   `recover-journal-partials.sh` (a recovery helper, not an enforcement path).
2. **Installed `/opt/librarian` (0.6.1) predates #307 entirely** — golems run the
   installed copy, which has neither the prose nor
   `recover-journal-partials.sh`. Needs the `sudo rsync` rebuild.

**Fix direction (#327):** make the bound a mechanically-enforced wrapper the
skill CALLS (like the `LIBRARIAN_CI_WAIT_TIMEOUT` loop), not a pattern it's told
to follow; + an orchestrator backstop (committed-but-no-PR after ceiling → ship
with recovered partials); + rebuild `/opt`.

**Takeover recipe that works (committed OR uncommitted work):** `tmux
kill-session golem-N`; if uncommitted changes exist, they're the golem's
pre-review refinements — commit them as a FRESH commit (NOT `git commit --amend`
— the auto-mode classifier denies amending a golem-authored commit as `[Git
Destructive]`); `git rebase origin/main` (disjoint → clean); `bash
tests/run-all.sh`; `git push --force-with-lease` + `gh pr create`. See
[[stale-base-squash-reverts-merged-pr]] for the rebase-safety pattern.

**SUPERSEDED — the old 15min/N-6-agents diagnostic is retired (issue #361, via
PR #369, merged).** The heuristic is now tracked prose, not this memory:
`plugins/workflow/skills/orchestrate/SKILL.md` Phase M § *Slow pre-PR reviews* +
`mode-protocol.md` § *Slow-review takeover contract*. Read those, not the
paragraph below. The recalibration (per the operator's #361 comment — batch-7 had
~75%+ false positives and **zero** confirmed-unrecoverable wedges): **default
never-kill / surface-and-wait**; a takeover is an operator OFFER only, gated on a
crashed/exited process (definitive on its own) OR a frozen TOP-LEVEL counter over
a **45–60min** window (not the old 15min); cross-golem corroboration required
**only in multi-golem batches** (inapplicable to a solo run); and the mandatory
pre-kill `gh pr list --head` check. Three follow-ups filed: #370 (Mode 3
container recipe), #371 (instrument the top-level counter — it's not
machine-observable today), #372 (SKILL.md bloat). See also
[[wall-timeout-decision-helper]].

**Original (retired) diagnostic, kept for context:** a WEDGE was flagged on
`next-issue-review N/6 agents` with the TOP-LEVEL token counter frozen (all
growth inside the sub-workflow) + committed work + no PR for >15min. This
over-fired — it conflated classifier-outage self-retry, a slow-but-completing
review, and top-level post-review work with a real wedge.

**ALWAYS `gh pr list --state open --head feature/issue-N` IMMEDIATELY BEFORE the
kill.** (batch-7 golem-328, 2026-07-16): a golem whose review is a genuinely slow
6-dimension harness can COMPLETE and open its PR in the exact window between the
takeover decision and the `tmux kill-session`. golem-328 self-reported "two
dimension reviewers still active ~22min in, waiting" (textbook borderline wedge)
— but had already pushed + opened PR #354 seconds before the kill. The kill was
harmless (PR was up, merged clean) but wasteful. A golem self-reporting a
slow-review WAIT + already-committed work is the highest-risk case for a
premature kill — re-check the open-PR set for its head branch as the last step
before killing. If a PR exists, skip the takeover entirely and just merge it.
