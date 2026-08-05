---
name: quoted-awk-program-apostrophe
description: "In a single-quoted embedded awk program an apostrophe (even in a comment) ends the shell quote; and awk has no block scope, so helper loop vars must be declared as extra params"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 621fe101-e237-498d-9198-a05d816bf523
  modified: 2026-08-05T03:30:15.643Z
---

When a `patterns.sh` embeds its logic as a single-quoted `awk '...'` program,
**any apostrophe inside it — including in a prose comment — closes the shell
quote** and hands the remainder to bash. This bit twice in one session (#663),
from the words `awk's` and `caller's` in explanatory comments. It surfaces as a
`syntax error near unexpected token` pointing at a line that looks fine.

Separately: **awk has no block scope.** A function's locals must be declared as
extra parameters (`function f(a, b,   i, n)`) or they are GLOBAL. An undeclared
`i` in a `target_path()` helper clobbered the enclosing loop's counter and hung
forever on any input reaching it — 20+ s on a 1060-line file vs 14 ms for the
Python primary.

**Why:** neither is caught by shellcheck, a bash↔python parity gate, or a test
suite as ordinarily written, and both mislead. The apostrophe reads as a bash
error far from its cause. The scope one reads as a *performance* problem — my
first diagnosis was a quadratic `substr` token walk, and I rewrote a working
algorithm before finding the real cause.

**How to apply:** after writing or editing an embedded awk program, (1) grep the
program body for `'` and reword rather than escape; (2) check every `function`
signature for loop variables missing from its parameter list. Both are one-line
greps, far cheaper than the debugging they prevent. The second habit generalizes:
prove a performance diagnosis before acting on it — see
[[measure-suppression-before-keeping-it]].
