# Mutation round — background-work adoption gate (#890)

Evidence for acceptance criterion **"Mutation round: neuter the registry lookup
and confirm the false-idle returns — a fixture that passes with and without the
fix proves nothing."** Recorded here because a mutation round is a claim about
what the suite *would* catch, and that claim is only checkable if someone can
re-run it.

Date: 2026-09-10. Tree: `feature/issue-890`.

## What this PR actually changed, and why the round is scoped to that

The #890 mechanism landed in two earlier PRs:

| PR | Half |
| --- | --- |
| #954 | the **classifier** — an unregistered background turn degrades to *indeterminate* rather than `idle` |
| #957 / #949 | the **registry** — `scripts/golem-work.sh`, its bounds, and the `background` class |

`work-registry-mutation-949.md` already carries the five-mutant round over the
registry itself (the two-knob boundary, numeric validation, the Signal A lookup,
the age bound, the dead-pid bound). Repeating it here would prove nothing new.

What this PR adds is the **third** thing, which is neither classifier nor
registry: whether the skills that *start* background work say so.
`golem/background-work.md` declared itself an "on-demand companion for `golem/`,
`next-issue/`, and `ship-issue/`" while `ship-issue/` referenced it **zero**
times — and `ship-issue` is where **all five** measured false-idles happened.

```text
$ grep -rn "background-work\|golem-work" plugins/workflow/skills/ship-issue/ | wc -l
0
```

The companion's own header *asserted* the adoption that did not exist. So the
round below mutates the **adoption gate**, `tests/lint-background-work-refs.sh`.

## Why the trigger is the bolded imperative — measured, not guessed

The first trigger drafted was the obvious one: any of `invoke|run|start|dispatch`
near a background-capable tool name. Measured across the four workflow skills, it
fired on **11 sections**:

```text
golem/background-work.md:4        # the protocol file itself
golem/background-work.md:66
orchestrate/SKILL.md:53           # <- 8 rows in orchestrate/
orchestrate/SKILL.md:320
orchestrate/merge-protocol.md:345
orchestrate/merge-protocol.md:530
orchestrate/mode-protocol.md:766
orchestrate/monitor-protocol.md:26
orchestrate/pool-train-protocol.md:58
orchestrate/pool-train-protocol.md:411
ship-issue/ci-review-protocol.md:129
ship-issue/ship-protocol.md:23    # a section ABOUT the permission question
```

Eight of the eleven are `orchestrate/`, which is the **observer** of golem
background work — it reads the registry rather than writing it. Demanding
registration there would make the gate assert something false, and a lens that
fires on sections nobody can fix is a lens that gets turned off. `ship-protocol.md`
§ *Workflow authority* is the same problem from the other side: a section that
*discusses* the harness and invokes nothing.

Narrowing to the **bolded imperative** (`**Invoke the \`Workflow\` tool**`,
`**Run** the \`Workflow\` tool`, `Invoke it as a background task`,
`run_in_background`) left exactly the real sites — and `test_negative_case_fires`
pins the narrowness half explicitly, so a future widening that swept
`orchestrate/` back in fails rather than silently nagging.

**The narrowing also found a site the manual sweep missed.** With the tightened
trigger, `ci-review-protocol.md:129` still fired — the **ci-fixer** harness,
whose prose says *"Invoke it as a background task"* verbatim. That is a genuine
fourth background site, and it was not in the plan's file list. The gate found it
before review did.

## Results

Three mutants, three classes, each applied alone to an otherwise-clean tree.
(The registry's own lookup, age bound and dead-pid bound are #949's M3/M4/M5 —
already measured in `work-registry-mutation-949.md`, not repeated here.)

| # | Class | Mutation | Result |
| - | ----- | -------- | ------ |
| M1 | The satisfier lookup | `named = 1` → `if (0) named = 1` (both arms) | **5 tests red** |
| M2 | Section scoping | Revert the adoption at `pre-ship-validation.md` only | **exactly 1 test red** |
| M3 | The two-line window | `two = sec[i] " " sec[i+1]` → `two = sec[i]` | **1 test red** |

### M1 — the satisfier lookup

The question this asks: *is the gate measuring adoption, or something
incidental?* Neuter the satisfier and every adopted section must go red.

