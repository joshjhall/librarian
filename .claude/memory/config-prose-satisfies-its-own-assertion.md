---
name: config-prose-satisfies-its-own-assertion
description: A raw-text assertion that a config still sets X passes on the comment EXPLAINING X — delete the setting and the test stays green
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c5ce24e2-e77c-45fa-a057-bc727ea834d8
  modified: 2026-08-28T00:16:34.150Z
---

When a test asserts "config C still has setting S" with a raw text match
(`assert_file_contains "$CONFIG" "$RULE"`, `grep -q`), the **comment explaining
S** satisfies the assertion. A well-documented setting is the worst case: the
more prose justifying it, the more reliably the check passes after the setting
is deleted.

Measured on #737: `.agnix.toml` devotes ~19 lines to explaining why CC-SK-006 is
suppressed for ship-issue, naming the rule repeatedly. Deleting the
`[[overrides]]` block outright left `assert_file_contains ... "CC-SK-006"`
**passing** — the exact regression that assertion named as its purpose. Only a
sibling test caught it, so the guarantee was enforced entirely by a different
test than the one claiming it.

**Why it hides:** the same file that documents a property is the file being
searched for that property. Documentation and configuration share a namespace in
a text match, so the check cannot distinguish "the setting is here" from
"someone wrote about the setting here." Strong prose makes it worse.

**How to apply:** assert against a **structural extract** — the parsed block,
the assignment, the stanza — never the raw file. Strip comments first, then
match. Where two tests read the same config, have both call one shared extractor
so they cannot drift apart about what the setting IS. And prove it: delete the
setting and confirm the test fails. If it still passes, the assertion was
describing the documentation.

**Two cheap remedies, in order of strength.** Anchoring the pattern (`"^VAR="`
rather than `"VAR="`) kills the commented-out and prose cases for one line of
diff. Stronger, where the file can be sourced in isolation: assert
**reachability**, not text — `(set -u; . "$f"; [ -n "$VAR" ])` proves the value
actually resolves under the same condition every consumer runs under, which no
text match can do.

**It is a whole-repo class, not a per-case slip** (#830, measured 2026-08-27 on
librarian): ~86 `assert_file_contains`/`assert_file_not_contains` calls across
`tests/`, of which **exactly one** anchored its pattern. Any repo whose
convention is "explain every non-obvious setting directly above it" — i.e. this
one — has the collision everywhere by construction, so on finding one instance
assume siblings and grep ([[harden-one-knob-grep-every-sibling]]).

It also recurs in **freshly written** tests, not just old ones: #825's mutation
round caught it in an assertion added in that very PR, minutes after its author
had read this rule. Writing the assertion and writing the paragraph above it are
the same motion — which is why review does not catch it and mutation does.

The sibling of [[comment-asserts-intent-not-code]] with the direction reversed:
there the comment claims what the code lacks; here the comment SATISFIES the
check the code should have answered.
