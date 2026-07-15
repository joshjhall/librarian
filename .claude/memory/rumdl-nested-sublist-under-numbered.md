---
name: rumdl-nested-sublist-under-numbered
description: rumdl MD077 autofix mangles a nested dash-sublist placed inside a numbered/lettered list bullet — dedents it out of the parent; use flat prose instead
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7ac30f9d-985d-4e42-94ed-884a2a0b715e
---

In this repo's SKILL companion markdown, putting a nested `-` sub-list (with its
own indented code fences) **inside** a numbered `1.` / lettered `a.` list bullet
makes `rumdl check` flag MD077 "Continuation line over-indented", and
`rumdl fmt` "fixes" it by **dedenting the whole sub-block out of the parent
bullet** — silently breaking the logical nesting (e.g. L3–L4-only cleanup steps
get stranded before the L1–L2 bullet).

**Why:** rumdl computes one expected continuation indent per list item; deeper
`-` children at 5/8-space indent exceed it and get pulled back to the parent's
indent, not the child's.

**How to apply:** inside a numbered/lettered ship-issue-style bullet, express
sub-cases as **flat prose** (bold lead-ins like `**Primary checkout** — …`) with
code fences at the bullet's own indent, NOT as a nested `-` list. Ran into it
editing `plugins/workflow/skills/ship-issue/execute-protocol.md` for #225 (PR

# 235); reverting and rewriting with flat prose passed `rumdl check` clean

Related: [[typos-gate-blocks-push]].
