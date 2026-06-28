# loop-make-it-documented — Output Contract

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
  "loop": "loop-make-it-documented",
  "status": "complete",
  "changes": [
    {
      "category": "docstring-added",
      "file": "src/handler.py",
      "description": "Added docstring to process_request() with params and return"
    }
  ],
  "blockers_resolved": [
    {
      "category": "undocumented-public-function",
      "file": "src/handler.py",
      "line": 15,
      "resolution": "Added comprehensive docstring"
    }
  ],
  "blockers_remaining": [],
  "tests_passing": true,
  "commit": "loop(make-it-documented): document request handler API"
}
```

## Change Categories

| Category               | Description                                   |
| ---------------------- | --------------------------------------------- |
| `docstring-added`      | New docstring for a public function or class  |
| `readme-updated`       | README or user-facing documentation updated   |
| `changelog-entry`      | Changelog entry added for behavior change     |
| `inline-comment-added` | Design decision or "why" comment added        |
| `config-documented`    | Configuration option documented with defaults |

## Status Values

| Status     | Meaning                                             |
| ---------- | --------------------------------------------------- |
| `complete` | All public APIs documented, decision comments added |
| `blocked`  | Documentation requires design decision not yet made |
| `partial`  | Some documentation added but gaps remain            |
