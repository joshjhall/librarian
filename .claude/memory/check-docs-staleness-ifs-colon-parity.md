---
name: check-docs-staleness-ifs-colon-parity
description: "FIXED in #549 — `while IFS=: read` ate trailing colons from pre-scan evidence; 7 patterns.py cloned the bug via a shim, so the differential gate was green on wrong output"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4f0940df-8211-4fd0-8e89-61fc71776f18
  modified: 2026-07-29T14:33:15.212Z
---

Found while shipping #397 (agnix normalizer). `check-docs-staleness/patterns.sh`
extracts outdated-reference / other categories with
`grep -nE ... | while IFS=: read -r line_num content`. Because `:` is in `IFS`,
a matched line whose content **ends in `:`** has that trailing colon **stripped**
from `content`; the python primary (`content[:EVIDENCE_CAP]`) keeps it. So a
version-ref line ending in `:` produces divergent evidence between the two impls.

**Why it stayed hidden:** no repo file previously had a version-ref line ending
in `:`. My test comment `# ...mirrors the REAL agnix 0.40.0 schema ... binary:`
was the first, and `validate-prescan-differential.sh` (runs every patterns.* pair
over the WHOLE repo tree) caught it. Reworded the comment to unblock #397; the
underlying `patterns.sh` bug is untouched.

**HIT AGAIN 2026-07-28** in PR #547 (#471/#472): an ADR line ending
`...0.40.0 and against 0.41.0:` tripped the same diff. Reworded to an em-dash,
matching the #397 precedent rather than expanding that PR's scope a 4th time.
Two occurrences, two reworkarounds, defect still live — and invisible to a future
author, who has no way to know a doc line must not end in `:`.

**NOW FILED as #549** (`type/bug`, `effort/small`) with both reproductions.

**Scope is far wider than this one file (measured 2026-07-28).** `IFS=:` appears
**86 times across `plugins/`**, and **72 of those are in 12 `patterns.sh` files
that have a `patterns.py` sibling** — i.e. every one carries the same parity
risk, not just check-docs-staleness's 4. Worst offenders: `check-security` (15),
`check-code-health` (13), `check-ai-config` (9), `loop-make-it-secure` (8),
`check-docs-missing-api` (7). `pre-review-gates.sh` has 14 more (no python port,
so no parity break — but the same evidence-mangling bug).

**Reproduce it with a SINGLE trailing colon, and no interior colon.** This is the
trap when confirming the bug: `1:ends in colon:` → content `ends in colon`
(stripped), but `1:two colons::` and `1:a:b:c:` come back **intact**, because
`read` strips one trailing IFS delimiter, not all of them. A first probe using a
line with interior colons makes the defect look like it does not exist. Verified
identical in bash 5.2 and `sh`.

Fix, verified across all shapes (`1:one:`, `1:two::`, `1:plain`, `1:a:b:c:`,
`12:Version to verify: 0.41.0:`):
`read -r raw; line_num=${raw%%:*}; content=${raw#*:}` — trailing colons survive,
interior colons preserved, line numbers correct, bash-3.2 clean.

**FIXED 2026-07-29 (#549).** All 71 bash sites across the 12 `patterns.sh` now
use `read -r raw` + `${raw%%:*}` / `${raw#*:}`. Two discoveries worth keeping:

**Seven `patterns.py` carried a `_bash_read_content` shim that deliberately
reproduced the bash strip in Python** — its docstring documented the rule
explicitly. So `validate-prescan-differential.sh` passing was never evidence of
correctness for those tools; it was evidence the bug had been cloned faithfully.
Only 5 of 12 tools could ever have diverged. Shims deleted.

**A parity gate cannot see a bug both impls share.** The regression test that
actually bites is `test_trailing_colon_preserved`, which asserts the evidence
*content* keeps its colon rather than that the two impls agree. Non-vacuity was
proven by running the new gate against a pre-fix tree: the differential fails for
2 tools, the content assertion for 4 more on **both** the bash and python side.

**`validate-shared-scanner-sync.sh` forced scope.** 7 of `pre-review-gates.sh`'s
14 sites live in the `shared:debug-statement-scan` region pinned byte-identical
against `check-code-health/patterns.sh`, so they had to move together. The other
7 are deferred to **#573** (no python port ⇒ no parity break, and that file is
the #567 measurement instrument).

**THE FIX'S OWN FIRST FIX — use `IFS= read -r raw`, never bare `read -r raw`.**
The first cut used a bare `while read -r raw`, which splits on the **default**
IFS and therefore strips leading/trailing **whitespace** from the whole record
before `${raw%%:*}` / `${raw#*:}` ever run. That traded the trailing-colon strip
for a trailing-whitespace strip — the same bash↔python divergence class, since
the python ports slice the line verbatim. Caught by the adversarial pre-PR
review at HIGH/0.92 and fixed at all 78 sites:

```bash
while IFS= read -r raw; do line_num=${raw%%:*}; content=${raw#*:}
```

Empty `IFS=` suppresses field splitting AND whitespace trimming; the prefix
strips still split on the first colon. Leading whitespace was never actually at
risk (the record starts with `grep -n`'s line number), so only the trailing case
is asserted.

**The repo-tree corpus structurally cannot catch this** — repo files are
whitespace-clean by lint, so the triggering shape never occurs there. The
fixture in `test_trailing_ws_preserved` is written via `printf` precisely so
editors and lint cannot strip the spaces out of it.

**Why:** a doc line ending in `:` silently produced wrong evidence, and the gate
that should have caught it was neutralized by a shim.
**How to apply:** when a differential/parity gate is the only coverage for a
behavior, ask whether both sides could be wrong together — if a helper exists
whose job is to make impl B match impl A's quirk, the gate is measuring
agreement, not correctness. Pin the output value, not just the delta. Related:
[[codebase-audit-prescan-location]], [[issue-471-472-agnix-config-trust]].
