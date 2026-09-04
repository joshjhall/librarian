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
| `command-injection` | CRITICAL | deterministic | >= 0.9     |
| `insecure-deserialization` | CRITICAL | deterministic | >= 0.9 |
| `weak-randomness`  | HIGH      | deterministic | >= 0.9     |
| `tls-verification-disabled` | HIGH | deterministic | >= 0.9   |
| `permissive-cors`  | HIGH      | deterministic | >= 0.9     |
| `jwt-unverified`   | CRITICAL  | deterministic | >= 0.9     |
| `xxe-risk`         | HIGH      | deterministic | >= 0.9     |

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
| Config (`#`) | yml, yaml, ini, cfg, conf, toml, properties, env | L | L        | —              | L        | L               |
| C-family (`//`) | php, c, h, cc, cpp, hpp, cs, scala, m, mm, dart, groovy, gradle, v, zig, cr | L | L | —      | L        | L               |
| Hash (`#`)  | pl, pm, r, jl, ex, exs, nim, tcl, zsh, fish, ps1, psm1, tf, tfvars | L | L | —          | L        | L               |
| Dash (`--`) | lua, sql, hs, elm   | L              | L                     | —              | L        | L               |
| Other markers | vb, bas (`'`), erl (`%`), clj, asm (`;`), bat (`REM`), vue, svelte, html, xml (`<!--`), pas (`{`) | L | L | —  | L        | L               |
| JSON (none) | json               | L              | L                     | —              | L        | L               |
| Extensionless (`#`) | Dockerfile, Containerfile, Makefile, Jenkinsfile, Vagrantfile, Procfile, Rakefile, Gemfile, Brewfile, Justfile, Caddyfile, CMakeLists.txt | L | L | —      | L        | L               |
| Dotfiles (`#`) | .env, .npmrc, .netrc, .yarnrc, .pypirc, .dockerignore, .gitconfig, .gitignore, .editorconfig, .bashrc, .zshrc, .profile, .bash_profile, .htaccess, .mailmap | L | L | —  | L        | L               |
| Shebang (`#!`) | — (extensionless: `run`, `deploy`, `entrypoint`) | L | L | —          | L        | L               |
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

**The Swift row was audited by measurement in Phase 2 (#839) and needed no
change**, which is worth recording so the next reader does not re-derive it.
Swift already resolves in this scanner's lexical model (the `swift` key in
`COMMENT_MODEL` / the `case` arm in the bash half), so the gating works: a real
`password = "…"` in a `.swift` file fires, while the same line behind `///`, `//`
or `/*` is silent. Both directions were probed rather than reasoned about, and
both are now fixture-pinned.

Its `injection-risk` cell stays `—` deliberately. Swift has no SQL-building
idiom comparable to a Python f-string, a Ruby `#{}` interpolation or Rust's
`format!` family — the sibling arms this column implements. Swift string
interpolation is plain `\(x)`, which appears in essentially every non-trivial
string in the language, so keying on it would emit at this scanner's `HIGH`
certainty tier for ordinary formatting. That is the same trade #838 refused for
Rust's `let _ =`, reached from the other direction: a detector whose measured
hit rate cannot support its tier does not ship at that tier.

**The rows below Swift are grouped by comment MARKER, not by language family,
and that is the point.** Three review cycles each found one more group that had
silently lost coverage to the gating — config formats, then the C-family, then a
long tail including `.tf`/`.tfvars`, `.ps1`, `.pl`, `.lua`, `.vue`. Those were
not three defects; they were three instances of one, because the table was being
extended language-by-language as each omission was noticed. Keying on the marker
makes the table describe the lexical fact directly, so adding a language is
choosing an existing family rather than discovering a gap.

**A path can defeat extension keying in four different ways**, and the resolver
handles each in order — this is the part worth understanding before extending it:

| shape | example | `ext` resolves to |
| --- | --- | --- |
| extension | `app.py` | `py` — the ordinary case |
| exact basename | `Dockerfile` | `""` — no extension at all |
| dotfile | `.npmrc` | `npmrc` — a **wrong** key |
| suffixed variant | `Dockerfile.prod`, `.env.local` | `prod` / `local` — also wrong |
| shebang | `deploy`, `run`, `entrypoint` | `""` — and **no name to table** |

Of the first four, the dotfile and suffixed-variant shapes are the dangerous
ones, because they produce a key that *looks* valid and resolves to nothing,
which is indistinguishable from "unmodeled" unless you go looking. Each was found by a separate review cycle after the previous
sweep had reported the table clean — an extension-keyed probe cannot reach any of
them by construction.

Suffixed variants match by **prefix** because the suffix names a *variant of the
same artifact* by universal convention: a `Dockerfile.prod` is a Dockerfile, a
`.env.local` is an env file. An earlier draft matched `.env.*` this way while
excluding `Dockerfile.*` — that was inconsistent and measurably wrong (`ENV
PASSWORD="…"` in a `Dockerfile.prod` fired on `main` and went silent). A name that
genuinely re-keys on its suffix belongs in the exact-basename table instead.

