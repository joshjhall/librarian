# loop-make-it-work — Output Contract

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
  "loop": "loop-make-it-work",
  "status": "complete",
  "changes": [
    {
      "category": "functionality-added",
      "file": "src/handler.py",
      "description": "Implemented request parsing and response formatting"
    }
  ],
  "blockers_resolved": [
    {
      "category": "stub-detected",
      "file": "src/handler.py",
      "line": 42,
      "resolution": "Replaced NotImplementedError with working implementation"
    }
  ],
  "blockers_remaining": [],
  "tests_passing": true,
  "commit": "loop(make-it-work): implement request handler end-to-end"
}
```

## Change Categories

| Category              | Description                                     |
| --------------------- | ----------------------------------------------- |
| `functionality-added` | New working code implementing the feature       |
| `test-added`          | Proving test for core behavior                  |
| `config-added`        | Configuration or setup required for the feature |
| `dependency-added`    | New dependency required for implementation      |

## Status Values

| Status     | Meaning                                              |
| ---------- | ---------------------------------------------------- |
| `complete` | All exit criteria met, zero HIGH blockers            |
| `blocked`  | HIGH blockers remain that require human input        |
| `partial`  | Core functionality works but proving test is missing |

## Blocker Format

Each blocker references a `patterns.sh` category and includes the resolution
or reason it remains unresolved.
