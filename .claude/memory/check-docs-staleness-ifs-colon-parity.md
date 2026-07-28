---
name: check-docs-staleness-ifs-colon-parity
description: "Latent bash↔python parity bug in check-docs-staleness — `while IFS=: read` strips a trailing colon from evidence that python keeps"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4f0940df-8211-4fd0-8e89-61fc71776f18
  modified: 2026-07-28T19:18:21.499Z
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

**Why:** genuine latent defect — a repo doc that legitimately ends a version-ref
line in `:` will silently desync bash vs python evidence.
**How to apply:** if you hit it a third time, the unblock is still "reword the
line" — but prefer picking up #549. Fix = stop splitting on `:`: `read -r raw`
then strip the `NN:` prefix explicitly (`${raw%%:*}` / `${raw#*:}`, or a
get_frontmatter-style sed), and audit the sibling `IFS=:` readers in the same
file. Add a fixture line ending in `:` to the differential corpus so the gate
covers it without waiting for a real repo file. Related:
[[codebase-audit-prescan-location]], [[issue-471-472-agnix-config-trust]].
