# check-demo-edge — Output Contract

Fixture contract for the patterns-coverage gate (edge-slug parity arm). Declares
two categories: `real-finding` (a normal kebab slug) and `x-finding` — a slug
whose FIRST segment is a single character. The sibling patterns.sh emits BOTH.

This pins the two extractors' agreement on the edge shape (finding #341).
`emitted_categories()` uses the strict kebab pattern
`[a-z][a-z0-9]+-[a-z][a-z0-9-]*`, whose first segment needs >= 2 chars, so it
never matches `x-finding`. contract_categories() must use the SAME shape, so it
too excludes `x-finding` — both sides symmetrically ignore it and the domain
scores **1/1** on `real-finding` (100%), with `x-finding` counted by neither.

If the asymmetry is reintroduced (contract_categories() loosened back to
`[a-z][a-z0-9-]+`), `x-finding` becomes declared-but-never-emitted: the total
climbs to 2, covered stays 1, and the `--strict 100` assertion fails. That is the
regression this fixture guards.

## Categories

| Category        | Certainty | Method        | Confidence |
| --------------- | --------- | ------------- | ---------- |
| `real-finding`  | HIGH      | deterministic | >= 0.9     |
| `x-finding`     | HIGH      | deterministic | >= 0.9     |

## Finding Format

Standard finding-schema.md. No category slugs outside the table above.
