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
