---
name: escaped-fixture-cannot-self-match
description: A fixture written with escaped metacharacters (console\. or \() can never match a detector whose pattern expects the literal character — the case passes either way
metadata:
  node_type: memory
  type: feedback
---

A third tautology shape, distinct from [[anchored-regex-tautological-test]] (the
fixture never reaches the detector) and
[[gate-and-evidence-converge-tautology]] (one fixture plays both roles). Here the
fixture reaches the detector and does not converge — it is simply **escaped on
disk**, so the detector's own metacharacters can never match it.

On #604 a case meant to prove "an indented scanner pattern literal self-matches
no debug arm" used the obvious fixture — a `command grep -nE -- '^\s*console\.(log|debug)\('`
invocation. On disk that line contains the text `console\.` and `\(`, with real
backslashes. The detector's pattern is `console\.(log|...)\(`, whose `\.` and
`\(` demand a **literal dot** and **literal paren**. They never match
`console\.`, so the case passed with the arm anchored AND unanchored — pinning
nothing.

The discriminating fixture holds the bare literal text: `const DEBUG_RE = "console.log(";`
— a real dot, a real paren, indented. That matches unanchored and not anchored,
so it detects the mutant.

**Why:** writing a fixture that "looks like scanner source" is not the same as
writing one the scanner can match. Regex source and the text a regex matches are
different languages, and a `printf`-built fixture adds a second escaping layer on
top — easy to end up asserting over a string no pattern in the system can ever hit.

**How to apply:** for any fixture meant to be matched by a regex containing
`\.`, `\(`, `\[` etc., check what actually lands on disk (`cat -A` the file, or
run the detector's raw `grep -nE` against it by hand) before trusting a green
case. Then mutation-test: flip the property under test (drop the anchor, delete
the exclusion) and confirm the case FAILS. That is what caught this one.
See [[mutate-after-every-security-fixture]] for the same discipline on security
fixtures.
