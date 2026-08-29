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

## Language Support

Governed by [ADR 0002](../../docs/adr/0002-scanner-language-support.md).
`M` = modeled (per-language detectors run). `L` = lexical-only (no per-language
detector; the language-agnostic detectors run under its comment model).
`—` = unsupported (not scanned).

Only the four deterministic categories appear here. `unjoined-worker` and
`unbounded-growth` are LLM-only and emit no pre-scan rows, so they have no
per-language dispatch to declare.

<!-- contract: check-lifecycle-language-support -->

| Language   | ext(s)          | unreaped-subprocess | terminate-without-kill | unclosed-handle | unpaired-listener |
| ---------- | --------------- | ------------------- | ---------------------- | --------------- | ----------------- |
| Swift      | swift           | M                   | M                      | M               | M                 |
| Python     | py              | M                   | M                      | M               | —                 |
| JavaScript | js, jsx         | M                   | M                      | M               | M                 |
| TypeScript | ts, tsx         | M                   | M                      | M               | M                 |
| Go         | go              | M                   | M                      | M               | —                 |
| every other | —               | —                   | —                      | —               | —                 |

<!-- contract: end-check-lifecycle-language-support -->

Every detector in this scanner is **language-specific** (ADR 0002 § 3): all of
them sit inside an extension arm and there is no trailing fallthrough arm, so an unmodeled
file yields zero rows and no error. This scanner therefore carries **no
false-positive risk** on an unmodeled language — only missing coverage. It is the
clean end of the spectrum described in ADR 0002 § Context.

Two gaps are visible above and are not yet fixed: Python and Go have no
`unpaired-listener` arm, though both languages have listener/timer registration
idioms worth detecting.

> **Known defect — the two runtimes disagree.** This scanner skips test files
> wholesale, and its **bash** `is_test_file` uses a path-crossing glob while its
> Python twin is basename-anchored. Real source under any directory named
> `test_*/` is scanned by the Python primary and silently skipped by the bash
> fallback. The matrix above describes the intended (Python) behavior. Tracked as
> [#836](https://github.com/joshjhall/librarian/issues/836).

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
