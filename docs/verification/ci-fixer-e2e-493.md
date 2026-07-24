# `ci-fixer` classify-hoist verification — issue #493

Tracks the acceptance criteria of
[#493](https://github.com/joshjhall/librarian/issues/493)
("ci-fixer: hoist the classify agent out of the retry loop"). The change
**memoizes** the classify (parse) agent inside the per-check `while` loop in
`plugins/workflow/agents/ci-fixer/workflow.js` so a successful classification is
computed once and reused across all fix/verify attempts, instead of re-running
classify once per attempt.

## Design: memoized classify, not a full hoist

Classification is cached in a `let cls = null` declared above the loop and
computed inside it under `if (!cls)`. This runs classify **at most once** on the
happy path (the issue's goal) while preserving the pre-existing transient
semantics **exactly**: a classify that returns `null` is deliberately **not**
cached — an `agent()` call is not deterministic, so a null can be a transient
parse/schema hiccup rather than proof the logs are unclassifiable — so it flows
through `transientVerdict`/`applyResult` and is retried up to `MAX` just as
before, and it stays gated behind the `BUDGET_FLOOR` guard (a near-empty budget
skips the whole attempt, classify included). A full hoist above the loop was
rejected precisely because it would have changed both of those behaviors
(zero-retry on a transient null, and an un-budget-gated classify) — a
behavior change beyond the issue's mechanical scope.

## Summary

| AC | What it proves | Status |
| --- | --- | --- |
| AC#1 — classify runs once per check, not once per iteration | classify memoized under `needsClassify(cls)`; single `agent(parsePrompt(...))` call site; `parsePrompt` arity 2 → 1; `needsClassify` unit-tested | **VERIFIED — unit + code-trace** this PR |
| AC#2 — fix/verify still run per iteration with the shared classification | loop body retains `fixPrompt`/`verifyPrompt(check, cls, iteration)` fed the memoized `cls` | **VERIFIED — code-trace** this PR |
| AC#3 — behavior equivalent on a fixture CI failure | loop body byte-identical to pre-change except the `needsClassify(cls)` classify guard; transient-null retry, `BUDGET_FLOOR` gating, and harness-error handling all unchanged; loop-control + `needsClassify` helper unit tests green | **PARTIAL — code-trace + unit**; no live fixture (two-runtime) |

Two verification strengths are distinguished: **unit** (a pure helper exercised
this run against real code paths) vs **code-trace** (the orchestration body read
and confirmed, but not executed — the `workflow.js` engine is sandboxed and
cannot run in-session; see the two-runtime model in `CLAUDE.md`).

## Why the orchestration loop is code-trace, not live

The change restructures the `parallel(checks.map(...))` per-check closure, whose
`agent(...)` calls only run inside the Workflow-tool engine. That engine has no
shell/fs and can't be driven from a plain session, so the classify-once loop is
verified by reading the code path, not by observing agents fire. The pure
surfaces of the change — `parsePrompt` (iteration-independent) and
`needsClassify` (the memoization decision) — **are** exercised directly in
`tests/validate-workflow-helpers.mjs`.

**AC#3 is therefore PARTIAL, not fully live.** The issue's third criterion —
"behavior equivalent on a fixture CI failure" — is satisfied by the two-part
argument that (a) the loop body is byte-identical to the pre-change code except
the `needsClassify(cls)` classify guard, so transient-null retry, `BUDGET_FLOOR`
gating, and harness-error handling are provably unchanged, and (b) the extracted
`needsClassify` memoization decision is unit-tested. It is **not** confirmed by
driving a real fixture `check` through the harness end-to-end — the two-runtime
constraint makes that impossible in-session, and it is left as a live spot-check
for a follow-up rather than claimed here.

## Code-path trace (post-change)

Per-check closure in `plugins/workflow/agents/ci-fixer/workflow.js`:

1. `let verdict = defaultVerdict(check)`; `let cls = null` (the memo) above the loop.
2. `while (iteration < MAX && !verdict.fixed)` — after the `BUDGET_FLOOR` guard and
   `iteration++`, inside the existing `try`:
   - **`if (needsClassify(cls))` → classify** via the single
     `agent(parsePrompt(check), …)`. On the first iteration `cls` is null so
     classify runs; a **successful** result is stored in `cls` and reused on every
     later iteration (classify does not run again). A **null** result is left
     uncached, so the next iteration re-enters this branch — the pre-existing
     transient-retry semantics, unchanged.
   - `if (cls)` → `fixPrompt(check, cls, iteration)`.
   - `if (!cls)` → `transientVerdict(check, cls, fix)` (skip verify, retry next
     iter); else `verifyPrompt(check, iteration)` → `wrapVerify(v, check, cls, fix)`.
   - `catch (e)` → the unchanged harness-error verdict + `break`.
   - `applyResult(verdict, result)` / `step.stop`.

There is exactly **one** `agent(parsePrompt(...))` call site, guarded by
`needsClassify(cls)`; its `parse:${check.name}#${iteration}` label keeps the
iteration suffix (as the sibling fix/verify calls do) so each genuine invocation
on the transient-null retry path has a unique journal key for resume. Everything
else in the loop body is byte-identical to the pre-change code.

### Agent-count impact

Per check, worst case (all `MAX = 3` attempts, none fixing, classify succeeding):

- **Before:** `3 × (classify + fix + verify)` = 9 agents (2 redundant classifies).
- **After:** `1 classify + 3 × (fix + verify)` = 7 agents.

The `MAX - 1` redundant classify agents per successfully-classified check are
eliminated, across every check fanned in parallel. (A check whose classify
transiently returns null still retries classify next iteration — identical to the
old behavior, no attempts forfeited.)

## Unit evidence

`tests/validate-workflow-helpers.mjs`, ci-fixer block:

- `parsePrompt.length === 1` — the `iteration` parameter is gone (AC#1).
- `parsePrompt(check)` output contains no `attempt` framing, embeds the failure
  logs, and interpolates `check.name`/`check.pr` — classification is a single,
  iteration-independent step (AC#1).
- `needsClassify(null)` / `needsClassify(undefined)` → `true` (classify / retry a
  transient null) and `needsClassify({…})` → `false` (reuse the memoized result) —
  the memoization decision that drops the `MAX-1` redundant classifies (AC#1),
  and, by leaving a null uncached, keeps the transient-retry behavior equivalent
  (AC#3).
- `defaultVerdict` / `transientVerdict` / `applyResult` / `wrapVerify` assertions
  are unchanged and green — the loop-control fold (#259) is untouched, so
  per-iteration fix/verify behavior is equivalent (AC#2, AC#3).

Full suite: `node tests/validate-workflow-helpers.mjs` → all assertions pass;
`node --check` on the harness passes; `bash tests/run-all.sh` mirrors CI.
