# Mutation round — background-work registry (#949)

Evidence for the acceptance criterion **"Mutation round per defect class, not per
test."** Recorded here because a mutation round is a claim about what the suite
*would* catch, and that claim is only checkable if someone can re-run it.

Date: 2026-09-06. Tree: `feature/issue-949`.

## Why per-class

Issue #949 exists because the registry regenerated **one bug class three times**, each
instance in a config or input shape the fixtures did not express, and each
producing the same symptom — a working golem reported `idle`. A mutant per *test*
would say nothing about that; a mutant per *defect class* asks the only question
that matters: **if this defect came back, would anything go red?**

Five mutants, five classes. Each was applied alone, to an otherwise-clean tree.

## Results

| # | Class | Mutation | Result |
| - | ----- | -------- | ------ |
| M1 | Two-knob boundary (defects 1+2) | `work_status_dir_for_worktree`: replace the `--git-common-dir` derivation with the withdrawn grandparent assumption `dirname(dirname(wt))` | **3 tests red** |
| M2 | Numeric validation (defects 3+4) | `work_valid_positive_int`: drop the `0*)` padded clause, leaving the literal `0)` string guard that shipped and failed | **bug resurrected** |
| M3 | Signal A lookup | `work_says_background`: `return 1` unconditionally | **verdict regressed** |
| M4 | Age bound | Strip the `started_epoch`/`max_age` filter from the jq reduction | **bug resurrected** |
| M5 | Dead-pid bound | `work_reap_dead_pids`: `if ! kill -0 …` → `if false` | **bug resurrected** |

### M1 — the two-knob boundary

Full suite under the mutant, `tests/validate-golem-scripts.sh`:

```text
Failed:  3
  golem-transcript-liveness: background resolves across BOTH env knobs (#949)  [90-transcript-liveness.sh] ... FAIL
  golem-work: an observer reads the subject across BOTH env knobs (#949)       [95-work-registry.sh] ... FAIL
  golem-work: writer and observer resolve the same registry file (#949)        [95-work-registry.sh] ... FAIL
```

Exactly the three cases that cross the knobs, and they span **both** halves — the
registry's own contract and the classifier's use of it.

> **A process note worth keeping.** The first M1 run appeared to show **0**
> failures. That reading was wrong: the log was captured from a run that had not
> yet reached the `#949` cases, so "0 FAILs" meant *not yet executed*, not
> *mutant survived*. It was caught only because a direct A/B (below) had already
> shown the mutant changing behavior, so a green suite was a contradiction rather
> than a relief. **Absence of failures in a partial log is not evidence** — the
> same silence-reads-as-a-pass shape this repo keeps filing issues about.

### M2 — numeric validation

Direct A/B, `register --pid <spelling>` (exit 0 = accepted):

```text
                 good    mutant
  --pid 0        rc=2    rc=2       <- the one spelling the string guard caught
  --pid 00       rc=2    rc=0  <-- bug resurrected
  --pid 007      rc=2    rc=0  <-- bug resurrected
  --pid 42       rc=0    rc=0
```

This is the withdrawn defect exactly: `case "$pid" in 0)` is a **string** compare,
so `00` and `000` sail past it — and `kill -0 00` signals the caller's process
group just as `kill -0 0` does, so the entry can never be reaped.

### M3 — the Signal A lookup

Same transcript (a `Workflow` call then an `end_turn`) with one open registration:

```text
  good:    background   (exit 0)
  mutant:  exit 2 — "turn ended after a background-capable tool … indeterminate"
```

The upgrade is gone and the verdict falls back to Signal B. Note what this
mutant does **not** do: it never produces `idle`. That is the two-signal design
working — neutering the explicit half degrades the answer, it does not corrupt it.

### M4 — the age bound

A 2-hour-old entry (`GOLEM_WORK_MAX_AGE` default 3600), no pid, so only the age
bound can drop it:

```text
  good:   count = 0
  mutant: count = 1   <-- a leaked entry pins the golem to `working`
```

### M5 — the dead-pid bound

An entry whose pid was spawned and reaped, so it is certainly gone:

```text
  good:   count = 0
  mutant: count = 1   <-- a crashed job never self-heals
```

## A flaky test the full suite caught (and what it cost to find)

Between the mutation round and shipping, a full run went **340/341** — one
failure in `test_work_dead_pid_is_reaped`:

```text
  golem-work: bound 1 — an entry whose pid is gone is reaped on read (#949) ... FAIL
      Expected: '0'
      Actual:   '1'
```

It had passed the three previous full runs. The cause was in the **fixture**,
not the code: `(exit 0) & dead=$!; wait "$dead"` asserts an OS fact the test does
not control — "this pid is gone" — and under a suite that forks thousands of
processes the number can answer `kill -0` again by the time the assertion reads
it. Fixed by verifying the precondition instead of assuming it (`dead_pid` /
`live_pid` in `tests/lib/golem-sandbox.sh`: allocate, confirm, bounded retry,
else `skip_test`).

