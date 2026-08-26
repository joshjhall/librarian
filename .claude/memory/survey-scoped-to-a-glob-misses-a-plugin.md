---
name: survey-scoped-to-a-glob-misses-a-plugin
description: A "find every other instance" survey scoped to check-* missed four dev-core loop-* detectors with the identical defect; the new FIXTURE found them, not the survey
metadata:
  type: feedback
---

When an issue says "survey the other scanners for the same shape", scope the
survey to the **idiom**, not to a directory glob. On #754 the survey was scoped
to `check-*` and reported four scanners. It was thorough within that scope and
still missed a whole plugin: four `dev-core` `loop-make-it-*/patterns.sh`
detectors carried the identical `.lower()`-vs-literal-`case` split.

They surfaced from the **fixture**, not the survey — the new mixed-case corpus
file turned two of them red on its first run, and only then did
`grep -rln 'rsplit(".", 1)\[-1\].lower()' plugins/ --include=*.py` show the real
population.

**Why:** a glob encodes a guess about where a class of defect lives. The defect
follows the shared idiom, and idioms cross plugin boundaries freely in this repo
(the same `ext = ....lower()` line appears in `review-audit`, `dev-core`, and
`workflow`). A survey keyed to the naming convention silently under-reports, and
its confident-looking table reads as complete.

**How to apply:** grep for the **defective line itself** across all of
`plugins/` before believing a survey's population count — one `grep -rln` over
the idiom is cheaper than the survey and bounds it. Treat a directory-scoped
survey result as a lower bound, and say so when reporting it. Related:
[[harden-one-knob-grep-every-sibling]], [[mutation-round-finds-the-untested-rule]].
