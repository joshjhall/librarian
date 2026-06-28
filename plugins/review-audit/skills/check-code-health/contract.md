# check-code-health — Output Contract

Reference companion for `SKILL.md`. Defines the finding format for code health
pre-scan results.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Category           | Certainty | Method        | Confidence |
| ------------------ | --------- | ------------- | ---------- |
| `tech-debt-marker` | HIGH      | deterministic | >= 0.9     |
| `debug-statement`  | HIGH      | deterministic | >= 0.9     |
| `empty-handler`    | HIGH      | deterministic | >= 0.9     |

## Finding Format

Each finding extends the standard finding-schema.md:

```json
{
  "id": "check-code-health-001",
  "category": "debug-statement",
  "severity": "medium",
  "title": "Debug print statement in production code",
  "description": "A debug print/console.log statement was found in production code. Debug statements clutter output, may leak sensitive data, and indicate incomplete development cleanup.",
  "file": "src/handler.py",
  "line_start": 42,
  "line_end": 42,
  "evidence": "print(f'debug: {response}')",
  "suggestion": "Remove debug statement or replace with proper logging",
  "effort": "trivial",
  "tags": ["maintainability"],
  "related_files": [],
  "certainty": {
    "level": "HIGH",
    "support": 1,
    "confidence": 0.95,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-code-health"
}
```

## ID Format

`check-code-health-<NNN>` (e.g., `check-code-health-001`)
