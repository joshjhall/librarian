# check-docs-staleness — Output Contract

Reference companion for `SKILL.md`. Defines the output format and category
definitions for this skill. The checker agent reads this to validate output.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

When this contract version changes:

- **Patch** (1.0.x): new optional fields, clarifications — no consumer changes
- **Minor** (1.x.0): new categories, new required fields with defaults —
  consumers may need updates
- **Major** (x.0.0): breaking changes to category slugs or field semantics —
  consumers must update

## Categories

| Slug                 | Certainty Expectation           | Severity Range |
| -------------------- | ------------------------------- | -------------- |
| `stale-comment`      | HIGH (pre-scan) or MEDIUM (LLM) | high, medium   |
| `outdated-reference` | HIGH (pre-scan) or MEDIUM (LLM) | high, medium   |
| `expired-date`       | HIGH (pre-scan)                 | low, medium    |

## Finding Fields

Each finding follows the parent `finding-schema.md` with these additions:

| Field       | Type   | Required | Description                                 |
| ----------- | ------ | -------- | ------------------------------------------- |
| `certainty` | object | yes      | Multi-signal certainty grading              |
| `pre_scan`  | bool   | yes      | `true` if initially detected by patterns.sh |
| `skill`     | string | yes      | Always `"check-docs-staleness"`             |

### Certainty Object

```json
{
  "level": "HIGH",
  "support": 1,
  "confidence": 0.95,
  "method": "deterministic"
}
```

| Field        | Type   | Description                                        |
| ------------ | ------ | -------------------------------------------------- |
| `level`      | string | `HIGH`, `MEDIUM`, or `LOW`                         |
| `support`    | int    | Number of evidence signals supporting this finding |
| `confidence` | float  | 0.0–1.0 success rate / reliability score           |
| `method`     | string | `deterministic`, `heuristic`, or `llm`             |

**Method mapping**:

- `deterministic`: patterns.sh regex match — confidence >= 0.9
- `heuristic`: pre-scan result confirmed by LLM context — confidence >= 0.7
- `llm`: LLM judgment only, no pre-scan support — confidence >= 0.5

## ID Format

`check-docs-staleness-<NNN>` (zero-padded, e.g., `check-docs-staleness-001`)

The checker agent may re-sequence IDs during merge. Use temporary IDs
(`check-docs-staleness-tmp-001`) if running as a sub-agent.

## Example Finding

```json
{
  "id": "check-docs-staleness-001",
  "category": "stale-comment",
  "severity": "high",
  "title": "Function docstring contradicts implementation",
  "description": "The docstring for `parse_config()` says it returns a dict, but the function returns a Config object since the refactor in v2.3.",
  "file": "src/config/parser.py",
  "line_start": 42,
  "line_end": 45,
  "evidence": "Docstring: 'Returns: dict of parsed config values'. Actual return: Config(dataclass).",
  "suggestion": "Update docstring to document the Config return type and its fields.",
  "effort": "trivial",
  "tags": ["documentation", "accuracy"],
  "related_files": [],
  "certainty": {
    "level": "MEDIUM",
    "support": 1,
    "confidence": 0.85,
    "method": "heuristic"
  },
  "pre_scan": false,
  "skill": "check-docs-staleness"
}
```
