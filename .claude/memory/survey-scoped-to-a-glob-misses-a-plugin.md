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

**The EXTENSION glob is the same trap, and easier to miss** (#928). A sweep of
`| grep -q` sites globbed `*.sh` across `tests/ plugins/ bin/`, reported 130
sites, fixed all of them, and read as complete. The adversarial review found five
more in **markdown**: `provision-agent/provision-protocol.md` embeds an
`agent-entrypoint.sh` that is written to disk and executed under
`set -uo pipefail`, and `ship-issue/execute-protocol.md` carries agent-run
recipes, one gating a `--delete-branch` decision. Executable code in this repo
lives in `.sh`, in `.md` fenced blocks, in `justfile`, and in `.yml` `run:`
blocks — an extension glob encodes a guess about **file type** exactly the way a
directory glob encodes one about location.

The irony is instructive: that sweep existed to close a class where a check
silently reads clean over the wrong input. Scoping it to `*.sh` reproduced the
very shape it was fixing — which is the tell that a corpus choice is a claim, not
a detail.

**How to apply:** grep for the **defective line itself** across all of
`plugins/` before believing a survey's population count — one `grep -rln` over
the idiom is cheaper than the survey and bounds it. Run it **without**
`--include` first and read what the extra hits are; only then narrow. Treat any
glob-scoped survey result — directory **or** extension — as a lower bound, and
say so when reporting it. When a gate enforces the sweep, check whether the
gate's own corpus matches the sweep's: `lint-shell-portability.sh` walks
`plugins/ tests/ bin/` for `*.sh`, so the markdown sites are fixed but NOT
guarded, and that gap belongs in the report rather than in the silence. Related:
[[harden-one-knob-grep-every-sibling]], [[mutation-round-finds-the-untested-rule]],
[[whole-repo-diff-bounded-by-repo-content]].
