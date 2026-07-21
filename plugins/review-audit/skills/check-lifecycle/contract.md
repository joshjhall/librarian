# check-lifecycle — Output Contract

Reference companion for `SKILL.md`. Defines the finding format for
resource-lifecycle pre-scan results.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

The deterministic categories emit at certainty `MEDIUM` (method
`deterministic`): the pre-scan flags a *candidate* the LLM pass confirms, not an
auto-fixable definite defect. `unjoined-worker` and `unbounded-growth` are
LLM-only (no pre-scan rows).

| Category                 | Certainty   | Method                | Confidence |
| ------------------------ | ----------- | --------------------- | ---------- |
| `unreaped-subprocess`    | MEDIUM      | deterministic + llm   | >= 0.7     |
| `terminate-without-kill` | MEDIUM      | deterministic + llm   | >= 0.7     |
| `unclosed-handle`        | MEDIUM      | deterministic         | >= 0.7     |
| `unpaired-listener`      | MEDIUM      | deterministic + llm   | >= 0.7     |
| `unjoined-worker`        | MEDIUM      | llm                   | >= 0.5     |
| `unbounded-growth`       | MEDIUM/LOW  | llm                   | >= 0.5     |

## Finding Format

Each finding extends the standard finding-schema.md:

```json
{
  "id": "check-lifecycle-001",
  "category": "unreaped-subprocess",
  "severity": "medium",
  "title": "Subprocess spawned without a visible reap",
  "description": "A subprocess is spawned here with no wait/reap on the same scope. If the paired reap does not run on the error/timeout path, the child can survive as a zombie or orphan — especially when detached onto a persistent side-channel (a socket or named session) that language-level reaping never touches.",
  "file": "src/capture.swift",
  "line_start": 42,
  "line_end": 42,
  "evidence": "let task = Process()",
  "suggestion": "Ensure the process is reaped on every path (waitUntilExit()/.wait()), including error and timeout branches, and torn down explicitly if detached",
  "effort": "small",
  "tags": ["reliability"],
  "related_files": [],
  "certainty": {
    "level": "MEDIUM",
    "support": 1,
    "confidence": 0.7,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-lifecycle"
}
```

## ID Format

`check-lifecycle-<NNN>` (e.g., `check-lifecycle-001`)
