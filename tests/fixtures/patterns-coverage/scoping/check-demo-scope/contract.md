# check-demo-scope — Output Contract

Fixture contract for the patterns-coverage gate (sed-scoping arm). Declares ONE
real category, `real-finding`, in the `## Categories` table. A second
category-shaped token, `zzz-should-not-count`, appears OUTSIDE that block (in the
`## Finding Format` section below). The tool scopes contract_categories() to the
`## Categories` section via `sed -n '/^## Categories/,/^## /p'`, so the out-of-
section token must NOT be counted: the domain scores 1/1 (100%), not 1/2. If the
sed range were dropped, `zzz-should-not-count` would be picked up, the total
would climb to 2, and the `--strict 100` assertion would fail.

## Categories

| Category        | Certainty | Method        | Confidence |
| --------------- | --------- | ------------- | ---------- |
| `real-finding`  | HIGH      | deterministic | >= 0.9     |

## Finding Format

Standard finding-schema.md. This section intentionally mentions a category-shaped
token — `zzz-should-not-count` — to prove the extractor's `## Categories` scoping
excludes it. It must never appear in the coverage report.
