# Registering Background Work

On-demand companion for `golem/`, `next-issue/`, and `ship-issue/`. **Load this
before starting work that outlives the turn that launches it** — a
`run_in_background` Bash task, a `Monitor`, or a `Workflow` harness.

## Why this exists

`golem-transcript-liveness.sh` decides whether a golem is working or idle from
the last top-level assistant record's `stop_reason`: `tool_use` means a call is
in flight, `end_turn` means the turn ended. That is right for a **synchronous**
turn and wrong whenever work outlives it. The turn genuinely ends; the work
genuinely continues; the transcript cannot tell the two apart.

Measured (#890): **five** golems reported `⚠ idle at prompt — turn ended` in one
orchestration session while running a test suite, a `git push` executing the
pre-push hook, and a review harness mid-fan-out. On a real transcript in this
repo, every `Workflow` call is immediately followed by an `end_turn`, and the
window before the next top-level record ran **2.7 min and 8.7 min**.

A false "idle" is indistinguishable from a real stall. Five cries of wolf and the
operator stops reading the column — which is exactly when a real stall lands.

## The one thing to do

Register before you start, complete when you finish:

```bash
<skill-base-dir>/../../scripts/golem-work.sh register workflow "review harness"
```

It prints one `key=value` line:

```text
id=work-1788724096-6b6a
```

**Read that id from the output** — do not wrap the call in `eval "$(...)"`. A
worktree-isolated session refuses a command substitution, and `eval` of a refusal
yields an empty string, so the id would silently vanish (`worktree-safe-recipes.md`
§ Pattern 1). Substitute `<skill-base-dir>` with the literal path from this
skill's own invocation header.

When the work finishes:

```bash
<skill-base-dir>/../../scripts/golem-work.sh complete work-1788724096-6b6a
```

`complete` is **idempotent** — completing an unknown or already-closed id exits 0
— so a cleanup path may call it unconditionally.

### Pass `--pid` whenever you have it

```bash
<skill-base-dir>/../../scripts/golem-work.sh register bash "run-all.sh" --pid 12345
```

The pid is what lets a **crashed** job be reaped in seconds instead of waiting out
the hour-long age bound. Optional, but always pass it for a backgrounded Bash task
where the harness reports the pid.

### The three kinds

| kind | what it covers |
| --- | --- |
| `bash` | a `run_in_background` Bash task |
| `monitor` | a `Monitor` watch |
| `workflow` | a `Workflow` harness fan-out |

These are exactly the three mechanisms that can outlive their turn.

## What happens if you forget

**Nothing breaks, and the golem is still not reported idle.** The classifier
carries a second signal that needs no cooperation: **every** top-level tool call
made since the current turn began. If *any* of them names a background-capable
tool, the verdict degrades to **indeterminate** rather than idle, and the caller
falls back to the mtime heartbeat — which still detects a genuine stall.

(Every call since the turn began, not merely the one immediately before the
`end_turn`: a golem that starts a background task and then makes one more
ordinary call before parking — `Workflow` → `Read` → `end_turn` — hides the
evidence one hop back. That shape occurs 3 times across 50 real transcripts in
this repo.)

| registry | tool calls this turn | verdict |
| --- | --- | --- |
| open item | anything | `background` — reported working |
| empty | any `Workflow` / `Monitor` / `Bash` | **indeterminate** — heartbeat decides |
| empty | all ordinary (`Read`, `Edit`, …) or none | `idle` |

So registration **upgrades** the signal from "don't know" to "definitely
working"; it is not load-bearing for correctness. Reaching `idle` requires
positive evidence that the turn ended on something that cannot have left work
behind.

Register anyway when you can. Row 2 costs the orchestrator a real signal: an
indeterminate golem falls back to a heartbeat that cannot distinguish *working*
from *parked*, which is most of what the liveness column exists to tell you.

## A stale registration cannot pin a golem to "working"

Three bounds, applied on every read, so a forgotten `complete` self-heals:

1. **Dead pid** — an entry whose `pid` is gone is dropped. (A pid that exists but
   cannot be signalled counts as alive: the reaper errs toward keeping an entry,
   since degrading toward *working* is safe and toward *idle* is the bug.)
2. **Age-out** — an entry older than `GOLEM_WORK_MAX_AGE` (default 3600 s) is
   dropped. Override per entry with `register --max-age S` for a genuinely long
   job.
3. **Fail-soft** — an absent or unreadable registry, or a missing `jq`, yields no
   open items and leaves the existing verdict untouched. Never a fabricated
   `working`.

This is the mirror of the `GOLEM_STALL_THRESHOLD` bound that stops a frozen
`tool_use` reporting `working` forever — the same reasoning, not a copy of the
knob. The two bound different questions: the stall threshold asks *has this
transcript stopped moving?*, the age bound asks *could this item still plausibly
be running?*

## Container (Mode 3) golems

**Register — it is the only liveness signal you have.** A container golem's
transcript lives inside the container and is invisible to the host, so the
transcript tier cannot classify it at all. The registry is written to the **main
checkout's shared status dir**, so the host *can* read it. An open entry is
reported as `background`; with no transcript and nothing registered the verdict
stays indeterminate, because the absence of a transcript is not evidence that a
golem is idle.

## Where the pieces live

| file | role |
| --- | --- |
| `scripts/golem-work.sh` | `register` / `complete` / `list` / `count` |
| `scripts/golem-transcript-liveness.sh` | consumes the registry; owns the verdict table |
| `scripts/golem-gate-watch.sh` | renders `alive, working (background: N items)` |
| `skills/orchestrate/schemas/golem-work.schema.json` | one registry line |

The registry is an **append-only JSONL event log**, not a rewritten object: a
golem writes it while an orchestrator reads it, and an append is atomic where a
read-modify-write would lose one of two interleaved updates. Open items are the
reduction of that log.
