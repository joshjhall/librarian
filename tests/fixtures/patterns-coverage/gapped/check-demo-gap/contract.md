# check-demo-gap — Output Contract

Fixture contract for the patterns-coverage gate. The contract declares three
categories but the sibling patterns.sh emits only one, so this domain scores
1/3 (33%) — enough to fail `--strict 100` and pass `--strict 0`.

## Categories

| Category          | Certainty | Method        | Confidence |
| ----------------- | --------- | ------------- | ---------- |
| `alpha-finding`   | HIGH      | deterministic | >= 0.9     |
| `gamma-finding`   | HIGH      | heuristic     | >= 0.7     |
| `delta-finding`   | HIGH      | heuristic     | >= 0.7     |

## Finding Format

Standard finding-schema.md. No category slugs outside the table above.
