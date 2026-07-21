# ADR 0001 — Golem event bus: reuse feed+Monitor as the floor, HTTP-bridge as optional enrichment

- **Status:** Accepted
- **Date:** 2026-07-18
- **Scope:** `workflow` plugin (golem event emission — `hooks/golem-notify.sh`;
  orchestrator consumption — `scripts/golem-gate-watch.sh`,
  `scripts/golem-status.sh`, `scripts/golem-watch.sh`, the `orchestrate` skill)
- **Issue:** [#343](https://github.com/joshjhall/librarian/issues/343)
  (epic umbrella — "Golem event bus: multi-sink emission + orchestrator-push")

> **Convention:** ADRs for the `workflow` plugin live in this directory
> (`plugins/workflow/docs/adr/`), four-digit-prefixed and never renumbered
> (this is the plugin's first, hence `0001`; numbering is per-plugin, so it is
> unrelated to `review-audit`'s ADR 0001). `docs/` is inert to the plugin loader
> (only `skills/` and `agents/` are auto-discovered), so a design doc here ships
> with the repo without becoming a loadable component.

## Context

A golem (a `/next-issue --level N` session running under `auto` mode in a tmux
worktree or a container) reaches human-decision points — a permission `gate`, a
plan-gate `ExitPlanMode`, a mid-flight `escalation`, a `dead-end`. The
orchestrator learns of these two ways today, each imperfect for the "a golem
needs a human **now**" case:

1. **Proactive, but shared-filesystem-only.** The `Notification` hook
   `golem-notify.sh` classifies each event and appends one JSON line
   (`{ts, golem, event, message}`) to `<root>/.worktrees/.status/feed.jsonl`;
   the orchestrator arms `golem-gate-watch.sh --stream` via the `Monitor` tool,
   which tails that feed and emits on the transition into a fresh gate. This
   already delivers push **at the orchestrator surface** — but it is
   *file-mediated*, not a golem-initiated call, so it only reaches an
   orchestrator that **shares the golem's filesystem**. A container golem's feed
   is trapped inside the container (the transport gap tracked in
   containers#735).
2. **Interval poll of external state.** A separate sweep derives coarse golem
   state from **GitHub PR / issue-label** changes. GitHub offers no push, so this
   *must* stay polled — but it is the wrong signal for a live decision point and
   is intentionally out of scope here.

So a container golem parking at a gate is invisible until a sweep happens, and
even a worktree golem relies on the orchestrator actively running a watcher. We
want the golem to **reach out** the moment it gates, uniformly for both golem
types.

The generalization: a golem already produces one per-event signal. Fan that
**one emission** out to **N sinks**, each an independent subscriber (local
`feed.jsonl`; a host monitor; an orchestrator bridge; future sinks). The golem
does not know who is listening — it emits; subscribers react. This is the same
decoupling `feed.jsonl` already has, extended across the process/host boundary
via HTTP. This ADR fixes which mechanism is the baseline and which is additive,
so the code follow-ups do not relitigate it.

## Decision

Adopt **a reuse-first floor with optional HTTP enrichment**: the existing
`feed.jsonl` + `Monitor` path is the unconditional baseline (approach **(a)**),
and a golem→orchestrator HTTP bridge (approach **(b)**) is additive on top, not a
replacement.

### 1. Reuse feed.jsonl + Monitor as the unconditional floor

The existing path — `Notification` → `golem-notify.sh` → `feed.jsonl` →
orchestrator `Monitor(golem-gate-watch.sh --stream, persistent: true)` — remains
the always-present baseline on **every** surface. It is TTY-free (covers headless
and container golems), carries golem-id attribution, and is the single source of
truth the pull `golem-status.sh` BLOCKED list already delegates to
(`golem-gate-watch.sh --once`). Nothing here is deleted. Approach **(a)** is the
recommended first step because the machinery is mostly built — the only missing
piece for container golems is transport (containers#735), not a new orchestrator
component.

### 2. Multi-sink emitter generalization

Generalize golem event emission so one event fans to a configurable set of
sinks: `feed.jsonl` **always**, plus zero or more HTTP endpoints
(env-configured, e.g. `GOLEM_EVENT_SINKS`). The **never-block-the-golem
contract** is preserved verbatim — every sink write is best-effort, all errors
are swallowed, and the hook always exits 0. `golem-notify.sh` (the feed sink) and
the containers `claude-host-event.sh` (an HTTP sink) thereby converge as **two
sinks of one emission**. An empty `GOLEM_EVENT_SINKS` is a pure no-op beyond the
feed, so the default behavior is byte-for-byte what it is today.

### 3. The HTTP bridge (b) is additive, not a rewrite

Any orchestrator-side HTTP listener that *receives* a golem's "I'm gated on X" is
a **net-new optional component** with its own lifecycle (candidate home — a
plugin-side shell listener, or an external command-center service; decided in the
consumption follow-up, not here). It supplements the floor for golems that do not
share the orchestrator's filesystem (container golems); it never replaces
`feed.jsonl` + `Monitor`. When the bridge is absent, the floor stands unchanged —
so worktree golems, which need no bridge, are never forced through one.

### 4. Keep the GitHub PR/issue-label poll unchanged

External GitHub state has no push mechanism, so the periodic PR/issue-label sweep
stays exactly as-is. This ADR governs only the **live-decision-point** signal
(the gate/escalation/dead-end fan-out); it does not touch, remove, or replace the
external-state poll.

### 5. Repo boundary

| Concern | Owner |
| --- | --- |
| Event-bus concept, multi-sink emitter, orchestrator consumption, `golem-watch` semantics (serve **both** golem types) | **librarian** (this plugin) |
| Container-boundary transport — mount/forward `.worktrees/.status` across the container boundary (containers#735) | **containers** |
| Build-wired container HTTP sink (`claude-host-event.sh`, `POST_CLAUDE_EVENTS_TO_HOST`) | **containers** |

The `containers` submodule is a separate, pinned repo; its transport and its
build-wired sink are a **cross-repo follow-up**, not part of any librarian PR
under this ADR.

## Consequences

**Positive:**

- No coverage regression on any surface — the feed floor is unconditional, and
  an unset `GOLEM_EVENT_SINKS` leaves today's behavior unchanged.
- Container golems become reachable the moment a sink is configured, without a
  new orchestrator component on the worktree path.
- One converged mental model — every subscriber (feed, host monitor,
  orchestrator bridge) is "a sink," so a future subscriber is additive by
  construction.
- The never-block-the-golem contract is carried into every sink, so a slow or
  dead HTTP endpoint can never wedge a golem.

**Negative / costs:**

- A second emission path (HTTP) must be kept best-effort and non-blocking — an
  HTTP POST has failure modes (timeout, DNS, TLS) a local file append does not,
  so the emitter must bound and swallow them.
- Building bridge **(b)** adds a listener lifecycle to own (start/stop, port,
  auth) — deferred to its follow-up precisely so it is not taken on until needed.
- The emitter's latent status-path coupling must be fixed **before**
  generalization: `golem-notify.sh` hardcodes `.worktrees/.status` instead of
  honoring `config.sh`'s env-overridable `GOLEM_STATUS_DIR`, so a config-driven
  multi-sink emitter would otherwise read config two inconsistent ways (see
  Follow-up 1).

## Alternatives considered

- **Rip-and-replace the feed with an HTTP-only bus.** Rejected: deletes the
  working shared-filesystem floor, strands host/worktree golems behind a listener
  they do not need, and forfeits the never-block simplicity of a local append.
- **Poll harder — shorten the GitHub sweep interval.** Rejected: GitHub has no
  push, so a tighter sweep is still coarse and still the wrong signal for a live
  decision point, and it does nothing for a container-trapped feed.
- **Push directly from `golem-notify.sh` to one hardcoded orchestrator URL.**
  Rejected: couples the golem to a single subscriber, which is exactly the
  coupling the emit-to-N-sinks decoupling exists to remove.

## Follow-ups

The concrete code changes land as separate issues; this ADR is the decision.
Dependency spine **1 → 2 → 3**, with **4** cross-repo and free-floating. Item 1
(the path fix) MUST precede item 2 (the generalization) so the multi-sink emitter
reads its status/sink config through one consistent source.

1. **Fix `golem-notify.sh` status-path coupling** (#405, blocks 2) — source
   `config.sh` / honor `GOLEM_STATUS_DIR` instead of hardcoding
   `.worktrees/.status`, so the emitter and its readers resolve the feed one way.
2. **Multi-sink emitter `GOLEM_EVENT_SINKS`** (#406, dep 1) — one event fans to
   `feed.jsonl` always plus zero-or-more env-configured HTTP sinks, best-effort,
   never blocks the golem, always exits 0; converge with the containers
   `claude-host-event.sh` sink.
3. **Orchestrator-push consumption / HTTP bridge** (#407, dep 2 + containers#735,
   **LANDED**) — give the orchestrate session a way to *receive* a golem's gate
   beyond feed+Monitor (the additive listener of Decision 3); decide the
   listener's home; works for container golems without a shared filesystem.
   Delivered as `scripts/golem-event-listener.{py,sh}`: an optional plugin-side
   HTTP listener (the decided home — not an external service, keeping host /
   bare-linux / container parity) that **appends each received POST into the
   orchestrator's own `feed.jsonl`**. Because the #406 POST body is byte-identical
   to a feed line, the received gate surfaces through the **existing**
   `golem-gate-watch.sh --stream` Monitor floor with no new classification or
   attribution path, satisfying "surfaces identically" for both golem types. It
   binds loopback by default and is purely additive (absent ⇒ the feed + Monitor
   floor is unchanged; worktree golems never need it). The container→host
   transport that carries a container golem's POST to it stays item 4
   (containers#735).
4. **containers transport + build-wired sink** (containers#743, cross-repo) —
   mount/forward `.worktrees/.status` across the container boundary
   (containers#735) and build-wire the container HTTP sink; tracked in the
   `containers` repo, not a librarian change.

**Landed increment — the `resolved` event kind** (#422): the feed's event
vocabulary gained a fifth kind, `resolved`, an explicit gate-clearing signal.
The BLOCKED list drops a golem only when its most-recent feed line leaves the
blocked set, which an `idle` normally supplies once the golem moves on — but the
compliant plan-approval broker's `tmux send-keys 1 Enter` fires no Notification,
so no superseding line was ever written and the stale `gate` rendered BLOCKED
for the full TTL. `scripts/golem-resolve.sh` synthesizes a `RESOLVED:`-prefixed
Notification after the send-keys; `golem-notify.sh` classifies it `resolved`,
which (like `idle`) is not in the blocked set and thus supersedes the stale gate
on the next sweep. This is the concrete "a `resolved`/clearing event kind is a
natural fit for the multi-sink emitter" the epic anticipated — it fans out
through the same emitter as every other kind, so item 2's generalization carries
it for free.
