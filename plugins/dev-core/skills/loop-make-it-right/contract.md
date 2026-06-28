# loop-make-it-right — Output Contract

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
  "loop": "loop-make-it-right",
  "status": "complete",
  "changes": [
    {
      "category": "extracted-function",
      "file": "src/handler.py",
      "description": "Extracted validate_input() from process_request()"
    }
  ],
  "blockers_resolved": [
    {
      "category": "long-function",
      "file": "src/handler.py",
      "line": 15,
      "resolution": "Split into 3 focused functions"
    }
  ],
  "blockers_remaining": [],
  "tests_passing": true,
  "commit": "loop(make-it-right): extract validation and split handler"
}
```

## Change Categories

| Category              | Description                                            |
| --------------------- | ------------------------------------------------------ |
| `extracted-function`  | Duplicated or large logic extracted into a function    |
| `renamed-symbol`      | Variable, function, or class renamed for clarity       |
| `removed-duplication` | Copy-paste code replaced with shared function          |
| `applied-convention`  | Project convention or pattern applied                  |
| `reduced-nesting`     | Deep nesting flattened via early returns or extraction |

## Status Values

| Status     | Meaning                                              |
| ---------- | ---------------------------------------------------- |
| `complete` | All exit criteria met, zero HIGH blockers            |
| `blocked`  | Structural issues require architectural decision     |
| `partial`  | Some refactoring done but hard limits still exceeded |
