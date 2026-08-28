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

## Language Support

Governed by [ADR 0002](../../docs/adr/0002-scanner-language-support.md).
`M` = modeled (per-language detectors run). `L` = lexical-only (no per-language
detector; the language-agnostic detectors run under its comment model).
`—` = unsupported (not scanned).

`debug-statement` is two independent detector families — a debug-print scan and a
debugger-statement scan — with **different** language coverage, so they are
separate columns here.

<!-- contract: check-code-health-language-support -->

| Language     | ext(s)          | tech-debt-marker | debug-print | debugger | empty-handler |
| ------------ | --------------- | ---------------- | ----------- | -------- | ------------- |
| Python       | py              | L                | M           | M        | M             |
| JavaScript   | js, jsx, mjs, cjs | L              | M           | M        | M (js/jsx only) |
| TypeScript   | ts, tsx         | L                | M           | M        | M             |
| Go           | go              | L                | M           | —        | M             |
| Java, Kotlin | java, kt        | L                | M           | —        | M             |
| Ruby         | rb              | L                | —           | M        | M             |
| every other  | —               | L                | —           | —        | —             |

<!-- contract: end-check-code-health-language-support -->

Two raggednesses are real and deliberate to record rather than smooth over:

- `empty-handler` covers .js/.jsx/.ts/.tsx but **not** .mjs/.cjs, while both debug
  families do. A .mjs empty `catch {}` is missed today.
- The debug-print family covers Go and Java/Kotlin but not Ruby; the
  debugger-statement family is the reverse.

Detector classification per ADR 0002 § 3:

- **lexical-independent**: `tech-debt-marker`. A `TODO`/`FIXME`/`HACK` marker
  carries the same meaning in any syntax, so it runs on every file including
  unmodeled ones — this is the case that makes ADR 0002's `L` state necessary
  rather than collapsing to "skip the file". It does **not** currently
  distinguish a marker in a comment from one in a string literal.
- **language-specific**: all three of debug-print, debugger and empty-handler.
  Each runs only under its own arm, so an unmodeled extension yields no rows from
  them.

This scanner has no lexical-dependent detector, which is why the `L` row's
consequences are benign here — unlike check-security.

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
