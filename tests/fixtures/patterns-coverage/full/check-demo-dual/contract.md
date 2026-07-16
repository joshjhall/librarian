# check-demo-dual — Output Contract

Fixture contract for the patterns-coverage gate (dual-impl union arm). Declares
two categories: `sh-finding` is emitted by the sibling patterns.sh and
`py-finding` ONLY by the sibling patterns.py. The tool must union slugs across
BOTH files, so this domain scores 2/2 (100%). If emitted_categories() read only
patterns.sh, `py-finding` would be reported missing and the domain would fall to
1/2 — this fixture is the regression guard for the union.

## Categories

| Category      | Certainty | Method        | Confidence |
| ------------- | --------- | ------------- | ---------- |
| `sh-finding`  | HIGH      | deterministic | >= 0.9     |
| `py-finding`  | HIGH      | deterministic | >= 0.9     |

## Finding Format

Standard finding-schema.md. No category slugs outside the table above.
