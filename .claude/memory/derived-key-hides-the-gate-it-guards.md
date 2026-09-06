---
name: derived-key-hides-the-gate-it-guards
description: A gate keyed off a value derived from the WHOLE path silently excludes the very inputs it targets; key it off the component the rule is about
metadata:
  type: feedback
---

When gating an expensive step on "this file has no extension", do not test the
caller's derived `ext` — test the **basename**. In `check-security/patterns.py`
the caller computes `ext = path.rsplit(".", 1)[-1] if "." in path else ""`, over
the **whole path**, so `.github/deploy` yields a non-empty `ext` of
`github/deploy`. A `if not ext:` gate therefore skips the shebang read for every
extensionless script under a dotted directory (`.github/`, `node_modules/.bin/`)
— exactly the files the shape existed to reach.

**Why:** the derived value answered a *different question* than the one the gate
asks. `ext` is "what does the extension table look up"; the gate needs "did this
NAME carry an extension". They agree on flat paths and diverge on nested ones, so
the flat-path probe that motivated the feature cannot expose it.

**How to apply:** when a guard reuses a value someone else derived, ask what that
value is *of* — the path, the basename, the line — and whether that matches the
guard's own subject. Then build the fixture on a path where the two disagree
(a dotted DIRECTORY, not a dotted file). Note a bash↔python parity gate is blind
here: both halves testing the whole path **agree**, so parity is green on the
shared miss — see [[parity-gate-hides-shared-defect]] and
[[whole-repo-diff-bounded-by-repo-content]]. Related:
[[fixture-must-express-the-divergent-case]].
