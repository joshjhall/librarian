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

`hardcoded-secret` is **two detector families with different classifications**,
so it is two columns here (the same treatment #847 gave `debug-statement`, and
for the same reason — one cell cannot carry two letters):

- `secret-literal` — the AWS / GitHub / Stripe / private-key patterns.
  Lexical-**independent**, so it runs on every file including unmodeled ones.
- `credential-assignment` — the generic `password = "…"` detector.
  Lexical-**dependent**, so it runs only where the comment model is known.

<!-- contract: check-security-language-support -->

| Language    | ext(s)             | secret-literal | credential-assignment | injection-risk | xss-risk | insecure-crypto |
| ----------- | ------------------ | -------------- | --------------------- | -------------- | -------- | --------------- |
| Python      | py                 | L              | L                     | M              | L        | L               |
| JavaScript  | js, jsx, mjs, cjs  | L              | L                     | M (js/jsx only) | L        | L               |
| TypeScript  | ts, tsx            | L              | L                     | M              | L        | L               |
| Ruby        | rb                 | L              | L                     | M              | L        | L               |
| Rust        | rs                 | L              | L                     | M              | L        | L               |
| Go          | go                 | L              | L                     | —              | L        | L               |
| Java, Kotlin | java, kt          | L              | L                     | —              | L        | L               |
| Bash        | sh, bash           | L              | L                     | —              | L        | L               |
| Swift       | swift              | L              | L                     | —              | L        | L               |
| Config      | yml, yaml, ini, cfg, conf, toml, properties, env | L | L         | —              | L        | L               |
| every other | —                  | L              | —                     | —              | L        | —               |

<!-- contract: end-check-security-language-support -->

The `every other` row is where the three states differ visibly. An unmodeled
language keeps `secret-literal` and `xss-risk` (both lexical-independent — an
`AKIA…` key is a leaked key in any syntax) but loses `credential-assignment` and
`insecure-crypto` entirely, because running them would mean applying some other
language's comment model to the file. That is ADR 0002 § 1's `—` state, and it
is **silent** per § 5: no TSV row is emitted, not even an `unsupported-language`
one.

The **Config** row is why that silence has to be reasoned about rather than
accepted. These are not source languages and are absent from the normative
`EXT_LANG` (which serves the decomposition lenses, where a `.yml` is not a unit
of code) — they are scanner-local keys, permitted because the sync gate checks
*subset*-consistency and a key the normative table lacks cannot contradict it.
They are modeled here because omitting them is a **security regression**: before
the gating the credential detector ran on every file, so a `password: "…"` in a
`docker-compose.yml` or an `application.properties` was flagged. Dropping them to
`—` would silently stop scanning exactly the file types where checked-in
credentials most often live. All of them spell a line comment with `#`.

`injection-risk` is the only category with per-language detectors: SQL built by
f-string (Python), template literal (JS/TS), `#{}` interpolation (Ruby), or
`format!` / `write!` / `push_str` (Rust). Its string-concatenation arm is
lexical-dependent and gated.

Rust needs **two** interpolation patterns rather than one alternation, because
the macros differ in argument position: `format!` takes the format string first,
while `write!`/`writeln!` take the `Write` destination first and the format
string second. A single `(format!|write!|writeln!)\s*\(\s*"` alternation makes
the `write!`/`writeln!` branches dead code — no valid call has its format string
in argument one. The JS narrowing is real: the template-literal arm dispatches on
`js`/`jsx`/`ts`/`tsx` only, so `.mjs`/`.cjs` reach the lexical-independent
detectors but not that arm.

Detector classification per ADR 0002 § 3:

- **lexical-independent** (may run on any file, by design): the AWS / GitHub /
  Stripe / private-key literal patterns, and all four xss-risk markers. These
  match tokens whose meaning does not depend on syntax — a leaked key or a
  `dangerouslySetInnerHTML` is as interesting inside a comment as outside one.
- **lexical-dependent** (consults the language's comment model, and does not run
  at all on a language this scanner cannot resolve): the `credential-assignment`
  detector, `insecure-crypto`, and the `injection-risk` string-concatenation arm.
  Gated as of #622 Phase 1, which also fixed #837 — the credential denylist was
  an *unanchored substring* test, so a `#` anywhere on the line (inside the
  secret value, or in a trailing `# noqa`) silently suppressed a real finding.
  The placeholder test now matches the extracted **value**; the comment test is
  line-start anchored and per-language.
- **language-specific** (runs only under its own `M` arm): every per-language
  `injection-risk` SQL detector.

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
