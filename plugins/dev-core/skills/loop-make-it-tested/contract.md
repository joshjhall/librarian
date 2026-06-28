# loop-make-it-tested — Output Contract

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
  "loop": "loop-make-it-tested",
  "status": "complete",
  "changes": [
    {
      "category": "test-added",
      "file": "tests/test_handler.py",
      "description": "Added happy path and edge case tests for process_request()"
    }
  ],
  "blockers_resolved": [
    {
      "category": "untested-public-api",
      "file": "src/handler.py",
      "line": 15,
      "resolution": "Added test_process_request with 4 test cases"
    }
  ],
  "blockers_remaining": [],
  "tests_passing": true,
  "commit": "loop(make-it-tested): add tests for request handler"
}
```

## Change Categories

| Category          | Description                                     |
| ----------------- | ----------------------------------------------- |
| `test-added`      | New test file or test function created          |
| `test-extended`   | Existing test function extended with more cases |
| `assertion-added` | Assertion added to previously empty test        |
| `fixture-added`   | Test fixture or helper created                  |

## Status Values

| Status     | Meaning                                           |
| ---------- | ------------------------------------------------- |
| `complete` | All public APIs tested, all tests pass            |
| `blocked`  | Cannot write tests without infrastructure changes |
| `partial`  | Some tests added but coverage gaps remain         |
