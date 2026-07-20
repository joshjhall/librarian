---
name: check-docs-staleness-ifs-colon-parity
description: "Latent bash↔python parity bug in check-docs-staleness — `while IFS=: read` strips a trailing colon from evidence that python keeps"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4f0940df-8211-4fd0-8e89-61fc71776f18
  modified: 2026-07-19T21:57:04.318Z
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

**Why:** genuine latent defect — a repo doc that legitimately ends a version-ref
line in `:` will silently desync bash vs python evidence.
**How to apply:** file a follow-up to fix `check-docs-staleness/patterns.sh` (and
audit the sibling `IFS=:` readers there) — likely `read -r line_num` then strip
the `NN:` prefix by hand (as get_frontmatter-style sed) instead of splitting on
`:`, so trailing colons survive. Add a fixture line ending in `:` to
`validate-checker-detectors.sh` / the differential fixture lib. Related:
[[codebase-audit-prescan-location]].