```text
  scan_file flags unregistered sites and honors every satisfier   ... FAIL
  plugins/workflow/skills/golem/SKILL.md                          ... FAIL
  plugins/workflow/skills/next-issue/SKILL.md                     ... FAIL
  plugins/workflow/skills/ship-issue/ci-review-protocol.md        ... FAIL
  plugins/workflow/skills/ship-issue/pre-ship-validation.md       ... FAIL

  Total: 27   Passed: 22   Failed: 5
```

All four files carrying a registration pointer go red, plus the fixture test.
Control (unmutated): `27 passed, 0 failed`.

### M2 — section scoping

The question: *is section scope real, or is a satisfier anywhere in a 660-line
file discharging every trigger in it?* Revert **one** site and exactly that file
must fail.

```text
  plugins/workflow/skills/ship-issue/pre-ship-validation.md ... FAIL

  Total: 27   Passed: 26   Failed: 1
```

One file, not four and not zero. A whole-file rule would have passed this mutant:
`pre-ship-validation.md` is 666 lines and the other sections in it are untouched.

### M3 — the two-line window

The question: *is the window load-bearing, or decoration?* Collapse it to one
line at a time and the wrapped-trigger fixture must fail.

```text
  A trigger wrapped across two lines is detected (not single-line) ... FAIL

  Total: 27   Passed: 26   Failed: 1
```

This is the tautological-gate guard `lint-harness-refs.sh` documents: a
single-line matcher is green before the fix and green after.

## Two defects the round found in the gate itself

Both surfaced while the gate was being written, and both are the
strictness-first shape — *a finer gate's first findings are its own parser bugs*.

1. **The wrapped-join regex.** `**Invoke the \`Workflow\` tool**` was written with
   literal spaces. A wrapped join preserves the continuation line's indent, so
   the joined text reads `**Invoke the` + `    \`Workflow\` tool**` — four spaces,
   not one — and the trigger did not match its own fixture. Fixed to
   `[[:space:]]+` between every word, in **both** the awk trigger and the
   fixture-guard grep (leaving the guard behind would have made it stop proving
   "no single line matches" about the regex the scan actually uses).

2. **The line-attribution heuristic.** It keyed on the word `Workflow` to decide
   which of the two joined lines to report. On a wrapped match the *first* line
   holds `**Invoke the` and `Workflow` lands on the **second**, so the violation
   pointed at the continuation line while the author's eye is on the line that
   opens the trigger. Re-keyed to the trigger's opening token.

Neither would have been caught by a gate that only ran against the real corpus:
the real corpus has no wrapped trigger today. The fixture is what found them.

## What the gate covers, and what it does not

Six files were edited; the gate arms on **four**. Stated explicitly so a reader
does not assume the other two are protected:

| file | gated? | why |
| --- | --- | --- |
| `pre-ship-validation.md` | **yes** | bolded `**Invoke the \`Workflow\` tool**` |
| `ci-review-protocol.md` | **yes** | two sites — the multi-cycle loop and the ci-fixer's "Invoke it as a background task" |
| `golem/SKILL.md` | **yes** | pre-existing, armed by its own trigger |
| `next-issue/SKILL.md` | **yes** | pre-existing, armed by its own trigger |
| `ship-issue/SKILL.md` | no | a one-line summary pointing at Step 3.5; it describes the harness rather than issuing the invocation |
| `execute-protocol.md` | no | `git push` is only background work **if** you background it — a conditional site, not a mandatory one |

This is verifiable rather than asserted: **M1 turned exactly the four gated files
red** and left the other two green. The two ungated additions are useful prose,
not enforced contract — a future edit could remove them silently. That is the
correct trade: extending the trigger to cover `git push` would fire on every
mention of pushing in the corpus, which is the over-trigger failure the
measurement above rejected.

## A/B: what adoption actually buys an operator

The gate proves the prose is right. This proves the prose *matters* — the
operator-visible difference between a registered and an unregistered background
turn, on the same transcript. Both directions are pinned as a test pair in
`tests/golem-scripts/90-transcript-liveness.sh`:

