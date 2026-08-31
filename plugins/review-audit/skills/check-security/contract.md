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
| Config (`#`) | yml, yaml, ini, cfg, conf, toml, properties, env | L | L        | —              | L        | L               |
| C-family (`//`) | php, c, h, cc, cpp, hpp, cs, scala, m, mm, dart, groovy, gradle, v, zig, cr | L | L | —      | L        | L               |
| Hash (`#`)  | pl, pm, r, jl, ex, exs, nim, tcl, zsh, fish, ps1, psm1, tf, tfvars | L | L | —          | L        | L               |
| Dash (`--`) | lua, sql, hs, elm   | L              | L                     | —              | L        | L               |
| Other markers | vb, bas (`'`), erl (`%`), clj, asm (`;`), bat (`REM`), vue, svelte, html, xml (`<!--`), pas (`{`) | L | L | —  | L        | L               |
| JSON (none) | json               | L              | L                     | —              | L        | L               |
| Extensionless (`#`) | Dockerfile, Containerfile, Makefile, Jenkinsfile, Vagrantfile, Procfile, Rakefile, Gemfile, Brewfile, Justfile, Caddyfile, CMakeLists.txt | L | L | —      | L        | L               |
| Dotfiles (`#`) | .env, .npmrc, .netrc, .yarnrc, .pypirc, .dockerignore, .gitconfig, .gitignore, .editorconfig, .bashrc, .zshrc, .profile, .bash_profile, .htaccess, .mailmap | L | L | —  | L        | L               |
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

The last two are the dangerous ones, because they produce a key that *looks*
valid and resolves to nothing, which is indistinguishable from "unmodeled" unless
you go looking. Each was found by a separate review cycle after the previous
sweep had reported the table clean — an extension-keyed probe cannot reach any of
them by construction.

Suffixed variants match by **prefix** because the suffix names a *variant of the
same artifact* by universal convention: a `Dockerfile.prod` is a Dockerfile, a
`.env.local` is an env file. An earlier draft matched `.env.*` this way while
excluding `Dockerfile.*` — that was inconsistent and measurably wrong (`ENV
PASSWORD="…"` in a `Dockerfile.prod` fired on `main` and went silent). A name that
genuinely re-keys on its suffix belongs in the exact-basename table instead.

The measured baseline, over all four shapes — 111 probe inputs: this
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
