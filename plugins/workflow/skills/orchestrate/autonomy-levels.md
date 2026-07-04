# Orchestrate — Autonomy Levels (L1–L4)

Reference companion for `orchestrate/SKILL.md` (and, for a lone issue,
`next-issue/SKILL.md`). Load this when choosing the **rules of engagement** for a
run — how much the pipeline decides on its own versus stops for a human. It fixes
the shared vocabulary the whole autonomy epic is built on: the two gate
categories, the four levels, the merge invariant, the dead-end rule, and the
`autonomy_level` field.

> **Authoritative contract — now live.** The level model this file specifies is
> wired into the running pipeline: #175 (`next-issue autonomy_level`), #177
> (`ship-issue` merge gate), #178 (`orchestrate` setup flow), #179 (critical cap
> / override removal), #181 (language reconciliation), and #215 (hard-removal of
> the deprecated `--autonomous`/`--auto`/`--plan-gate`/`--force-auto` aliases and
> the `NEXT_ISSUE_AUTONOMOUS` env var) have all landed. **`--level {1,2,3,4}` is
> the sole autonomy dial.**
>
> **The disposition table is implemented in code (#190).** This doc is the
> *contract*; its decision table — level selection, the critical cap, per-gate
> disposition, the dead-end override, and the derived `autonomous`/`plan_gated`
> dispositions — is computed by the resolver
> `${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh` (Python primary
> `autonomy-resolve.py` + bash fallback), the **authoritative implementation**
> the skills call. When this prose and the resolver ever disagree, the resolver's
> `tests/validate-autonomy-resolve.sh` decision table is the tiebreak — update
> the prose, not the test. `/next-issue`, `/ship-issue`, and `/orchestrate` all
> call the resolver instead of re-deriving these rules.

---

## Why levels instead of a switch

Autonomy **was** a **binary**: a run was either `--autonomous` — every gate
takes its documented default, all the way to a pushed PR — or fully interactive.
Under the hood that binary was really **two orthogonal on/off axes** (autonomy,
and plan-gating) plus a `severity/critical` double-consent special case guarding
one corner. It was a switch, not a dial.

Real sessions want a **dial**: *decide the obvious, stop for the real choices.*
This spec replaces the switch with a **4-level model** (an SAE-driving analogy —
L1 hands-on through L4 hands-off) chosen **once at setup** and applied uniformly
to `/orchestrate` (many issues, many tracks) and a lone `/next-issue` (one
issue, treated as a one-issue "track").

---

## The two gate categories

Every point where the pipeline would otherwise stop for a human is one of two
kinds of **gate**:

- **Routine gate** — a mechanical, reversible, or already-guarded step whose
  disposition is *automatable*. **Auto-passed at L3–L4; human-authorized at
  L1–L2.** Examples: `git push`, open a PR, **merge a PR whose CI is green and
  review is clean**, each mechanical rebase resolution, each `ci-fixer` attempt,
  a branch/worktree prune.
- **Escalation gate** — a genuine judgement call. **Auto-passed at L4 only;
  human at L1–L3.** Defined as **everything that is not routine**: plan approval,
  a mid-flight architectural/directional fork, hitting a wall that has more than
  one viable path forward.

"Auto-passed" for a routine gate means *the disposition is decided without a
human*; it does not by itself remove a harness permission prompt (see the note
in the gate inventory).

---

## The four levels

| Level  | Harness perm mode | Routine gates | Escalation gates          | Merge (needs green CI + clean review) |
| ------ | ----------------- | ------------- | ------------------------- | ------------------------------------- |
| **L4** | `auto`            | auto          | auto (except dead-ends)   | auto                                  |
| **L3** | `auto`            | auto          | **human**                 | auto                                  |
| **L2** | `auto`            | **human**     | human                     | human                                 |
| **L1** | `acceptEdits`     | human         | human                     | human                                 |

Each boundary reduces to **exactly one knob**:

- **L1 → L2** — harness permission mode (`acceptEdits` → `auto`). L1 still asks
  before every side effect at the harness layer; L2 lets the harness act but the
  workflow keeps every routine and escalation gate human.
- **L2 → L3** — routine gates (human → auto). L3 stops asking about the
  mechanical steps (push, PR, merge-on-green, rebase, ci-fix, prune) but still
  stops for every escalation gate.
- **L3 → L4** — escalation gates (human → auto, except dead-ends). L4 is
  hands-off: it decides plan approval, architectural forks, and walls on its own
  — picking its recommended option — and only a **dead-end** brings it back to a
  human.

---

## Enumerated gate inventory

Every concrete gate in the pipeline, classified. The "where it lives today"
column points at the code the consuming issues make level-aware; it is a map for
the refactor, not a claim that the level logic exists yet.

### Routine gates (auto at L3–L4)

| Gate                         | Where it lives today                                                         |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `git push`                   | `ship-issue/SKILL.md` (`git push -u origin HEAD`); rebase force-push in Phase R |
| Open a PR                    | `ship-issue/SKILL.md` (`gh pr create`)                                       |
| **Merge a green+clean PR**   | `ship-issue` auto-merge fast path; `orchestrate` integration train (Phase T) |
| Each mechanical rebase resolution | `rebase-agent`; `merge-protocol.md` conflict classification (union/lockfile/generated/imports/version) |
| Each `ci-fixer` attempt      | `ci-fixer`; `ship-issue/ci-review-protocol.md` (capped at 3 attempts/check)  |
| Branch/worktree prune        | `worktree-rm.sh`; pool refill on merge (`pool-train-protocol.md`)            |

### Escalation gates (auto at L4 only)

| Gate                                | Where it lives today                                                    |
| ----------------------------------- | ----------------------------------------------------------------------- |
| Plan approval                       | `next-issue` `ExitPlanMode`; `mode-protocol.md` plan-gate-by-effort/severity contract |
| Mid-flight architectural/directional fork | New mechanism in #176; today only rebase arch-conflict escalation exists (`merge-protocol.md`, `rebase-agent`) |
| A wall with viable options          | Autonomous STOP conditions in `ship-issue/ci-review-protocol.md` (review-cap, CI-config denylist) |

> **"Routine" ≠ "promptless."** `git push`, PR-open, and PR-merge are each
> independently pinned to `ask` in `.claude/settings.local.json` (see
> `mode-protocol.md`), so at the harness layer they can still surface a
> permission prompt even at L3–L4. "Routine" classifies the *workflow*
> disposition — the step is automatable and batch-authorizable. The integration
> train's **one up-front approval** for a whole batch of merges/rebases/pushes
> (Phase T) is exactly the mechanism that discharges these routine gates in bulk.

---

## The merge invariant

**Never merge unless CI is green *and* the PR review is clean.** This is
**uncrossable at every level, including L4** — no flag, level, or override
crosses it.

This spec *names* an invariant the pipeline already enforces; it does not add new
merge behavior:

- The monitor flags a PR for merge only when it is green + review-clean
  (`ci: passing`, `review: approved`/`none`, `blocking: false`) — see
  `orchestrate/SKILL.md`.
- The integration train **excludes** any PR that is not green + review-clean —
  see `pool-train-protocol.md` (the train lands approved work; it does not wait
  on red CI or an open review).
- A golem runs unattended only *to* a green, review-clean PR before handoff.

The L3–L4 "merge = auto" cell above is auto **subject to** this invariant: the
level decides *whether merging needs a human keystroke*, never *whether an
un-green or un-reviewed PR may merge*.

---

## The dead-end rule

A **dead-end** is an escalation gate whose only auto-resolution would **violate
the merge invariant**. Concretely:

- CI is still red after `ci-fixer` exhausts its attempt cap.
- A contradictory conflict the `rebase-agent` cannot union-resolve.
- A review that came back **not clean** and cannot be mechanically fixed.

A dead-end **defers to a human at every level, L4 included** — there is nothing
safe to auto-decide, because every automatic path forward would cross the merge
invariant. On a dead-end the orchestrator emits a **structured summary** (below)
and waits. This is the one place even a fully hands-off L4 run stops and waits.

### The dead-end summary template

Every dead-end — from any of the three sources above — emits the **same three
required sections**, so an operator returning to a parked run reads one shape
regardless of what stalled. This is the canonical definition; the three sources
(`ship-issue/ci-review-protocol.md`, `agents/ci-fixer.md`,
`agents/rebase-agent.md`) reference it rather than re-inventing a format.

```markdown
## Dead-end — {issue #N or PR #N}: {one-line what stalled}

**Why it's a dead-end**
{The specific gate and why no safe auto-resolution exists — name the invariant
it would cross. e.g. "CI job `test` is red after `ci-fixer` exhausted its
3-attempt cap; the failure is in product code the diff changed, not infra, so
merging would violate green-CI."}

**What was attempted**
{The concrete remediation already tried and its outcome, so the human does not
redo it. e.g. "3 `ci-fixer` passes (assertion fix, import fix, type fix); each
re-ran CI and the same 2 tests stayed red. Infra-flake retry ruled it out —
failing step exercises the diff."}

**Options that remain**
{The agent's analysis of viable paths forward — may be "none obvious — needs a
human decision." Include a recommendation with a one-line rationale when one
exists. e.g. "A: the test expectation itself may be wrong (recommend — the
assertion predates the behavior the issue changes); B: revert the behavior
change and re-scope the issue; C: ship with failing CI is NOT an option (merge
invariant)."}
```

Rules that hold for every dead-end summary, at every level:

- **Never merge**, never force past the merge invariant, never fabricate a human
  answer or lapse-and-default (see § *Standing rule* below).
- Leave the PR **parked** (`status/pr-pending`), not merged, not in a prompting
  state.
- **Surface it on the feed** as a `dead-end` event (message begins `DEAD-END:`)
  so `golem-status.sh` / `golem-gate-watch.sh` flag it distinctly from a routine
  `escalation` and point the operator at `golem-attach.sh {N}`. See
  `orchestrate/mode-protocol.md` § *Feed event vocabulary*.

---

## The critical carve-out

`severity/critical` issues offer **L1–L3 only**. An **L4 request on a critical
issue is silently reduced to L3** (the setup prompt offers L1–L3; `--level 4` on
a critical issue resolves to L3 with a one-line note). A critical issue therefore
always keeps its escalation gates — most importantly plan approval — in front of
a human.

This **replaced** the scattered critical special-casing the binary model carried:

- Under the old model an autonomous critical run was forced *plan-gated*, and the
  *only* way to bypass its plan gate was a double-consent — a per-invocation
  `--force-auto` flag plus a separately-sourced env-var second-consent.
- The level model collapses that whole apparatus to **"critical ⇒ cap at L3"**:
  capping at L3 keeps escalation gates human, which keeps plan approval human,
  which is exactly what the double-consent protected. The env-var second-consent
  and the `--force-auto`-on-critical branch were **removed** (#179), and the
  `--force-auto`/`--plan-gate` override flags themselves were hard-removed (#215)
  — the cap now stands alone: nothing lifts a critical issue past L3.

---

## The setup flow (all levels)

The same ceremony runs whether orchestrating twenty issues or planning one via
`/next-issue`:

1. **Propose** tracks + issue ordering (for a lone issue: the single issue is a
   one-issue track).
2. **Approve** the tracks.
3. **Choose the rules of engagement** — the autonomy level L1–L4 (offered as
   L1–L3 for a `severity/critical` issue per the carve-out).
4. **Dispatch.**

The level chosen here is the run's single autonomy knob; it is persisted (see
`autonomy_level` below) so every downstream gate reads the same disposition.

---

## Standing rule: wait indefinitely at a human gate

Once a gate is raised to a human — at any level that keeps that gate human, and
at a dead-end regardless of level — **wait indefinitely for the answer.** Never
lapse-and-default because the operator stepped away. The only mechanism that
resolves a gate without a human is **L4's auto-passing of routine + escalation
gates**; a dead-end still waits even at L4. A human gate that "timed out" and
proceeded on a default is a bug, not a level behavior.

---

## The `autonomy_level` field

`autonomy_level` is an **integer 1–4** recording the chosen level for a run. Its
**meaning is fixed by this spec**; the schema changes that add it land in the
consuming issues (this doc changes no schema). Where it will live:

- **`next-issue` state file** —
  `next-issue/schemas/next-issue-state.schema.json` (added by **#175**). Replaces
  the binary `autonomous`; a legacy `"autonomous": true` reads as **L4** for
  back-compat.
- **golem-status / pool / orchestrator caches** —
  `orchestrate/schemas/golem-status.schema.json`,
  `orchestrate/schemas/pool-status.schema.json`, and (legacy)
  `orchestrate/schemas/agent-status.schema.json` (added by **#178**), so status
  displays and the monitor can show and reason about each track's level.

> All of these schemas are `additionalProperties: false`, so `autonomy_level`
> cannot be added implicitly — each is an explicit, per-schema edit in the owning
> issue.

---

## Removed vocabulary (#215)

`--level {1,2,3,4}` (added in #175) is the **sole** autonomy signal. The old
alias vocabulary was hard-removed in #215 — there is no deprecation window:

| Removed signal             | Replacement                                        |
| -------------------------- | -------------------------------------------------- |
| `--autonomous` / `--auto`  | `--level 4`                                        |
| `--force-auto` / `--skip-plan` | `--level 4`                                     |
| `--plan-gate` / `--no-skip-plan` | `--level 3` ("auto routine, keep the plan gate") |
| `NEXT_ISSUE_AUTONOMOUS=1`  | `--level 4` on the launch line                     |
| `"autonomous"` / `"plan_gated"` state-file mirror fields | dropped — `autonomy_level` is the only field |

*(no autonomy signal)* still means interactive — an **L1 disposition**
(everything asks) unless a level is chosen at setup. Note that `--permission-mode
auto` (the Claude Code harness flag), `gh pr merge --auto`, and `bin/release.sh`'s
`--auto-*` flags are **unrelated** spellings of "auto" and are **not** autonomy
signals — they were untouched by #215.

---

## Migration map: today → the level model

| Old binary model (two axes + critical guard)                   | Level        |
| -------------------------------------------------------------- | ------------ |
| Not autonomous (every prompt + plan mode runs)                 | **L1**       |
| "act, but ask at every gate" (no old spelling)                 | **L2**       |
| "auto routine, human escalations" (was `--plan-gate`)          | **L3**       |
| `--autonomous`, plan **skipped** (was trivial/small, non-critical) | **L4**   |
| `--autonomous`, plan **gated** (was medium/large/no-effort/critical) | **L3** on the plan gate (escalation stays human); other gates auto |
| the old critical plan-gate bypass (a `--force-auto` flag + env-var second-consent) | **removed** — critical caps at L3, so this bypass no longer exists |

L2 and L3 are the genuinely new dispositions the old switch could not express; L4
is full autonomy, and L1 is the interactive default. The `--autonomous` /
`--plan-gate` / `--force-auto` flags in the left column are gone (#215) — the
right column is now the only spelling.

---

## Consuming-issue index

This spec is the shared vocabulary; each downstream issue implements a slice of
it. `#174` (this doc) blocks all of them.

| Issue  | Implements                                                                 | Sections it cites                                     |
| ------ | -------------------------------------------------------------------------- | ----------------------------------------------------- |
| **#175** | `next-issue` `autonomy_level` (1–4) replaces the binary `autonomous`     | Four levels; `autonomy_level` field; back-compat aliases |
| **#176** | Mid-flight escalation gate for architectural/directional decisions       | Gate categories; escalation inventory; dead-end rule  |
| **#177** | `ship-issue` merge-on-green+clean-review as a level-aware routine gate    | Merge invariant; routine gate inventory (merge)       |
| **#178** | `orchestrate` track composition + rules-of-engagement setup flow          | Setup flow; `autonomy_level` in orchestrate caches    |
| **#179** | Cap critical at L3 and remove `force-auto-critical` overrides             | Critical carve-out                                    |
| **#181** | Reconcile autonomy language to L1–L4; bake in the never-time-out rule     | All — especially the standing wait-indefinitely rule  |