| fixture | registry | `golem-transcript-liveness.sh` |
| --- | --- | --- |
| `Workflow` → `end_turn` | one open item | exit 0, `background` → renders `alive, working (background: 1 item)` |
| `Workflow` → `end_turn` | empty | exit 2, indeterminate → falls back to the mtime heartbeat |
| ordinary tool → `end_turn` | empty | `idle` (unchanged — the signal the column exists for) |

Registration **upgrades** the verdict from *don't know* to *definitely working*.
Row 2 is not a bug — #954 made it safe — but it costs the orchestrator the
signal, because a heartbeat cannot distinguish *working* from *parked*. That is
most of what the liveness column is for, and it is precisely the automation
the #890 "Why it matters" section says is blocked.

## Cycle 1 of the adversarial review: three blocking findings

The mutation round above was run BEFORE the review. The review then returned
**three blocking findings**, two of them in code the mutants had exercised — which
is the argument for the review being a separate gate rather than a redundant one,
restated with fresh evidence.

### B1 — line attribution keyed off a loose keyword (HIGH, reproduced)

The window joins two lines, so a match visible only in the join has three possible
sites. Attribution chose between them with a bare `/[Ii]nvoke/` test, which claims
any first line merely containing *invoked* / *invoking* / *revoke* while the real,
unwrapped trigger sits wholly on the second. Reproduced independently before
fixing:

```text
## Red herring above the trigger
We already invoked the setup earlier for context.
   b. **Invoke the `Workflow` tool** with the bundled script.

  before: 2:## Red herring above the trigger   <- unrelated prose blamed
  after:  3:## Red herring above the trigger   <- the actual trigger line
```

Fixed by factoring the trigger into ONE `trigger_on()` predicate used both to
detect and to attribute — they can no longer disagree — plus an explicit
three-case branch whose **order is load-bearing** (a trailing-line match and a
genuine wrap are indistinguishable from the join alone, so the trailing case must
be tested first). `test_line_attribution_picks_the_trigger_line` pins all three
cases together, and reverting to the loose keyword turns it red.

Note what my own mutation round missed here: M1–M3 targeted the satisfier lookup,
section scope, and the window. Attribution was a **fourth** class I had not
thought to mutate — and I had already *fixed* an attribution bug during
development, which is exactly the blind spot. Having debugged one instance made
the code feel settled.

### B2 — a failed scan read as "clean" (MEDIUM)

`scan_file` ended `awk … 2>/dev/null || true`, folding an awk **runtime** failure
into the same empty output as a clean file. The 77 sentinel covers an *absent*
awk; nothing covered a *present* awk that failed on a particular file. That is the
per-file arm of the #538/#571 silence-reads-as-a-pass rule.

Now runs awk to a temp file so the status is awk's own (a `while read` fed by a
process substitution discards it), sets `CUR_SCAN_ERR`, and the per-file test
**fails** with `SCAN DID NOT RUN` rather than passing.
`test_scan_failure_is_loud_not_clean` drives it by breaking `SCAN_AWK` itself, with
a control proving the fixture is otherwise scannable.

### B3 — bare `golem-work.sh` in three of the new pointers (MEDIUM)

The adopted pointers showed a path-less `golem-work.sh register …` while every
other recipe in the same worktree-isolated files uses
`<skill-base-dir>/../../scripts/…`. A bare `golem-work.sh` is **not on PATH** — it
is a bundled plugin script — so a golem copying the parenthetical literally gets
`command not found` and never registers. Soft failure (the verdict degrades to
indeterminate rather than idle), but it silently loses precisely the signal this
PR exists to add.

**Independently confirmed while shipping this PR**: registering the pre-push suite
by hand, I reached for `register --worktree`, which `register` refuses (`--worktree`
is an *observer* flag on `count`/`list`). The docs were right and my invocation was
wrong — which is the same class of error B3 predicts a reader will make. Both the
flag split and the runnable recipes are now stated explicitly.

## What this round does NOT prove

The same limit `work-registry-mutation-949.md` records, restated because it
applies again: **a mutation round proves the tests catch the failures you thought
of, and says nothing about the ones you did not.** #949's five mutants missed a
real HIGH defect in `work_open_items_nojq` that the adversarial review found,
because that defect was in a class the issue never named. The three mutants above
target the classes *this* gate was built around — satisfier lookup, section
scope, the wrap window. The adversarial review is a separate gate, not a
redundant one.
