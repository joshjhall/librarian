# check-docs-organization — Output Contract

Reference companion for `SKILL.md`. Defines the output format and category
definitions for this skill.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Slug                     | Certainty Expectation           | Severity Range    |
| ------------------------ | ------------------------------- | ----------------- |
| `missing-root-doc`       | HIGH (pre-scan, file missing)   | high, medium, low |
| `missing-dir-readme`     | HIGH (pre-scan) or MEDIUM (LLM) | medium, low       |
| `inconsistent-structure` | MEDIUM (heuristic) or LOW (LLM) | medium, low       |
| `doc-duplication`        | MEDIUM (heuristic) or LOW (LLM) | medium, low       |

## Finding Fields

Each finding follows the parent `finding-schema.md` with these additions:

| Field       | Type   | Required | Description                                 |
| ----------- | ------ | -------- | ------------------------------------------- |
| `certainty` | object | yes      | Multi-signal certainty grading              |
| `pre_scan`  | bool   | yes      | `true` if initially detected by patterns.sh |
| `skill`     | string | yes      | Always `"check-docs-organization"`          |

### Certainty Object

Same schema as `check-docs-staleness/contract.md`.

## ID Format

`check-docs-organization-<NNN>` (zero-padded)

## Example Finding

```json
{
  "id": "check-docs-organization-001",
  "category": "missing-root-doc",
  "severity": "medium",
  "title": "Missing LICENSE file in public repository",
  "description": "This repository has no LICENSE or LICENSE.md file. Public repositories should declare their license to clarify usage rights.",
  "file": ".",
  "line_start": 1,
  "line_end": 1,
  "evidence": "No LICENSE file found in project root. Repository appears public based on git remote URL.",
  "suggestion": "Add a LICENSE file. Common choices: MIT, Apache-2.0, or GPL-3.0.",
  "effort": "trivial",
  "tags": ["documentation", "compliance"],
  "related_files": [],
  "certainty": {
    "level": "HIGH",
    "support": 1,
    "confidence": 0.95,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-docs-organization"
}
```
