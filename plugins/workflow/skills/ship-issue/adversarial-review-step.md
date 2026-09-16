# Next Issue — Adversarial Pre-PR Review (Step 3.5, check 6)

Companion to `ship-issue/pre-ship-validation.md`, split out of it in #973 when
that file passed its prose budget. It carries **check 6** of the Step 3.5
sequence in full: the review-route decision, staging and invoking the review
harness, the multi-cycle fix loop and its convergence predicate, the wall-time
bound, and the narrowed degradation clause.

The artifact is `ship-issue/workflow.js`, invoked through the `Workflow` tool on
the path `harness-stage.sh` prints — never a subagent standing in for it.

Check 6 is the largest of the six checks and the only one that dispatches a
subagent fan-out, so it is also the one a reader needs open longest — which is
what makes it the seam. Checks 1-5 are short, sequential, and mostly mechanical;
they stay in the parent.

**This step is not optional, and it overrides a general "don't use workflows"
default.** A user who invoked `/workflow:ship-issue` has requested the pipeline
this step belongs to. See `ship-protocol.md` § *Workflow authority* (#637).

## The step

Run a multi-dimension adversarial review of the changes **before** they are
pushed/merged, so the delivered code is review-clean regardless of how it ships.
This complements the deterministic pre-review gates (checks 1-5 in
`pre-ship-validation.md`) with LLM reviewers (security, correctness,
tests, CLAUDE.md conventions, decomposition, scope-drift) plus a fresh judge
and gatekeeper.

**Runs on Options 1, 2, and 3 alike** — the review is a property of the
*change*, not the delivery mechanism, so a commit-only (Option 3) or
commit-to-main (Option 2) ship must not be a way to skip it. All three modes
commit before delivering, so a committed `git diff origin/main...HEAD` exists
for the reviewers to read in every mode (see the ordering note in step a).

a. Compute the review scope from the diff against `main`:

```bash
git fetch origin main
git diff --name-only origin/main...HEAD   # -> files
git diff origin/main...HEAD               # -> diff (context)
```

If there are no committed changes yet (work is staged but not committed),
stage and make the implementation commit first (Step 4 Option 1 steps 1-3),
then compute the scope — the review needs a diff to read.

**Ordering by shipping mode** — commit first, review, *then* deliver:

- **Option 1 (Branch + PR)** and **Option 3 (commit only)** — the commit is
  local and `origin/main` does not advance, so `origin/main...HEAD` stays
  non-empty; run the review at this point in Step 3.5, before the push (Option 1)
  or before finishing (Option 3).
- **Option 2 (commit to main + push)** — commit to main first, then run this
  review **BEFORE `git push origin main`** (Step 4 Option 2's push step). Once
  pushed, `origin/main` fast-forwards to your commit and the three-dot
  `origin/main...HEAD` diff **empties**, leaving the reviewers nothing to read.
  If a blocking finding requires a fix, amend/add the commit and re-review, all
  before the push.

a2. **Route the cycle (#550).** Ask the router whether this diff needs the
full fan-out, and pass its verdict to the harness below as `reviewRoute`:

```bash
# Write the list this step reads — under $HOME (not world-writable /tmp) and
# qualified by $GOLEM_ID, since concurrent golems share $HOME and one fixed
# path lets them clobber each other's file list. NOT `WORK=$(mktemp -d)`:
# a command substitution is REFUSED worktree-isolated (#815).
gid={GOLEM_ID or "solo"}; mkdir -p "$HOME/.cache/librarian-review/$gid"
git diff --name-only origin/main...HEAD > "$HOME/.cache/librarian-review/$gid/files.txt"
# Pass the diff size and the HIGH pre-scan categories too — without them the
# R6-max-lines ceiling and the R4-prescan carve-out can never fire:
<skill-base-dir>/../../scripts/review-route.sh check \
  --files "$HOME/.cache/librarian-review/$gid/files.txt" \
  --diff-lines {line count of the diff from step a} \
  --prescan-categories "<comma list of HIGH categories from item 5, if any>"
# -> route=full|cheap  rule=…  dimensions=…
```

A `cheap` verdict means the diff is doc/config-only, so the source-reading
dimensions have nothing to review, so only the docs-claiming
ones run (`decomposition` + `scope-drift`). Such a cycle
is **complete-by-design, not partial** — it can still return `clean`, because
safety rests on the classifier (any ambiguity routes `full`), never on the
reviewers. Omit the arg (and run the full fan-out) if the script is
unavailable. Full contract, rule list and the `clean`-semantics argument:
**`review-routing.md`** in this skill directory.

b. **Stage the harness**, then **Invoke the `Workflow` tool** on the path it
prints — **already opted in** (`ship-protocol.md` § *Workflow authority*, #637;
do not re-derive the permission question). Staging is not optional ceremony: the
`Workflow` tool only accepts a `scriptPath` under the session's cwd, and the
installed plugin root never is, so a bundled path handed over directly is
**refused** (#973):

```bash
<skill-base-dir>/../../scripts/harness-stage.sh stage ship-issue
# -> path=…  source=…  staged=true|false
```

Run it **bare and read the `path=` line** — never `eval "$(…)"`, which is
refused worktree-isolated and yields an empty string (#815,
`next-issue/worktree-safe-recipes.md`). Substitute `<skill-base-dir>` with
this skill's invocation-header path. Pass the printed `path` as `scriptPath`,
with these args:

> This call is **already opted in** — `/workflow:ship-issue` is a slash
> command whose instructions direct it. See `ship-protocol.md`
> § *Workflow authority* (#637); do not re-derive the permission question.
>
> **Register this harness as background work first** (#890). The fan-out
> outlives the turn that starts it — measured 2.7 min and 8.7 min between the
> `Workflow` call and the next top-level record — so an observer reads this
> golem as `⚠ idle at prompt` while it reviews. `golem-work.sh register
> workflow` before, `complete` after; recipe in `golem/background-work.md`.

<!-- contract: args-keys-pre-pr-cycle1 -->

```text
args: {
  phase: "pre-pr",
  cycle: 1,
  maxCycles: <REVIEW_MAX_CYCLES, default 5>,
  files: [<changed files, FULL scope>],
  diff: "<diff text, FULL scope>",
  issue: { number: {N}, title: "{title}" },
  tokenCeiling: <REVIEW_TOKEN_CEILING if set; OMIT otherwise (default)>,
  preScan: [<pre-review-gates.sh TSV rows (incl. growth-graded sizing rows) + lint-gate rows from item 5>],
  conventionsDigest: "<distilled CLAUDE.md/AGENTS.md/memory rules>",
  reviewRoute: "<route from step a2; OMIT if the router was unavailable>"
}
```

<!-- contract: end-args-keys-pre-pr-cycle1 -->

`diff` is the **authoritative bytes the reviewers read** (byte-faithful
`git diff` from step a) — the manifest step no longer transcribes it, so pass
the full diff here (#267). Omitting `diff` is supported but makes each reviewer
derive it in-agent (`git diff origin/main...HEAD`), which costs extra tool
calls; prefer supplying it. A cycle with **neither** `diff` nor `deltaDiff`
logs a `WARNING:` at cycle start — it still reviews (each reviewer derives the
diff), but the line is there because a **dropped** `diff` key and an
intentionally omitted one are indistinguishable from inside the harness.

**Unknown top-level `args` keys are rejected — the harness throws, naming the
offending key(s) (#597).** The accepted set is exactly the keys shown in the
blocks here and in `ci-review-protocol.md`:

<!-- contract: args-keys-accepted-set -->
`phase`, `cycle`, `maxCycles`, `files`, `diff`, `prComments`, `issue`,
`tokenCeiling`, `preScan`, `conventionsDigest`, `reviewRoute`, `deltaDiff`,
`deltaFiles`, `priorBlockingDimensions`.
<!-- contract: end-args-keys-accepted-set -->

Every one is read by name with an empty-default fallback, so a mistyped key
was previously **dropped in silence** and its input simply went missing —
which on `diff` meant six reviewers scanning an empty diff and returning
`clean: true`, a vacuous pass byte-identical to a real one (measured on #567,
where an `argsFile` key dropped `diff`, `preScan` **and**
`conventionsDigest`). Since `clean` is half the merge invariant, that would
auto-merge at L4. A typo'd key is always a caller bug, so it fails loud at
dispatch: read the key name out of the error, fix it, re-dispatch.

**No key has a path/file variant — everything is passed INLINE, whatever its
size (#722).** `diffPath` and `argsPath` are the inventions actually observed
in the wild, and they are what you reach for on a large diff when you assume
passing the bytes inline is impractical. There is no such spelling, and the
harness could not use one: a `workflow.js` runs in a **sandbox with no
filesystem, no shell, and no git of its own** — the two-runtime model, whose
sibling constraints (banned clocks/timers) are recorded under
`LIBRARIAN_WORKFLOW_WALL_TIMEOUT` in `ship-protocol.md` § Environment
Variables. A path would arrive as an unreadable string. A big diff is a reason
to narrow the scope with the delta args below, never to invent a key.

**`tokenCeiling` is OPT-IN and OFF by default (#553) — measure before you
arm it.** It bounds **output tokens for one cycle**, measured as a delta from
harness start, so each cycle of a `REVIEW_MAX_CYCLES` loop gets its own full
ceiling. When `REVIEW_TOKEN_CEILING` is unset (the default), omit the arg
entirely and the cycle is unbounded.

**A ceiling set below where output actually lands is worse than no ceiling.**
Hitting it degrades the cycle exactly like budget exhaustion — remaining
dimensions land in `dimensions_skipped`, `budget_exhausted` is set, and `clean`
is forced false. That is correct for safety (a truncated review can never
terminate the loop as clean) but it means the skill will `cycle++` and re-run.
A too-low ceiling therefore does not save tokens: it spends its full budget on
every cycle, never reaches clean, exhausts `REVIEW_MAX_CYCLES`, and **dead-ends
the PR** for a human. Worked example from the #471/#472 run (cycle output 173k
/ 281k / 207k, terminated clean at 660k): a 150k ceiling would truncate all
three cycles, spend 450k, and still dead-end.

So size it from **observed** data, not a guess. Every cycle returns a
`token_report` — `{ output_tokens, ceiling, bound, dimensions_run }` — and logs
`cycle output: N tokens across M dimensions`, on bounded and unbounded runs
alike. Collect that across a handful of real issues, then set
`REVIEW_TOKEN_CEILING` comfortably **above** the observed p95 so it catches
runaways without truncating normal reviews. If a runtime turn budget *is* armed
it takes precedence and `tokenCeiling` is ignored.

The `token bound:` line at cycle start says which bound is live
(`runtime` / `caller ceiling N` / `none (default)`).

**Re-review narrowing — gated on the previous cycle's `next_scope`**
(#492, #656). Cycle 1 is a full review (no delta args). After that, narrow **iff
the previous cycle's `next_scope` (step (c)'s convergence call) was
`narrow`** — NOT merely because `cycle > 1`. When it was `full`, omit the
delta args and review the whole diff again.

> This loop shares `review-convergence.sh` — and therefore `C3-narrow-zero` —
> with the post-PR loop in `ci-review-protocol.md`, so it inherits the same
> composition bug: a narrowed cycle is narrow *by construction*, so a
> zero-finding result falls under the surface-ratio floor and `C3` withholds
> termination. Such a cycle is **structurally incapable of ending the loop**
> whatever it finds. `next_scope` resolves it identically here: a cycle with
> **blocking** findings advises `narrow` (a fix must be re-checked, so another
> cycle is coming regardless), while a **clean or deferrable-only** cycle
> advises `full` (the next cycle is a candidate terminator). A **crashed**
> cycle always advises `full`. Do not re-derive that rule — read `next_scope`
> from the convergence call in step (c) and carry it forward exactly as
> `--prev-delta-lines` is carried.

When the previous cycle advised `narrow`, pass the
**fix-commit delta since the last reviewed HEAD** so the harness re-reviews
only what changed instead of re-scanning the whole diff every cycle:

<!-- contract: args-keys-pre-pr-narrowed -->

```text
args: {
  phase: "pre-pr",
  cycle: <cycle>,
  maxCycles: <REVIEW_MAX_CYCLES>,
  files: [<changed files, FULL scope>],     // unchanged — scope-drift + summary
  diff: "<diff text, FULL scope>",          // unchanged — scope-drift reads this
  issue: { number: {N}, title: "{title}" },
  tokenCeiling: <REVIEW_TOKEN_CEILING if set; OMIT otherwise (default)>,
  preScan: [<pre-review-gates.sh TSV rows (incl. growth-graded sizing rows) + lint-gate rows from item 5>],
  conventionsDigest: "<distilled CLAUDE.md/AGENTS.md/memory rules>",
  reviewRoute: "<route from step a2; OMIT if the router was unavailable>",
  // Omit ALL THREE unless the PREVIOUS cycle advised next_scope=narrow
  // (#656); cycle 1 always omits them:
  deltaFiles: [<git diff --name-only lastReviewedSha...HEAD>],
  deltaDiff: "<git diff lastReviewedSha...HEAD>",
  priorBlockingDimensions: [<dimensions that blocked last cycle>]
}
```

<!-- contract: end-args-keys-pre-pr-narrowed -->

Capture `lastReviewedSha = git rev-parse HEAD` for the diff you just reviewed
**before** amending/adding the cycle's fix commit; the next cycle's delta is
everything committed since it. Derive `priorBlockingDimensions` from the
previous cycle's `blocking[]` findings' `dimension`/`category`. The full
`files`/`diff` stay in play on narrowed cycles — `scope-drift` reads the full
`diff` (whole-change AC-completeness lens), and a delta-local dimension
re-included via the prior-blocking carry-over also reads the full `diff` (it
must re-confirm a finding that may live outside the delta); only a dimension
pulled in because the delta *touches* its file types reads `deltaDiff` (the
saving). The delta args are additive and default-off: omit them — on cycle 1,
**and on any cycle whose predecessor advised `next_scope=full`** — for the
pre-#492 full review. Narrowing never sets `budget_exhausted` /
`dimensions_skipped`, so a narrowed cycle can still return `clean`.

The harness fans the dimensions as one parallel barrier under a single
token budget, re-scores certainty and characterizes each finding with a fresh
judge, computes each disposition from that characterization
(`ci-review-protocol.md` § How a finding is classified), and returns
`{ blocking[], deferrable[], summary, budget_exhausted, dimensions_skipped[],
clean }`. `dimensions_skipped` names any dimensions that did not run this cycle
(budget floor or mid-barrier failure); a non-empty list means the cycle is
**partial** and `clean` is forced false. The review agents are **read-only** —
applying fixes and filing deferrals is this skill's job (below).

**Bound the invocation in wall-time** (#224, #327). The harness is
budget-bounded but has **no wall-clock bound of its own** — the `workflow.js`
sandbox bans clocks/timers, and a *spinning* reviewer agent emits no tokens so
it never advances the token budget. So a single stuck agent can run the
invocation unbounded (observed: a >1h pre-PR review). Bound it from here, the
way the CI-wait loop bounds pending CI — but do **not** re-derive the
threshold/extension arithmetic in your head. That prose-only bound is exactly
what let three golems wedge (#327); the stop **decision** now lives in a
bundled helper you **call** each poll, so it cannot drift:

- Invoke the `Workflow` tool as a **background** task and poll `TaskOutput`
  with a finite per-poll timeout, accumulating elapsed wall-time (whole
  minutes). The tool result carries the run's `transcriptDir`.
  **A poll asks one question — is it done?** `TaskOutput` averages 7,776 chars,
  the highest per-call of any tool (#786), and a poll loop pays that on every
  iteration for an answer that is one line. Read the completion state and the
  `transcriptDir`; do not re-read the accumulated transcript each poll. The
  findings arrive in the harness's structured result when it finishes.
- At each poll, ask the helper what to do — pass the accumulated minutes, the
  run's autonomy level, and how many extensions it has already granted:

  ```bash
  <skill-base-dir>/../../scripts/workflow-wall-timeout.sh check \
    --elapsed-min {elapsed} --level {level} --extensions-used {ext}
  # -> verdict=continue|extend|stop|checkpoint
  #    ceiling_min=<hard cap>  next_deadline_min=<poll to here>  extensions_used=<K'>
  ```

  Substitute `<skill-base-dir>` with this skill's invocation-header path and
  the `{...}` placeholders with literal values — this polls from inside the
  golem's worktree when ship is chained in-turn (#815,
  `next-issue/worktree-safe-recipes.md`).

  It reads `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` (default 20) and
  `LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS` (default 1 → 40 min ceiling) itself.
  Act on `verdict`: **continue** — keep polling; **extend** (L3–L4 past a
  checkpoint with headroom) — carry the returned `extensions_used` forward and
  poll to the new `next_deadline_min`; **checkpoint** (L1–L2 past a checkpoint)
  — prompt the human **cut short** (treat this cycle as partial) vs **extend**
  (wait another interval); **stop** (the ceiling, at any level incl. L4) —
  `TaskStop` the run and recover partials below.
- On a stop (cut-short or the `stop` verdict), **recover the findings already
  produced** with
  `${CLAUDE_PLUGIN_ROOT}/scripts/recover-journal-partials.sh <transcriptDir>/journal.jsonl`
  — it prints a JSON array of the finding-shaped results collected before the
  stop (empty `[]` if none; a non-zero exit means the journal was
  missing/unreadable — fall back to "review timed out; findings not
  recoverable" rather than treating it as clean). Treat the cycle as
  **partial → `clean` forced false**, identical to `budget_exhausted`: it can
  never terminate the review loop as clean, and its recovered findings feed
  the resolve-or-defer step below. Carry a `timed_out` STOP note into the
  completion summary.

c. **Resolve the blocking findings**: for each finding in `blocking`, make
the fix in the working tree, then amend or add a commit. Re-run step (b)
(incrementing `cycle`) until `clean` is true **and** the convergence predicate
says stop, or the predicate stops at the `REVIEW_MAX_CYCLES` cap. On each
re-run, pass the fix-commit delta args
(`deltaFiles`/`deltaDiff`/`priorBlockingDimensions`) from step (b)'s narrowing
block **only when the previous cycle's `next_scope` was `narrow`**
(#492, #656); when it was `full`, omit them and re-review the whole diff. Resolving a
blocking finding is itself the case that advises `narrow`, so a cycle that
just fixed something does narrow — the gate only stops a *clean* cycle being
followed by one that cannot terminate.

**Consult the predicate once per cycle** — the cycle counter is the ceiling,
not the stop signal (#596). Same helper and same call shape the PR-side loop
uses; the full rule list and its per-verdict composition with the merge
invariant are documented once in `ci-review-protocol.md` § "Multi-cycle PR
review loop" step (f), and in the script header:

Substitute `<skill-base-dir>` and the `{...}` placeholders with literal values
— worktree-isolated when ship is chained in-turn (#815,
`next-issue/worktree-safe-recipes.md`).

```bash
<skill-base-dir>/../../scripts/review-convergence.sh check \
  --cycle "$cycle" --max-cycles "$cap" \
  --result "$cycle_result_json" \
  --delta-lines "$delta_lines" \
  [--prev-result "$prior_cycle_json" ...] \
  [--prev-delta-lines "$prev_delta_lines"] \
  [--delta-files "$delta_files_list"] \
  --partial "<true if budget_exhausted or wall-timed-out, else false>"
# -> verdict=continue|stop  rule=C1-cap|…|C8-novel  reason=<slug>
```

**`--delta-lines` is the surface this cycle REVIEWED**, captured when you
compute the review scope — the line count of the diff passed to the harness
(`deltaDiff` on a narrowed cycle, the full `diff` on cycle 1). Do **not**
recompute it from `lastReviewedSha`...`HEAD` after making the cycle's fix
commit: that measures the fix rather than the reviewed surface, and on a
**clean** cycle (no fix, so `HEAD` has not moved) it is always `0`, which reads
as maximally narrow and fires `C3` on a review that had genuinely converged.
Carry the value forward as the next cycle's `--prev-delta-lines`.

Pass `--partial true` on a `budget_exhausted` **or** wall-timed-out cycle: the
predicate then refuses to converge (rule `C2`), matching the existing rule that
a partial cycle can never read as clean. The one case that **adds** a cycle is
`C3` — a zero-finding cycle on a delta narrower than its predecessor does not
terminate, because a zero over a fraction of the previous surface says nothing
about the rest (#568). Extra cycles never weaken the pre-PR gate.

**Graceful degradation**: if the helper is missing or exits non-zero, fall
back to the plain `cycle` vs `REVIEW_MAX_CYCLES` comparison with a one-line
note — the same posture as a missing `workflow-wall-timeout.sh`. The loop
stays bounded either way; it just loses the early-stop and the narrow-zero
protection.

> **Standing rule — `blocking: []` is not a merge signal** (#580). Read every
> finding on merit, including the deferrables, and fix anything that is a live
> defect in code this PR itself wrote. The disposition is a rule list over a
> judge's characterization (`ci-review-protocol.md` § How a finding is
> classified); a mischaracterized finding lands in the wrong bucket silently.

d. **Collect the deferrables**: keep the `deferrable` list for filing after
delivery. **Option 1** files them **after the PR exists** so the filed issues
can link the PR (see Option 1 "File deferred review findings"). **Options 2/3**
have no PR to link — file the deferrables after the commit lands (Option 2:
after the push; Option 3: after the local commit), linking the commit SHA
instead of a PR number.

e. **Cap / budget exhaustion / wall-timeout**: `REVIEW_MAX_CYCLES` (default 5)
caps the number of review **cycles**; `LIBRARIAN_WORKFLOW_WALL_TIMEOUT`
(default 20 min, step b) caps the **wall-time of one cycle**. Both are the
review action's thresholds — the cut-short/extend checkpoints, the analogues of
`LIBRARIAN_CI_WAIT_TIMEOUT` for the CI-wait loop (which, like the wall-timeout,
is applied by a helper — `scripts/ci-wait-timeout.sh` — not by hand).
A `budget_exhausted` cycle
**and** a wall-timed-out cycle are both **partial regardless of their
findings**: `clean` is false even with zero blocking findings (some dimension
in `dimensions_skipped` never ran, or the run was stopped mid-flight), so
neither terminates the loop as clean — it must be re-run (fresh budget) or, at
the cap, hit the dead-end below. Never merge on a partial cycle. If `cycle`
exceeds `REVIEW_MAX_CYCLES`, or `budget_exhausted` is true, or the cycle was
wall-timed-out (whether or not blocking findings remain):

- **Interactive**: ask — **Fix remaining blocking findings now, ship anyway,
  or defer them?** (cut short the review vs. extend it by raising
  `REVIEW_MAX_CYCLES`).
- **Autonomous**: do NOT prompt. Proceed to deliver, **subject to each mode's
  review gate** — open the PR for Option 1 (it is parked, not merged, by the
  merge invariant); for Option 2 apply the **Option 2 review gate**
  (`execute-protocol.md`) — a cap-exhausted cycle with blocking findings left
  IS `stopped-with-blocking`, so it must **not** push to `main` and falls back
  to Option 3; finish the local commit for Option 3. Record the remaining
  blocking findings as a STOP note for the completion summary (Option 1
  "Autonomous completion summary" → "Review status"). Delivering is never a
  licence to bypass a gate: it means take each mode as far as its gate allows,
  then stop for a human (#637).

**Graceful degradation — mechanical failure only (#637), and only the RIGHT
mechanical failure (#973).** Two outcomes, and which one applies is decided by
`harness-stage.sh`'s **exit code**, not by your reading of the situation:

- **Exit 4 — the owning plugin is not installed.** The harness genuinely does
  not exist on this machine. **Skip**, with the note "Adversarial pre-PR
  review skipped (harness not available)", surfaced as
  `Review status: skipped: {reason}`.
- **Exit 3 — unresolvable or unstageable** (a broken install, an override
  pointing nowhere, an unwritable cwd). The harness is *supposed* to be here
  and is not reachable. Do **not** skip: **STOP** and surface
  `Review status: unavailable: {reason}`, quoting the probe list the script
  printed. **Do not deliver** — this is a broken environment, the same call
  CLAUDE.md makes for the prose-budget gate ("fail loud on a missing runtime
  rather than returning the 77 sentinel"). Fix the environment and re-run.
- **The `Workflow` tool errors on a successfully-staged path.** Skip, as for
  exit 4.

The split exists because the un-narrowed clause was **permanently satisfied**:
it keyed on a path that resolved on no tree, so the skip written for
mechanical failure fired on every single run and silently replaced the review
— silence-reads-as-a-pass (#538/#571) at the most expensive site in the repo.
A skip that fires every time is not graceful degradation. **If this step is
skipping routinely, that is the bug, not the weather.**

A `skipped` status **gates delivery in every shipping mode** (see
`execute-protocol.md`): Option 1 parks the PR instead of merging, and Option 2
must **not** push to `main` — it falls back to Option 3 (commit only) and
stops for a human, since a push to `main` has no PR to park and no remedy but
a revert. An `unavailable` status does not reach delivery at all. Never block
shipping due to harness errors that are genuinely a `skipped`.

Two things are **not** grounds to skip:

- **"I believe I lack permission to call `Workflow`" is excluded.** The call
  is authorized — `/workflow:ship-issue` is a slash command whose instructions
  direct it (`ship-protocol.md` § *Workflow authority*). Permission doubt is
  not unavailability; invoke the harness.
- **Never substitute a hand-rolled review.** If the harness is genuinely
  unavailable, record the skip and proceed to delivery. Do **not** re-implement
  the review yourself — reading the diff serially in-context is slower and
  weaker than the harness fan-out, and worse, it *reports as a review having
  run*, so the skip never surfaces. An observed run burned hours of wall time
  this way. A loud skip beats a quiet substitute.

If only
`workflow-wall-timeout.sh` is missing or errors (non-zero exit), do **not**
skip the review — fall back to the inline bound (checkpoint at
`LIBRARIAN_WORKFLOW_WALL_TIMEOUT`, auto-extend up to
`LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS` at L3–L4, then `TaskStop`) with a
one-line note, so a stuck agent is still bounded.
