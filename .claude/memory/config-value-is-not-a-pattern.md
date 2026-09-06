---
name: config-value-is-not-a-pattern
description: An operator-configured name matched with fnmatch/case fails to match itself when it contains [ ] * ? — try literal equality FIRST
metadata:
  node_type: memory
  type: feedback
---

When a configured **name** (a filename, a label, an id) is matched with
`fnmatch` in Python or a `case`/`[[ ==` glob in bash, any glob metacharacter in
that value is read as **syntax**, so the value stops matching *itself*.
`fnmatch("notes[1].md", "notes[1].md")` is **False**, and bash's `case` agrees —
`[1]` is a character class matching `1`, not the literal text `[1]`.

Worked example (#669): `is_index()` classified a memory-bundle index by matching
each configured name as a glob when it contained `*?[`, else literally. A repo
whose index is literally `notes[1].md` took the glob arm, failed to match, and
its only index was classified as a concept — so the index went unread and
**every memory in the bundle was reported as an orphan**.

**Why:** a configured value is operator input, not a pattern language they opted
into. Globbing is wanted for one or two defaults (`index-*.md`) and the code then
applies that interpretation to *every* value. The failure is silent and inverted
— not "no match" but a confident wrong classification of everything downstream.
Both runtimes implement the same rule, so they agree while both are wrong: parity
gates stay green ([[parity-gate-hides-shared-defect]]), and the whole-repo
differential cannot see it either, since no file in the repo has such a name
([[whole-repo-diff-bounded-by-repo-content]]).

Same session, same shape, different domain: `kill -TERM $(pgrep -f 'run-all.sh'
| head -1)` treats a *pattern match* as if it were an identity. `head -1` picks
the OLDEST match, which on a shared host is a **peer worktree's** suite, not
mine. Selecting an exact PID does not establish ownership when the PID came from
an unfiltered pattern — filter by `readlink /proc/<pid>/cwd` before signalling
(see [[confirm-pid-ownership-before-killing]], whose rule this violated).

**How to apply:** try **literal equality across all configured values first**,
then interpret only the metacharacter-bearing ones as patterns — two passes, not
one loop with an if/else, since the ordering *is* the fix. Test the value that is
simultaneously a valid literal and a valid pattern (`notes[1].md`, `a?b.md`),
never only `*`-shaped ones: a fixture using `index-*.md` passes with and without
the bug ([[fixture-must-express-the-divergent-case]]). Assert BOTH halves — the
bracketed name matches its own file, AND a genuinely unmatched file is still
reported — or the test passes by the whole scan going silent
([[absence-assertion-needs-a-leak-fixture]]).
