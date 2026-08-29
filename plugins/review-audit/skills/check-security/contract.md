# check-security — Output Contract

Reference companion for `SKILL.md`. Defines the finding format for security
pre-scan results.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Category           | Certainty | Method        | Confidence |
| ------------------ | --------- | ------------- | ---------- |
| `hardcoded-secret` | CRITICAL  | deterministic | >= 0.9     |
| `injection-risk`   | CRITICAL  | deterministic | >= 0.9     |
| `xss-risk`         | HIGH      | deterministic | >= 0.9     |
| `insecure-crypto`  | HIGH      | deterministic | >= 0.9     |

## Language Support

Governed by [ADR 0002](../../docs/adr/0002-scanner-language-support.md).
`M` = modeled (per-language detectors run). `L` = lexical-only (no per-language
detector; the language-agnostic detectors run under its comment model).
`—` = unsupported (not scanned).

<!-- contract: check-security-language-support -->

| Language   | ext(s)             | hardcoded-secret | injection-risk | xss-risk | insecure-crypto |
| ---------- | ------------------ | ---------------- | -------------- | -------- | --------------- |
| Python     | py                 | L                | M              | L        | L               |
| JavaScript | js, jsx            | L                | M              | L        | L               |
| TypeScript | ts, tsx            | L                | M              | L        | L               |
| Ruby       | rb                 | L                | M              | L        | L               |
| every other  | —                  | L                | —              | L        | L               |

<!-- contract: end-check-security-language-support -->

`injection-risk` is the only category with per-language detectors: SQL built by
f-string (Python), template literal (JS/TS) or `#{}` interpolation (Ruby). Its
string-concatenation arm is lexical-dependent and currently ungated — see below.

Detector classification per ADR 0002 § 3:

- **lexical-independent** (may run on any file, by design): the AWS / GitHub /
  Stripe / private-key literal patterns, and all four xss-risk markers. These
  match tokens whose meaning does not depend on syntax — a leaked key or a
  `dangerouslySetInnerHTML` is as interesting inside a comment as outside one.
- **lexical-dependent** (must consult the language's comment model): the
  hardcoded-secret generic-credential denylist, insecure-crypto, and the
  injection-risk string-concatenation arm. **These are not yet gated** — the
  denylist defect is issue #837 and the gating lands in Phase 1 of #622. Until
  then this scanner applies a hardcoded C-family comment model to every file.

## Finding Format

Each finding extends the standard finding-schema.md:

```json
{
  "id": "check-security-001",
  "category": "hardcoded-secret",
  "severity": "critical",
  "title": "AWS access key detected",
  "description": "An AWS access key ID matching the AKIA prefix pattern was found hardcoded in source code. Hardcoded credentials are a critical security risk — they persist in version history and can be extracted by anyone with repository access.",
  "file": "src/config.py",
  "line_start": 42,
  "line_end": 42,
  "evidence": "AKIA... pattern matched on line 42",
  "suggestion": "Move credential to environment variable or secrets manager",
  "effort": "trivial",
  "tags": ["security"],
  "related_files": [],
  "certainty": {
    "level": "CRITICAL",
    "support": 1,
    "confidence": 0.95,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-security"
}
```

## ID Format

`check-security-<NNN>` (e.g., `check-security-001`)
