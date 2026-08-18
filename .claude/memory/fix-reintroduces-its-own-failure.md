---
name: fix-reintroduces-its-own-failure
description: A fix for a silent-data-loss bug tends to reintroduce that same loss by a new route; re-ask the original question of the fix itself
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 11132429-3014-4a1a-816f-781c2d7c5f7a
  modified: 2026-08-18T16:15:45.814Z
---

When fixing a **silent** failure (wrong/empty output, exit 0), the fix itself is
the most likely place the same failure reappears — by a different route. On #503
one data-loss bug took four cycles because each fix opened the next instance:

1. `> "$FILE"` truncates on **open**, so a lookup reading the same path got an
   empty file → every rationale dropped.
2. Fix: snapshot to `mktemp` first. But the `mktemp` was **unchecked**, so on
   failure the variable was empty, the lookup hit `[ -f "" ]` → same loss.
3. Fix: check it, and add `trap '... rm' EXIT INT TERM` to tidy up. But bash
   **resumes** after a trapped signal unless the handler exits, so Ctrl-C deleted
   the snapshot then fell through into the loop → same loss.
4. Fix: exit from the signal handlers, and stage the write for atomicity. But the
   staging file came from a bare `mktemp` in `$TMPDIR` while the target was in the
   repo — **different filesystems**, so `mv` degraded to copy+unlink and the
   "atomic" comment described something the code did not do. Plus `mv` preserves
   mode, so `mktemp`'s 0600 silently made a committed 0644 file owner-only.

**Why:** each fix is written while thinking about the *original* route, so the
new machinery it introduces (a temp file, a trap, a rename) is not itself
subjected to the question that found the bug.

**How to apply:** after fixing a silent failure, re-ask the original question of
the fix — *if this new step fails, what does the user see?* Specifically:

- every `mktemp`/`cat`/`mv` gets its exit status checked, and fails **loud**;
- a signal handler that must abort has to call `exit` (cleanup alone resumes);
- `mv` is atomic **only** on one filesystem — colocate the staging file with the
  target, and `df` it rather than assuming;
- `mv` preserves the source mode, and `mktemp` is 0600.

Prove each with a mutation: revert the fix, confirm its test goes red. And when a
behavioural test proves flaky (a real-SIGINT probe that passed standalone and
failed in-suite), **replace it with a deterministic structural one** rather than
keeping it — a flaky test teaches people to ignore red. Related:
[[measure-suppression-before-keeping-it]], [[comment-asserts-intent-not-code]].
