---
name: measure-suppression-before-keeping-it
description: Before narrowing a noise-suppression rule, measure what it actually suppresses — neuter the predicate and diff; it may buy nothing while causing false negatives
metadata:
  node_type: memory
  type: feedback
---

When a suppression/exclusion causes a false negative, the reflex is to **narrow**
it — add a condition so it keeps its win but stops over-firing. Check first that
it has a win. On #604 the issue proposed three narrowing options; the answer was
that two of the three guard sites should not exist.

The measurement is cheap and decisive: **neuter the predicate and diff the
output** over the real inputs.

```bash
sed 's/^is_scanner_pattern_line() {$/is_scanner_pattern_line() { return 1;/' scanner.sh > /tmp/n.sh
diff <(bash scanner.sh files.txt) <(bash /tmp/n.sh files.txt)
```

Result: the `ai-slop` guards suppressed 3 real rows; the `debug-statement` guards
suppressed **0**, across every scanner in the tree. Same predicate, same
codebase — one site earned its place, the other was pure cost. The reason was
structural (the debug patterns are `^\s*`-anchored, so the self-match the guard
existed to prevent was already impossible), which no amount of narrowing would
have surfaced.

**Why:** a suppression rule is invisible by construction — it removes rows, and
nobody audits rows that never appeared. Its cost (false negatives) and its
benefit (noise removed) are both unmeasured unless you deliberately measure them.
"It was added for a reason" is not evidence the reason still holds, or that it
ever held at every site the rule was copied to.
See [[harden-one-knob-grep-every-sibling]] — the same copy-to-every-site
dynamic, in the opposite direction.

**How to apply:** before narrowing a suppression, neuter it and diff. If it buys
zero, delete it at that site rather than complicating it. Report the per-site
numbers — they are what justifies rejecting a filed issue's proposed fix. Then
pin the structural reason it was unnecessary as a test, so nobody re-adds it
blind (and so the invariant it now depends on fails loudly if broken).
