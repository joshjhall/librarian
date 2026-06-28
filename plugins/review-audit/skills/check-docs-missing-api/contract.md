# check-docs-missing-api — Output Contract

Reference companion for `SKILL.md`. Defines the output format and category
definitions for this skill.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Slug                            | Certainty Expectation           | Severity Range |
| ------------------------------- | ------------------------------- | -------------- |
| `undocumented-public-api`       | HIGH (pre-scan) or MEDIUM (LLM) | medium, low    |
| `undocumented-complex-function` | MEDIUM (heuristic) or LOW (LLM) | medium, low    |

## Finding Fields

Each finding follows the parent `finding-schema.md` with these additions:

| Field       | Type   | Required | Description                                 |
| ----------- | ------ | -------- | ------------------------------------------- |
| `certainty` | object | yes      | Multi-signal certainty grading              |
| `pre_scan`  | bool   | yes      | `true` if initially detected by patterns.sh |
| `skill`     | string | yes      | Always `"check-docs-missing-api"`           |

### Certainty Object

Same schema as `check-docs-staleness/contract.md`.

## ID Format

`check-docs-missing-api-<NNN>` (zero-padded)

## Example Finding

```json
{
  "id": "check-docs-missing-api-001",
  "category": "undocumented-public-api",
  "severity": "medium",
  "title": "Exported function lacks documentation",
  "description": "The exported function `validate_schema(data, schema, strict=False)` has 3 parameters including a non-obvious `strict` flag but no docstring.",
  "file": "src/validation.py",
  "line_start": 45,
  "line_end": 72,
  "evidence": "Function signature: def validate_schema(data: dict, schema: Schema, strict: bool = False) -> ValidationResult. No docstring. 28 lines of logic with 4 branches.",
  "suggestion": "Add docstring explaining parameters (especially `strict` behavior), return value, and possible ValidationError.",
  "effort": "small",
  "tags": ["documentation", "api"],
  "related_files": [],
  "certainty": {
    "level": "HIGH",
    "support": 2,
    "confidence": 0.9,
    "method": "heuristic"
  },
  "pre_scan": true,
  "skill": "check-docs-missing-api"
}
```
