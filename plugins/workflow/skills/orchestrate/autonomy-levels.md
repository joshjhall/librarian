# Orchestrate — Autonomy Levels (L1–L4)

Reference companion for `orchestrate/SKILL.md` (and, for a lone issue,
`next-issue/SKILL.md`). Load this when choosing the **rules of engagement** for a
run — how much the pipeline decides on its own versus stops for a human. It fixes
the shared vocabulary the whole autonomy epic is built on: the two gate
categories, the four levels, the merge invariant, the dead-end rule, and the
`autonomy_level` field.

> **Spec-only doc — no behavior change ships with it.** This file is the
> authoritative contract that the consuming issues cite; it does **not** wire any
> skill to a new code path. Today's binary `--autonomous` toggle still governs
> the running pipeline until #175 (`next-issue autonomy_level`), #177
> (`ship-issue` merge gate), #178 (`orchestrate` setup flow), #179 (critical cap
> / override removal), and #181 (language reconciliation) land. Read this to
> understand the target model and to know which section your issue implements —
> see the **Consuming-issue index** at the end.

---

## Why levels instead of a switch

Autonomy today is a **binary**: a run is either `--autonomous` — every gate
takes its documented default, all the way to a pushed PR — or fully interactive.
Under the hood that binary is really **two orthogonal on/off axes** (autonomy,
and plan-gating) plus a `severity/critical` + `FORCE_AUTO_CRITICAL` special case
guarding one corner. It is a switch, not a dial.

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
invariant. On a dead-end the orchestrator emits a **structured summary**: why it
is a dead-end, what was attempted, and what options remain. This is the one place
even a fully hands-off L4 run stops and waits.

---

## The critical carve-out

`severity/critical` issues offer **L1–L3 only**. An **L4 request on a critical
issue is silently reduced to L3** (the setup prompt offers L1–L3; `--level 4` /
`--autonomous` on a critical issue resolves to L3 with a one-line note). A
critical issue therefore always keeps its escalation gates — most importantly
plan approval — in front of a human.

This **replaces** today's scattered critical special-casing:

- Today, an autonomous critical run is forced *plan-gated*, and the *only* way to
  bypass its plan gate is the `--force-auto` + `FORCE_AUTO_CRITICAL=1`
  double-consent (a per-invocation flag plus a separately-sourced env var).
- Under the level model that whole apparatus collapses to **"critical ⇒ cap at
  L3"**: capping at L3 keeps escalation gates human, which keeps plan approval
  human, which is exactly what the double-consent protected. The
  `FORCE_AUTO_CRITICAL` env var, the `--force-auto`-on-critical branch, and their
  scattered references are **removed** in #179.

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

## Back-compat aliases

The old vocabulary maps onto the new levels so existing launch commands and env
keep working:

| Legacy signal              | Resolves to                                        |
| -------------------------- | -------------------------------------------------- |
| `--autonomous`             | **L4** (alias)                                     |
| `--auto` (deprecated)      | **L4** (alias)                                     |
| `NEXT_ISSUE_AUTONOMOUS=1`  | **L4**                                            |
| *(no autonomy signal)*     | interactive — **L1 disposition** (everything asks) unless a level is chosen at setup |
| legacy `"autonomous": true` in a state file | **L4** on read |

The explicit `--level {1,2,3,4}` flag (added in #175) is the forward form; the
aliases above are retained for continuity. Note that `--permission-mode auto`
(the Claude Code harness flag), `gh pr merge --auto`, and `bin/release.sh`'s
`--auto-*` flags are **unrelated** spellings of "auto" and are **not** autonomy
signals.

---

## Migration map: today → the level model

| Today (two binary axes + critical guard)                       | Level        |
| -------------------------------------------------------------- | ------------ |
| Not autonomous (every prompt + plan mode runs)                 | **L1**       |
| — (no distinct spelling today for "act, but ask at every gate")| **L2** (new) |
| — (no distinct spelling today for "auto routine, human escalations") | **L3** (new) |
| `--autonomous`, plan **skipped** (trivial/small, non-critical) | **L4**       |
| `--autonomous`, plan **gated** (medium/large/no-effort/critical) | **L3** on the plan gate (escalation stays human); other gates auto |
| `--force-auto` + `FORCE_AUTO_CRITICAL=1` on a critical issue   | **removed** — critical caps at L3, so this bypass no longer exists |

L2 and L3 are the genuinely new dispositions the switch could not express; L4 is
today's full autonomy, and L1 is today's interactive default.

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
