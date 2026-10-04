# Handoff re-orientation cost `R` — running tally (#1058)

**Status:** open. This doc collects rows while handoffs happen, and closes with a
verdict once enough exist to re-derive from.

`R` is the number of re-orientation requests a resumed session spends before its
first file-modifying request (`handoff-protocol.md` § Recording `R` at a
handoff). #784 had to **sweep** it (R=3–50), and that sweep is why the 175k
threshold had to be picked by minimax regret instead of as a point optimum. Every
row here narrows the sweep the next re-derivation has to run.

## Why this is a hand-kept table, not code (#1058 AC3)

- **The source is deleted.** `checkpoint.handoff_marker` lives in
  `next-issue-{N}.json`, and `/workflow:ship-issue` deletes that file when it
  ships. A `context-budget.sh aggregate` subcommand would have nothing durable to
  read: by the time a second marker exists, the first is gone.
- **The volume is tiny.** One row exists. Reading a table by hand costs nothing,
  and code that aggregates n=1 has nothing to test against.
- **When to revisit:** at ~5 rows, or as soon as one re-derivation wants these
  numbers by machine. At that point, persist the marker somewhere ship does not
  delete, and aggregate that instead.

## How to add a row

The resumed session counts `R` when `next-issue`'s Phase 0 tells it to
(`scripts/handoff-marker.sh status` prints the directive on an open marker). It
writes the count to `r_measured`, then appends a row here in the same PR, before
ship deletes the state file. Leave `R` as `null` if the count was lost, and never
reconstruct it afterwards.

## Rows

| Date       | Issue | `context_tokens` at handoff | % of threshold | `R` | What the re-orientation was         |
| ---------- | ----- | --------------------------- | -------------- | --- | ----------------------------------- |
| 2026-09-16 | #1056 | —                           | —              | 3   | read state file, plan, and corpus   |

The #1056 row predates this doc. The per-request figures were withheld under
that verification doc's normalization policy
(`context-threshold-rederivation-1056.md` § Limits), so they show as `—`.