**Why this one mattered more than an ordinary flake.** The test guards a
**bound**. A red run reads as "the reaper is broken" and a green run as "the
reaper works" — when on a flaky fixture neither was actually measured. The two
live-pid cases had the mirror weakness and were hardened with it; in the age-out
case an unstarted child would have reaped the entry for the *wrong reason*,
passing while asserting nothing about age.

The general lesson, which is the same one the mutation round teaches: **a test
that depends on an unchecked precondition is not testing what its name says.**

## What the adversarial review found that the mutation round did not

Review cycle 1 returned a **HIGH blocking correctness defect** in
`work_open_items_nojq`, reproduced independently before fixing:

```text
  registered: work-…-7da2 (COMPLETED), work-…-1171 (should remain open)
  jq path:    work-…-1171  two      <- correct
  no-jq path: work-…-7da2  one      <- the COMPLETED item, open one dropped
```

The dedup loop set `IFS=$'\n'` for `set -- $oldrecs` and restored it only *after*
the following `for keep_id in $oldids` loop — but `$ids` is **space**-delimited,
so with IFS newline-only it never word-split: every id arrived as one iteration,
`$i` desynchronized from the positional records, and the accumulator corrupted
for any registry with 2+ lines. Both failure directions are the bug this feature
exists to prevent: an open item vanishing reads as "nothing open" → `idle`, and a
completed item surviving pins a false `background`.

**Why five mutants missed it.** They targeted the *defect classes the issue
named* — the two-knob boundary and numeric validation. This was a third class the
issue did not name, in a code path the withdrawn version never had reviewed. A
mutation round proves the tests catch the failures *you thought of*; it says
nothing about the ones you did not. That is the argument for the adversarial
review being a separate gate rather than a redundant one.

**Why the suite was green through it.** `test_work_nojq_read_matches_jq_read`
registered two items, completed none, and asserted only `count`. The reduction's
dedup loop only runs when a slot must be *dropped*, so a fixture with no
`complete` never entered it — and count parity held even while identities were
swapped. Same-number is not same-answer. The test now uses three registers plus a
complete and asserts **which** items each reader reports.

Two further hardenings came out of the same cycle:

- **The no-jq bounds were untested.** Every bound test called `run_work`, which
  leaves PATH intact and so exercised only the jq arm — in exactly the
  stripped-PATH environment the header calls a "full peer, not a degraded stub".
  Added `test_work_nojq_bounds_match_jq_bounds`.
- **A dangling flag collapsed to a default.** `--pid` with no value fell to
  `${1:-}` = `""`, indistinguishable from "never passed", so the entry registered
  with no pid and silently lost the dead-pid bound. Nine sites shared the shape;
  `--worktree` was the sharpest, since collapsing it makes an *observer* resolve
  ambiently and print a well-formed `0` that renders as `idle`. All nine now
  refuse loudly, and `cmd_count`'s fail-soft contract gained an explicit
  malformed-invocation-vs-runtime-condition boundary.

## Cycle 2: converged, and one finding about the cycle-1 fix itself

Cycle 2 reviewed the fix delta and returned **zero blocking findings** — the loop
converged. Its most useful finding was about the *fix*, not the original code:

> The cycle-1 hardening routed 8 of 9 dangling-flag sites through the new
> `require_flag_value` helper but hand-rolled the identical shape inline at the
> other two (`--pid`, `--max-age`), leaving two independent implementations of
> one invariant — and two different message shapes for the same class of error.

That is the same **harden-one-knob-and-the-sibling-stays-exposed** pattern the
hardening existed to close, reintroduced *by the fix for it*. Worth recording as
its own lesson: a fix that generalizes a guard should route every site through
the generalization, or the next change to the contract will look complete while
leaving a stale twin behind. All ten sites now share one helper, and the message
carries the subcommand.

Four coverage findings were also taken rather than deferred, since each named a
branch of new code that no test entered: `cmd_complete`'s id validation,
`cmd_list`'s stray-positional rejection, `work_compact`'s truncation, and
`--status-dir` used standalone plus its documented precedence over `--worktree`
(a comment asserting behavior nothing measured).

**A mutation note on the last one.** Its first mutant *passed*, which looked like
a vacuous test. It was not — the mutation had been applied to `cmd_list` while
the test drives `cmd_count`. Re-run against the right function, it fails as
intended. Recorded because the failure mode is worth naming: **a mutant that
lands outside the code under test proves nothing in either direction**, and read
carelessly it retires a good test.

## Reproducing

M1 and M3 need the full suite (they are wiring-level). M2, M4, and M5 are visible
in seconds via a direct A/B: copy `golem-work.sh` **and its `config.sh` sibling**
into a scratch dir (the script sources `config.sh` from its own directory — a copy
without it fails for an unrelated reason and reads as a false "rejected"), apply
the mutation, and compare `count` against a planted registry.

Unset `GOLEM_ID` and `AGENT_ID` in every probe: this suite may itself run inside a
live golem, and an inherited id makes the probe assert the runner's identity
rather than the code's derivation.
