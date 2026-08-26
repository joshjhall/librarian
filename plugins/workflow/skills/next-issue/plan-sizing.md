# Next Issue — Plan-Lens Sizing

On-demand companion for `next-issue/SKILL.md` and `phase2-plan.md`. Load this at
the **plan-lens sizing step** of Phase 2 — after exploring the code areas, before
writing the plan.

It exists because file-size discipline used to be entirely reactive. The audit
lens (`/review-audit:codebase-audit`) sweeps the whole repo and produces a
backlog nobody works through; the review lens (`/workflow:ship-issue`'s pre-PR
review) fires only once the work exists, when acting on it means unpicking a
finished implementation. Neither runs while planning, which is the one moment a
decomposition is cheap — the file is already open and nothing depends on the new
code yet.

| Lens   | Question                      | Growth signal    |
| ------ | ----------------------------- | ---------------- |
| audit  | is this file too long?        | none             |
| review | did this diff make it worse?  | `git diff --numstat` |
| plan   | will this plan make it worse? | **your estimate** |

The intended effect is that issues which are **first to touch** an oversized file
absorb its decomposition. Over many issues the worst offenders get fixed as a
side effect of ordinary work, without a decomposition backlog and without the
review lens rejecting finished implementations.

## The step

1. **Build the candidate list** — the files the plan will create or modify, from
   the exploration you just did. One path per line.

1. **Estimate added lines per file.** This is a guess, and it is allowed to be
   rough: it decides whether a row is raised, not what the plan says. Write
   `added<TAB>path` rows (the same shape `git diff --numstat` uses, so a real
   numstat file is accepted unchanged).

1. **Run the lens** — bundled with `ship-issue`, a sibling skill in this same
   plugin, so the path resolves wherever `workflow` is installed (it must not
   reach into `review-audit`, which installs separately):

   ```bash
   <skill-base-dir>/../ship-issue/plan-lens.sh \
     /tmp/plan-files.txt /tmp/plan-estimates.tsv
   ```

   Inside a golem worktree, substitute `<skill-base-dir>` with this skill's
   invocation-header path — `${CLAUDE_PLUGIN_ROOT}` is refused there (#815, see
   `worktree-safe-recipes.md`).

1. **Parse the TSV** — `file\tline\tcategory\tevidence\tcertainty`:

   | Category | Meaning |
   | -------- | ------- |
   | `size-headroom` | UNDER budget today, but your estimate projects it over |
   | `file-length` | Code file already over its production-LOC budget |
   | `ai-file-bloat` / `doc-file-bloat` | Prose file already over its per-type budget |

   `size-headroom` is the row that justifies this step: both other lenses return
   early on a file under threshold, so a file at 640 lines against a 700 budget
   is **silent everywhere else** — and it is exactly the file about to gain 200
   lines.

1. **Dispose of each row** — cheap seam vs swamping, below.

