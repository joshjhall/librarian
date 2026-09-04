---
description: Deterministic security pre-scan for hardcoded secrets, injection risks (SQL and command), XSS, insecure deserialization, weak randomness, TLS/CORS/JWT/XXE misconfiguration, and insecure cryptography. Runs patterns.sh before LLM analysis. Used by the checker agent.
---

# check-security

Deterministic security pattern detection. The `patterns.sh` pre-scan catches
regex-matchable security findings before LLM analysis, reducing token usage
for patterns that code can detect better than a language model.

**Companion files**: See `contract.md` for the output format. See
`thresholds.yml` for configurable severity levels.

## Pre-Scan Categories

`patterns.sh` detects these security patterns:

| Category           | What it detects                                                            |
| ------------------ | -------------------------------------------------------------------------- |
| `hardcoded-secret` | AWS keys, GitHub tokens, Stripe keys, private keys, generic credentials    |
| `injection-risk`   | SQL in f-strings/template literals, string concatenation with SQL keywords |
| `xss-risk`         | Raw HTML rendering patterns (React, Vue, Django, Blade)                    |
| `insecure-crypto`  | MD5/SHA1 for security, ECB mode encryption                                 |
| `command-injection` | `shell=True`, `os.system`, `child_process.exec`, eval/exec of a non-literal |
| `insecure-deserialization` | pickle/marshal loads, `yaml.load` without a safe loader, Java `readObject`, PHP `unserialize` |
| `weak-randomness`  | Non-CSPRNG (`Math.random`, `random.random`) on a line naming a token/nonce/salt/session/key |
| `tls-verification-disabled` | Certificate checking switched off (requests, Node, Go, `NODE_TLS_REJECT_UNAUTHORIZED`) |
| `permissive-cors`  | Wildcard `Access-Control-Allow-Origin`, or an origin reflector            |
| `jwt-unverified`   | `alg: none`, or a decode call with verification disabled                  |
| `xxe-risk`         | XML parser with external entities / DTD loading enabled                   |

### What the pre-scan deliberately does NOT detect

`path-traversal`, `ssrf` and `open-redirect` are **measured gaps**, not
oversights — see the `gap:` reasons in `owasp-coverage.yml` and follow-up #898.
Each needs to know that an argument *derives from* an untrusted source, which a
line scanner cannot establish; a same-line proxy for it scored **0 true
positives in 8 hits** across a 753-file corpus. Per the tier rule below, that
ships at no tier at all.

## Pass 2 — LLM Analysis

After the pre-scan, analyze files the pre-scan missed for:

- **Context-dependent secrets**: Variables that look like credentials but need
  context to confirm (environment variable reads vs hardcoded values)
- **Injection sinks**: User input reaching dangerous functions through indirect
  paths (not just direct string concatenation)
- **Auth bypass**: Missing authentication checks on route handlers — requires
  understanding the application's auth middleware pattern
- **Data exposure**: Sensitive data in logs or error responses — requires
  understanding what constitutes PII in context
- **Missing validation**: Input boundaries without type/length checks — requires
  understanding the data flow

## Exclusions

The pre-scan automatically skips:

- Test fixtures and testdata directories
- `.env.example`, `.env.sample`, `.env.template` files
- Lock files (package-lock.json, go.sum, etc.)
- Comments (for insecure-crypto category)
- Known placeholder values (changeme, xxx, TODO, example, etc.)
