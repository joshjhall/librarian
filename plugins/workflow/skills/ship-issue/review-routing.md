# Ship Issue — Review Routing

On-demand companion for `ship-issue/SKILL.md`. Load this when wiring or
debugging the **routing** step that decides whether a review cycle runs the full
adversarial fan-out or the cheap doc/config-only path (#550).

## The problem

The review harness fans out **7 agents** — manifest + 5 dimensions + judge — on
every diff regardless of its shape. A two-file doc change costs the same as a
900-line refactor. Measured on the #471/#472 run:

| Cycle | files | cache_read | output |
| ----- | ----- | ---------- | ------ |
| 1     | 2     | 13.0M      | 367k   |
| 2     | 2     | 34.3M      | 578k   |
| 3     | 5     | 19.8M      | 468k   |

Cycles 1–2 reviewed **two files** and still burned 47M cache_read / 945k output
between them. When a diff is prose only, `security`, `correctness` and `tests`
have nothing to read — running them is pure cost.

## The step

Before invoking the harness, ask the router. It is a bundled script, not a
judgement call:

```bash
# Under $HOME, not a world-writable /tmp (predictable path = symlink race), and
# NOT `WORK=$(mktemp -d)`: a command substitution is REFUSED in a worktree-
# isolated run (#815, next-issue/worktree-safe-recipes.md). `$HOME` unbraced and
# an inline-assigned variable are both spellings that harness CAN evaluate.
gid={GOLEM_ID or "solo"}; mkdir -p "$HOME/.cache/librarian-review/$gid"
git diff --name-only origin/main...HEAD > "$HOME/.cache/librarian-review/$gid/files.txt"
<skill-base-dir>/../../scripts/review-route.sh check \
  --files "$HOME/.cache/librarian-review/$gid/files.txt" --diff-lines {line count of the full diff} \
  --prescan-categories "<comma list of HIGH pre-scan categories>"
# -> route=full|cheap  rule=R0-empty|…|R7-doc-only  reason=<slug>
#    source_files=N doc_files=N config_files=N unknown_files=N
#    dimensions=<comma list>
```

Substitute `<skill-base-dir>` with this skill's invocation-header path — this
runs worktree-isolated when ship is chained in-turn (#815,
`next-issue/worktree-safe-recipes.md`).

Pass the verdict to the harness as `reviewRoute`. It is **additive and
default-off**: omit it and the cycle is byte-identical to pre-#550.

```text
args: {
  …,
  reviewRoute: "<route from the script above>",
}
```

**Why a script rather than harness logic.** `workflow.js` runs in a sandbox with
no shell, no filesystem and no git (the two-runtime model) — it cannot classify
paths it cannot read. This is also the repo's standing split: the script owns
the **decision**, the model performs the **action**
(`workflow-wall-timeout.sh` #327, `review-convergence.sh` #596,
`autonomy-resolve.sh` #190). A threshold a model re-derives each cycle drifts.

## The rule list

Ordered, first match wins; the last has no condition, so the policy is total.

| Rule            | Condition                          | Route             |
| --------------- | ---------------------------------- | ----------------- |
| `R0-empty`      | empty or missing file list         | `full` (fail safe) |
| `R1-forced`     | the operator off-switch is set      | `full` (operator) |
| `R2-source`     | **any** source-classified file     | `full`            |
| `R3-unknown`    | **any** unrecognized extension     | `full` (fail safe) |
| `R4-prescan`    | a HIGH pre-scan row the cheap path cannot surface | `full` |
| `R5-config`     | **any** config-classified file     | `full`            |
| `R6-max-lines`  | `--diff-lines` over the ceiling    | `full`            |
| `R7-doc-only`   | every file is **doc**              | `cheap`           |

`R7` is the **only** rule yielding `cheap`, and it is **last** — every fail-safe
fires first. There is deliberately no trailing catch-all producing `cheap`: the
default direction of this script is `full`.

### R5 — config is security-relevant, so it never routes cheap

Four review cycles found the same bug wearing different clothes: a file class
the harness treats as security-relevant, classified here as inert and routed
cheap — CI workflows, then database schemas, then **dependency manifests and
lockfiles** (`package.json`, `pnpm-lock.yaml`, `requirements.txt`,
`Cargo.toml`). A dependency bump is the canonical supply-chain diff, and it was
routing around `security` entirely while staying eligible to return
`clean: true`.

Four instances means the *shape* is wrong, not that a fifth carve-out is
missing. The root contradiction is one line in the normative table
(`workflow.src/74-narrowing.js`):

```js
security:    ['source', 'database', 'config', 'ci', 'docker'],
correctness: ['source', 'database', 'config', 'ci', 'docker'],
```

`config` is listed. So the cheap path is now **doc-only**, and this classifier
agrees with that table by construction instead of by an exception list that
could never be complete — `*.json` alone spans package manifests, lockfiles,
tsconfig, IAM policies and inert fixtures, and no basename list separates them.
`.txt` is excluded from `doc` for the same reason (`requirements.txt`).

The cost is real and accepted: a config-only diff no longer routes cheap. The
measured win was always doc-only diffs — prose is this repo's largest and
fastest-churning surface (#589) — and buying a wider optimization with a
fail-open security hole is not a trade this feature makes.

**Pass every input the rules need.** `R6` is inert without `--diff-lines` and
`R4` without `--prescan-categories`, so a call site omitting them silently
disables those fail-safes. Both shipped recipes
(`ci-review-protocol.md` step (a), `pre-ship-validation.md` step a2) pass all
three arguments.

### R4 — decomposition and memory-conformance rows (#695, #699)

Raised on issue #550 itself, and the sharpest case against naive content
routing. A markdown **decomposition** finding (progressive disclosure; "a moved
heading is still reachable by a link") and an OKF **memory-conformance** finding
(missing `type`, unparseable frontmatter) fire on precisely the doc-only diffs
the cheap path targets — and `.claude/memory/**` files are `.md`, so a pure
memory edit *is* doc-only by classification. Route those cheap and the repo's
largest, fastest-churning surface (#589) gets the one dimension aimed at it and
then a rule that skips it.

**Why a routing rule rather than trusting the pre-scan.** The issue comments
assumed `pre-review-gates.sh` already carried these scanners, so preserving
item-5's advisory surfacing would suffice. It does not: that script scans only
ai-slop, debug statements and missing tests. The sizing rows come from
`sizing.sh`, and the `decomposition` **dimension** is what turns such a row into
a judged blocking-or-deferrable finding. On a cheap cycle that dimension is
dropped, so the row would decay to an advisory table entry — blocking only under
`PRE_REVIEW_STRICT` — i.e. it would "vanish into a `clean: true`", which those
comments explicitly rule out. `R4` refuses the cheap path outright instead,
keeping the guarantee in the classifier rather than in an operator's env var.

Extension spellings are **not invented here.** ADR 0002 names one normative
table — `check-decomposition/loc_engine.py`'s `EXT_LANG` — and every other copy
is a **subset** of it: a scanner may cover fewer extensions, never contradict
them. Note `tests/lint-language-table-sync.sh` covers the four `check-*`
scanners and **not** this script, so that subset relationship is followed by
hand here rather than gated — see #913.

## Is a routed cycle `clean`?

This is the decision the whole feature turns on, because `clean` is half the
merge invariant **and** the review loop's terminator. `workflow.js` already
records the governing principle:

> Gating on budget-exhaustion makes `clean` unforgeable by truncation: a partial
> review can never terminate the loop as clean and reach the merge gate — even
> when the surviving dimensions produced only deferrable findings.

So the question is whether routing is **complete-by-design** (like a narrowed
dimension — legitimately clean) or **truncation** (like budget exhaustion —
never clean).

**Routing is complete-by-design, and a routed cycle CAN return `clean: true`** —
but only because the classifier is conservative. A routed-around dimension had
nothing to review; that is categorically different from a dimension that should
have run and did not. So the cheap path adds **nothing** to `dimensions_skipped`
and never sets `budget_exhausted`, exactly as narrowing already behaves, and
`computeClean` is untouched.

**Safety rests on the classifier, never on the reviewers.** Any ambiguity —
an unknown extension, an empty list, a malformed `reviewRoute` value —
resolves to `full`. That direction is a **tested property**, not a comment:
neutering `R2-source`, `R3-unknown`, the operator override, the extensionless
arm, or the `reviewRoute` allowlist each turns a named test red
(`tests/validate-review-route.sh`,
`tests/workflow-helpers/ship-issue/09-route-selection.mjs`).

The alternative — forcing `clean: false` on a routed cycle — was rejected as
self-defeating: a cycle that can never be clean can never terminate the loop, so
every routed PR would burn cheap cycles to `REVIEW_MAX_CYCLES` and dead-end for
a human. That is strictly worse than the status quo it optimizes.

## What still runs on the cheap path

`scope-drift` **and** `decomposition` — not nothing, and not scope-drift alone.

`scope-drift` reads the issue's acceptance criteria for completeness, and a
doc-only diff can absolutely fail one: documentation that does not describe what
the issue asked for is incomplete work, not inert prose. It always reads the
full diff and is exempt from narrowing, so AC-completeness holds on **every**
route.

`decomposition` is included because its `DIMENSION_RELEVANT_TYPES` entry lists
`docs` — and the selector **derives** membership from that table rather than
carrying a second list. That is the lesson of this feature's review history:
five separate blocking findings, every one a place where a hand-maintained list
disagreed with the normative table. Deriving removes the class rather than
patching another instance of it.

Post-#551 (which demoted `conventions` to a scheduled audit) `decomposition` is
the only non-`scope-drift` dimension claiming docs — and the one that matters
most on prose, since markdown progressive-disclosure and the
moved-heading-still-linked check fire on exactly these diffs (#589, #695).

A cheap cycle is therefore **4 agents** (manifest + 2 dimensions + judge) against
**7** for a full one — a **43%** drop. An earlier draft claimed 62% from the
pre-#551 six-dimension shape; that figure is stale.

## Two rejected triggers

Recorded so they are not re-proposed:

- **Routing on a line count alone.** A small *source* diff would then merge
  having never been read by the security or correctness dimensions — precisely
  what the merge invariant exists to prevent. Twenty lines of auth code is where
  security matters most. `--diff-lines` therefore only ever forces `full` (R6);
  it can never produce `cheap`.
- **A cheap path running one combined reviewer.** That reintroduces a
  judge-less self-grading path, the exact structure the fresh judge exists to
  break (#580).

## Environment variables

The router's two toggles — the operator off-switch that forces `full` (rule
`R1`), and the diff-line ceiling behind `R6` — are documented **with the script
that reads them**: `plugins/workflow/README.md` § environment variables, and
`review-route.sh`'s own header.

They are deliberately not restated here. `tests/lint-env-var-drift.sh` (#588)
fails a variable that prose documents but no code reads, so keeping the
documentation next to its reader is what makes that gate meaningful rather than
something to route around — and it leaves one place to edit when a default
changes.

## Graceful degradation

If `review-route.sh` is missing or exits non-zero, **omit `reviewRoute` and run
the full fan-out**, with a one-line note. The absent-router direction is the safe
one, which is why this needs no sentinel: a router that cannot answer must not
be able to narrow a review. Never block shipping because the router is
unavailable.
