# loop-make-it-secure — Output Contract

Reference companion for `SKILL.md`. Defines the loop completion report format.
The pipeline orchestrator reads this to determine whether to advance.

## Contract Version

```yaml
version: "1.0"
compatible_with: "loop-contract >= 1.0"
```

## Report Format

The loop produces a JSON completion report:

```json
{
  "loop": "loop-make-it-secure",
  "status": "complete",
  "changes": [
    {
      "category": "parameterized-query",
      "file": "src/db/users.py",
      "description": "Replaced f-string SQL with parameterized query"
    }
  ],
  "blockers_resolved": [
    {
      "category": "string-interpolation-query",
      "file": "src/db/users.py",
      "line": 28,
      "resolution": "Converted to parameterized query with placeholders"
    }
  ],
  "blockers_remaining": [],
  "tests_passing": true,
  "commit": "loop(make-it-secure): harden against SQL injection"
}
```

## Change Categories

| Category              | Description                                            |
| --------------------- | ------------------------------------------------------ |
| `parameterized-query` | String-built query replaced with parameterized version |
| `input-allowlisted`   | Denylist validation replaced with allowlist            |
| `secret-externalized` | Hardcoded secret moved to environment variable         |
| `output-encoded`      | Output encoding added for context (HTML, SQL, shell)   |
| `audit-logged`        | Audit logging added for sensitive operation            |
| `function-replaced`   | Dangerous function replaced with safe alternative      |

## Status Values

| Status         | Meaning                                                    |
| -------------- | ---------------------------------------------------------- |
| `complete`     | Zero HIGH-certainty findings remain                        |
| `blocked`      | Security issue requires architectural decision             |
| `acknowledged` | Finding exists but is intentionally accepted (with reason) |
