# check-docs-examples — Output Contract

Reference companion for `SKILL.md`. Defines the output format and category
definitions for this skill.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Slug                 | Certainty Expectation           | Severity Range |
| -------------------- | ------------------------------- | -------------- |
| `broken-example`     | HIGH (pre-scan) or MEDIUM (LLM) | high, medium   |
| `deprecated-example` | MEDIUM (heuristic) or LOW (LLM) | medium, low    |
| `incomplete-example` | LOW (LLM judgment)              | medium, low    |

## Finding Fields

Each finding follows the parent `finding-schema.md` with these additions:

| Field       | Type   | Required | Description                                 |
| ----------- | ------ | -------- | ------------------------------------------- |
| `certainty` | object | yes      | Multi-signal certainty grading              |
| `pre_scan`  | bool   | yes      | `true` if initially detected by patterns.sh |
| `skill`     | string | yes      | Always `"check-docs-examples"`              |

### Certainty Object

Same schema as `check-docs-staleness/contract.md`.

## ID Format

`check-docs-examples-<NNN>` (zero-padded)

## Example Finding

```json
{
  "id": "check-docs-examples-001",
  "category": "broken-example",
  "severity": "high",
  "title": "Example imports removed module",
  "description": "The quickstart example imports `from mylib.utils import parse_config` but the utils module was moved to `mylib.config.parser` in v3.0.",
  "file": "docs/quickstart.md",
  "line_start": 22,
  "line_end": 28,
  "evidence": "Import: `from mylib.utils import parse_config`. Module mylib/utils.py does not exist. Correct: mylib/config/parser.py",
  "suggestion": "Update import to `from mylib.config.parser import parse_config`",
  "effort": "trivial",
  "tags": ["documentation", "examples"],
  "related_files": ["mylib/config/parser.py"],
  "certainty": {
    "level": "HIGH",
    "support": 2,
    "confidence": 0.95,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-docs-examples"
}
```
