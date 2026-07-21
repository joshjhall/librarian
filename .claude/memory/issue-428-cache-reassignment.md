---
name: issue-428-cache-reassignment
description: "#428 golem status-cache reset on issue reassignment — whitelist-identity not blanket wipe; review caught container/branch regression"
metadata: 
  node_type: memory
  type: project
  originSessionId: 920860ad-58de-4fb6-8393-b12679cdb3dd
  modified: 2026-07-21T05:14:36.008Z
---

SHIPPED PR #466 (2026-07-21, L3): provision-agent Mode-3 `write_status()` resets
the bind-mounted host status cache when the cached `.issue` != current `$ISSUE`
(operator reassigned an agent slot + `--force-recreate` without the documented
"Remove status file" teardown).

Key design lesson (3 review cycles to reach clean):

- cycle 1 caught: clearing only `started` leaves the sibling poller fields
  (`pr`/`ci`/`review`/`blocking`/`errors`) rendering the OLD issue's
  CI/blocking/error signal → same false-signal class #428 targets, wider.
- cycle 2 caught: a **blanket `doc = {}`** wipe ALSO destroys `container`/`branch`
  — those are agent-slot IDENTITY fields set ONCE at provisioning (SKILL.md Step
  4), never rewritten by write_status or status_poller. `golem-status.sh` keys
  Mode-3 detection off `.container` (line ~190) and `golem-attach.sh` finds the
  container by it (line ~35). Wiping them silently breaks monitoring + attach of
  a LIVE golem.
- FIX = keep-identity WHITELIST: `doc = {k: doc[k] for k in ("golem","kind",
  "container","branch") if k in doc}` — a future issue-scoped schema field is
  dropped by default (safe direction). Plus defensive `int(doc["issue"])` coerce
  (malformed numeric-string cache must not force a spurious mismatch-wipe).

Reusable: for a "reset stale cache on identity change" fix, prefer a
keep-identity whitelist over a drop-issue-scoped blacklist — the whitelist
auto-drops future issue-scoped fields (the bug direction), and forces you to
enumerate the small stable identity set instead of chasing every volatile field.
Related [[issue-283-checkpoint-table]] (started stamp origin #415),
[[token-scrape-transcript-dedup]] (.container Mode-2/3 split).
