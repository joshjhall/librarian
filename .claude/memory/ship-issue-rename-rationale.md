---
name: ship-issue-rename-rationale
description: "why the ship skill is named ship-issue (not next-issue-ship) — deliberate, don't rename it back into the next-issue prefix"
metadata:
  node_type: memory
  type: project
  originSessionId: 2216b035-7289-4281-87a6-61f64386a636
---

The delivery-half skill is `ship-issue`, renamed from `next-issue-ship` on
2026-07-01. It is still the second stage of the `/next-issue` → `/ship-issue`
pipeline (SKILL.md keeps the "kept as separate skills on purpose" rationale).

**Why the rename (don't undo it):** sharing the `next-issue*` prefix meant
typing `nex` gave the skill selector two `next-i…` candidates, and it sometimes
autocompleted/dispatched the ship skill instead of `/next-issue`. Moving ship
out of that namespace resolves the collision and matches the `file-issue`
verb-noun convention. The `next-issue`/`ship-issue` name asymmetry is
intentional — do NOT "fix" it by renaming back to `next-issue-ship`.

The containers copy of this skill was already deprecated/removed, so the rename
was contained to librarian (no cross-repo coordination needed). State file is
still `next-issue-{N}.json` (written by `/next-issue`, read by ship) — that name
was deliberately NOT renamed. See [[conform-scope-enum]] for commit scope,
[[autonomy-vs-plangate-flags]] for the shared flag families.
