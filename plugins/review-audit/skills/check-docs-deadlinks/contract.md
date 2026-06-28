# check-docs-deadlinks — Output Contract

Reference companion for `SKILL.md`. Defines the output format and category
definitions for this skill.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Slug                       | Certainty Expectation               | Severity Range |
| -------------------------- | ----------------------------------- | -------------- |
| `broken-relative-link`     | HIGH (pre-scan, file missing)       | high, medium   |
| `broken-anchor`            | HIGH (pre-scan) or MEDIUM (LLM)     | medium, low    |
| `suspicious-external-link` | MEDIUM (pattern match) or LOW (LLM) | medium, low    |

## Finding Fields

Each finding follows the parent `finding-schema.md` with these additions:

| Field       | Type   | Required | Description                                 |
| ----------- | ------ | -------- | ------------------------------------------- |
| `certainty` | object | yes      | Multi-signal certainty grading              |
| `pre_scan`  | bool   | yes      | `true` if initially detected by patterns.sh |
| `skill`     | string | yes      | Always `"check-docs-deadlinks"`             |

### Certainty Object

Same schema as `check-docs-staleness/contract.md`.

## ID Format

`check-docs-deadlinks-<NNN>` (zero-padded)

## Example Finding

```json
{
  "id": "check-docs-deadlinks-001",
  "category": "broken-relative-link",
  "severity": "high",
  "title": "Link to removed setup guide",
  "description": "README.md links to docs/setup-guide.md which was removed in the docs reorganization.",
  "file": "README.md",
  "line_start": 15,
  "line_end": 15,
  "evidence": "Link: [Setup Guide](docs/setup-guide.md). File does not exist. Nearest match: docs/getting-started.md",
  "suggestion": "Update link to point to docs/getting-started.md",
  "effort": "trivial",
  "tags": ["documentation", "links"],
  "related_files": ["docs/getting-started.md"],
  "certainty": {
    "level": "HIGH",
    "support": 1,
    "confidence": 0.99,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-docs-deadlinks"
}
```