**The fifth shape differs in KIND from the first four** (#858), which is why it
is a different mechanism rather than a longer table. Each of the first four is
closable by *enumeration*: a finite list of extensions, basenames, dotfiles,
prefixes. The set of extensionless script names is **unbounded** — a repo's bare
`run`, `deploy`, `entrypoint`, `bootstrap` — so no table reaches it. The file's
own `#!` line is the evidence instead, which is the one place `lang_of` reads
content rather than being a pure function of the path.

The read is the **last** resort and is gated on a **basename** carrying no
extension, so an ordinary `app.py` returns at the extension table and never opens
the file. `lang_of` runs once per file, so the cost is bounded at **one extra
one-line read per extensionless, untabled file**, and the read itself is capped
(512 bytes) so a newline-free binary at an extensionless path cannot pull its
whole content into the resolver. The gate is keyed to the
basename rather than the whole path deliberately: `ext` is derived from the full
path, so `.github/deploy` yields a non-empty `ext` of `github/deploy`, and a
whole-path test would skip the read for exactly the files this shape exists to
reach. Both runtimes gate on the basename; because two whole-path tests would
*agree*, the parity gate could not have caught that miss (#684).

Recognized interpreters map only to **existing** language keys, so this shape
adds no language and cannot contradict the normative table: `sh`/`bash`/`dash`/
`ksh` → `sh`; `zsh`/`fish`/`perl` → `hash`; `python` → `py`; `ruby` → `rb`;
`node` → `js`. Both spellings resolve (`#!/bin/bash` and `#!/usr/bin/env bash`,
including `env -S`), and a version suffix is stripped (`python3.11`, `perl5`).
`zsh`/`fish`/`perl` map to `hash` rather than `sh` because that is where their
*extensions* already map — a file must resolve alike by name and by content.

**An extensionless file with no recognizable shebang stays `—`, deliberately.**
That is the `/tmp/run` case from #858's reproduction, and it is a decision rather
than a remaining gap: with neither a tabled name nor a shebang there is no
evidence of a language, and defaulting to `sh` would apply a `#` comment model to
arbitrary binaries and data files — re-creating precisely the language-blind
false positives ADR 0002 exists to remove. An unrecognized interpreter
(`#!/usr/bin/env cobol`) resolves the same way, for the same reason. The
lexical-*independent* detectors still run on these files, so a real leaked key
fires regardless.

The measured baseline, over the first four shapes — 111 probe inputs: this
scanner covers **exactly what `main` covered**, with one intended class of
exception — plain-prose files (`.md`, `.txt`, `LICENSE`, `README`, `CHANGELOG`)
no longer get the *lexical-dependent* detectors, because prose is not code and
applying a comment model to it is what produced the ADR's motivating false
positives. A **real** leaked key in one of those files still fires, through the
lexical-*independent* literal patterns. That asymmetry is the three-state model
working as designed rather than a coverage loss.

JSON is the interesting row: it has **no comment syntax at all**, so its model is
a *never-matching* pattern rather than an absent one. That distinction is
load-bearing in the bash runtime specifically — the consumers pipe through
`grep -vE "$file_comment_re"`, and an **empty** ERE matches every line, so `-v`
would suppress the entire file, turning "this language has no comments" into
"this language has no findings". A fixture using a *gated* detector pins it; one
using a literal-secret pattern would not, since those never consult the model
(measured — the first draft of that fixture passed with the pattern emptied).

Every family is fixture-tested in **both** directions: its own marker suppresses,
and a foreign marker does not. The foreign half is what stops a family from
degenerating into "suppress everything", which would re-create the false-clean
this phase exists to remove.

The seven categories added by #707 (`command-injection` through `xxe-risk`) are
all **lexical-dependent** and **language-agnostic**: each matches a call shape or
configuration flag rather than a language-specific string form, so they run
wherever the comment model resolves and are skipped on an unmodeled file. Two
carry an extra filter rather than a single pattern — `insecure-deserialization`
suppresses a match carrying an explicit safe loader (`Loader=` / `safe_load`),
and `weak-randomness` requires a security-context word on the same line, which
is what keeps a UI-jitter `Math.random()` from firing.

`tls-verification-disabled` explicitly **excludes** a line that also matches
`jwt-unverified`: `verify=False` is the same token in both taxonomies, but on a
`jwt.decode(...)` line it disables a signature check rather than a TLS
certificate check, and reporting it as TLS sends the reader to the wrong fix.

Three detectors proposed alongside them — `path-traversal`, `ssrf`,
`open-redirect` — were **measured and declined** (#707, follow-up #898). Each
requires knowing that an argument *derives from* an untrusted source; the
same-line proxy for that scored 0 true positives in 8 hits over a 753-file
corpus, with request-derived hits = 0 and every hit `argv`-derived. That
supports neither HIGH nor MEDIUM, so they ship at no tier and are recorded as
`gap:` entries in `owasp-coverage.yml` carrying the numbers.

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
