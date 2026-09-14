---
name: exit-code-alone-cannot-pin-a-path-property
description: "When a fixture stages several files, asserting only the exit code lets a SIBLING satisfy the assertion — the mutant that breaks one path still exits the same way; assert the observable consequence unique to that path"
type: feedback
---

A test whose only assertion is the process exit code pins "something in this
fixture failed", not "*this* thing failed". When the fixture touches more than
one file, a sibling can satisfy it and the mutant survives.

**Measured on #1007.** The case was "a non-ASCII memory filename is still in
scope", guarding the `-z` in `git diff --cached --name-only -z` — without it git
C-quotes `café.md` into the literal `"caf\303\251.md"`, which matches no prefix
test. The fixture staged `café.md` **and** an ASCII `MEMORY.md`. Reverting to
plain `--name-only` left the case **green**: the ASCII file still put the commit
in scope and the gate still found a row, so the exit code was 1 either way — for
the wrong reason.

What the quoting actually breaks is one step further in: the narrowing lookup
holds the C-quoted literal, matches no row, and the guard falls through to its
"no finding sits in your staged files" branch. Asserting the file's **real name
appears under the staged heading** is what fails the mutant, because only raw
bytes can produce it.

**Why:** this is the tautological-test family (see
[[anchored-regex-tautological-test]]) reached from a different direction — there
the fixture never triggered the detector; here it triggers by an unintended
route. Both pass before and after the fix, and a green suite is the only thing
either shows you. It is easy to miss precisely because the test *looks*
behavioural: it runs the real script and checks a real status.

**How to apply:** for any case named after a specific path through the code, ask
what the mutant would change in the OUTPUT, not just in the status — then assert
that. If the only answer is the exit code, the fixture is too rich: strip it to
the one file the property is about, or add the consequence assertion. Always run
the mutant; a case that survives it is documentation, not a test. See
[[staged-tree-checks-need-checkout-index]] for the guard this was found in, and
[[mutation-round-finds-the-untested-rule]] for why the round is what surfaces it.