**Degrade, never block (AC12).** If the scanner is missing, unreadable, or exits
non-zero, put a one-line note in the plan ("plan-lens sizing unavailable:
`<reason>`") and **continue planning**. A planner that cannot size a file must
not stall the pipeline. This is not in tension with the scanner's own fail-loud
contract: the *scanner* refuses to report "no findings" when it cannot scan
(exit 2, the #538/#571 sentinel discipline), and the *planner* records that
refusal and proceeds. Both halves are required — a silent exit 0 would be
indistinguishable from a clean repo.

## Cheap seam vs swamping

**Most hits are cheap. Fold them into the plan silently** — as ordinary plan
steps naming the seam the scanner found (which units move where), placed *before*
the feature work. No gate, no ceremony; the plan gate reviews them like any other
step. A lens that escalates on every row is a nuisance generator, and a nuisance
generator gets turned off — at which point it catches nothing at all.

A decomposition is **swamping** when it would:

- move the issue's `effort/*` tier up a step (`small` → `medium`), **or**
- account for the majority of the resulting diff, **or**
- require design decisions the issue never contemplated (a new module boundary,
  a public API change, a migration).

Judgment call, deliberately. When it is genuinely ambiguous, treat it as cheap
and fold it in — the plan gate is the backstop, and a human striking a folded-in
step costs one glance, while a spurious escalation costs a whole round-trip.

## The swamp gate

**When it swamps, you do not decide — you raise a gate.** The four resolutions
have materially different costs, and choosing among them is the operator's call.

Resolve the disposition with the standard ladder — do **not** re-derive the
cutoff:

```bash
<skill-base-dir>/../../scripts/autonomy-resolve.sh gate escalation --level {N}
```

Substitute `<skill-base-dir>` with this skill's invocation-header path — this
recipe runs worktree-isolated in a golem (#815, `worktree-safe-recipes.md`).

**Payload** — assemble exactly the shape `escalation-protocol.md` § *Escalation
payload format* specifies: a one-line **decision**, the **options** each with a
one-line tradeoff, and your **recommendation with a rationale**. You hold the
seam data, so you are expected to have an opinion.

The four options:

1. **Fold it in** — expand this issue to include the refactor. Relabel the
   effort tier to match (`gh issue edit {N} --remove-label effort/small
   --add-label effort/medium`); shipping a `small`-labeled issue with a
   `medium`-sized diff makes the backlog lie.
1. **Follow-up issue(s)** — do the minimum here, file the decomposition
   separately, and reference it. The PR says `Contributes to #N`, not `Closes`
   (#243).
1. **Decompose first** — stop this issue, work the split to completion, come
   back. Mechanically this is the **existing dependency queue**, not a new
   suspend mechanism: file the split issue, add a `Blocked by #<split>`
   reference to this one, and let `dependency-queue.md` order the work. The
   next `/workflow:next-issue` picks up the blocker and advances toward this
   target. Leave the state file on disk — that is what makes the return
   resumable rather than an abandoned worktree.
1. **Proceed unchanged** — the file is judged fine as-is. Record the decline in
   `scope_expansions` so the same gate does not re-fire on the next issue that
   touches it.

**Dispatch by level**, per `escalation-protocol.md` § *Disposition by level*:

- **L1–L3** — block and **wait indefinitely**. Under an orchestrator, mint a
  gate-id and use the feed + issue comment + inbox `consume` loop; for a lone
  `/workflow:next-issue`, surface the payload inline and block the session.
  Never lapse-and-default because the operator stepped away.
- **L4** — auto-select the recommendation, and record **which option and why**
  in the state file and in the plan issue comment. A scope decision taken
  unattended must be visible after the fact.

**Option 3 is the one with teeth.** It suspends in-flight work, and at L4 it can
be selected with nobody watching. Prefer option 1 or 2 unless the split genuinely
must land first (for example, the feature cannot be written coherently against
the current shape). If option 3 is chosen, the `Blocked by` reference and the
state file are not optional — they are what distinguishes a suspended issue from
an abandoned one.

## Flow coverage

`/workflow:golem` and `/workflow:orchestrate` inherit this step with **no extra
wiring**, and that is verified rather than assumed: neither skill builds a plan
of its own. Golem's Phase C invokes `Skill(next-issue)`; orchestrate launches
`claude "/workflow:next-issue <N> --level {L}"`. Every `ExitPlanMode` mention in
either skill *describes* this skill's gate rather than raising one. So the
sizing step, the swamp gate, and the `scope_expansions` record apply identically
to a solo run, a golem, and a pool golem.

At **L4** the plan is posted as an issue comment instead of gated
(`phase2-plan.md` § *Autonomous planning path*). That comment **must include the
decomposition steps and any auto-selected swamp-gate resolution**, with the
rationale. L4 is the path with no human in the loop, so the issue comment is the
only place the scope growth becomes visible — omitting it turns an unattended
scope decision into an invisible one.

## Recording the outcome

Every folded-in decomposition and every swamp-gate resolution goes in the state
file's `checkpoint.scope_expansions` array (see `state-format.md`). Each entry
records the file, what was decided, and why.

This is what stops the expansion reading as **drift**: `dev-core`'s
`drift-detect` and the pre-PR review both compare the diff against the plan, and
a decomposition nobody declared looks exactly like unplanned scope creep. A
recorded expansion is a planned change that a human (or an L4 auto-selection)
signed off on.
