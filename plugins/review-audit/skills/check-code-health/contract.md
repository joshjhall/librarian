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
| JavaScript   | js, jsx, mjs, cjs | L              | M           | M        | M               |
| TypeScript   | ts, tsx         | L                | M           | M        | M             |
| Go           | go              | L                | M           | —        | M             |
| Java, Kotlin | java, kt        | L                | M           | —        | M             |
| Ruby         | rb              | L                | —           | M        | M             |
| Rust         | rs              | L                | M           | M        | M             |
| Swift        | swift           | L                | M           | —        | M             |
| Bash         | sh, bash        | L                | —           | —        | —             |
| every other  | —               | L                | —           | —        | —             |

<!-- contract: end-check-code-health-language-support -->

One raggedness is real and deliberate to record rather than smooth over
(a second, `empty-handler`'s missing `.mjs`/`.cjs`, was closed by #840 — see
below):

- The debug-print family covers Go and Java/Kotlin but not Ruby; the
  debugger-statement family is the reverse. Rust (#838) is in **both**: the
  `print!`/`println!`/`eprint!`/`eprintln!` macro family is stdout output and so
  is exemptible via `stdout_is_output`, while `dbg!` is a debugging aid that is
  never a program's output and therefore lives in the never-exempted debugger
  family (#680 AC3).
- Swift (#839) is in debug-print but **not** debugger, and that `—` is a real
  absence rather than an unwritten arm. Swift has no source-level breakpoint
  token to key on: a breakpoint is set in Xcode or lldb, not written in the file,
  so there is nothing analogous to `dbg!`, `pdb.set_trace` or the `debugger`
  keyword. The cell would still be `—` after an exhaustive search, which is why
  it is declared rather than left for a future phase.

`empty-handler` gained `.mjs`/`.cjs` in #840, closing an intra-scanner
contradiction: both debug families covered those extensions while this one did
not, so a `console.log` in `foo.mjs` was caught and an empty `catch {}` in the
same file was not. The split was not arbitrary — the two debug families sit
inside `# >>> shared:` sync regions and received #568's widening; this arm sits
outside one and was missed. The gap was **symmetric** across the two runtimes,
so `validate-python-ports.sh` compared two silences and passed.

Swift's `empty-handler` arm needs its own pattern rather than an extension of the
js/java one, and the reason is the whole shape of the #622 bug. Swift's `catch`
takes **no parenthesized parameter** — it binds an implicit `error`, or an
explicit pattern with no parens (`catch let e`, `catch is FooError`). The
js/java pattern is `catch\s*\([^)]*\)\s*\{\s*\}`, which requires those parens, so
it could never match Swift no matter how many extensions were added to its arm
list. A Swift `catch { }` therefore emitted **nothing at all**: the motivating
false negative of #622, reproduced before the fix and pinned by a fixture after.

The Swift debug-print arm covers `print(` and `debugPrint(`. Both are stdout
writes, so both are exemptible via `stdout_is_output` — a Swift CLI's `print()`
is its actual output, exactly as a Python CLI's is (#680/#686).

Rust's `empty-handler` arm covers the empty `Err(_) => {}` match arm (and its
`Err(_) => ()` unit-body spelling). The other Rust swallow idiom named in #838,
`let _ = fallible()`, is deliberately **not** implemented: this scanner emits at
`HIGH` with a declared confidence `>= 0.9`, and `let _ =` does not earn that.
Measured over an available Rust corpus, 723 `let _ =` lines against 2 empty
`Err(_)` arms, and the `let _ =` lines are overwhelmingly deliberate — `write!`
into a `String` (infallible by construction), `let _ = guard;` to extend an RAII
lifetime, `let _ = param;` to silence an unused warning. It is a real signal at a
lower tier (the `MEDIUM` candidate shape `check-lifecycle` uses), but this
scanner has no per-detector certainty, so the honest options were "wrong tier" or
"not yet". Revisit if `check-code-health` gains one — tracked as
[#1003](https://github.com/joshjhall/librarian/issues/1003).

Bash (#842, Phase 5) is `L` — the language-agnostic `tech-debt-marker` runs
under its `#` comment model, and **all three per-language columns are `—` by
measurement**, not for want of an arm. #842 proposed arms for both; the corpus
refused them. Measured against this repo's own shell corpus (299 tracked `.sh`
files, 119,139 lines — the corpus that issue names):

| Proposed idiom | Column | Hits | Verdict |
| --- | --- | --- | --- |
| `\|\| true` swallow | `empty-handler` | **1009** | refused — noise at this tier |
| empty `trap ''` handler | `empty-handler` | 0 | no corpus evidence |
| `set -x` | `debug-print` | 0 | nothing to detect |
| a bare `echo` statement | `debug-print` | 238 | legitimate program **output**, not debug |

`|| true` is the same shape as Rust's `let _ =` above, reached from a different
language: a real signal at a **lower** tier, unshippable at this one. At 1009
hits it would add roughly a thousand `HIGH`-certainty rows to make a handful of
genuine swallows reachable. And `echo` is not merely noisy but *wrong* here —
this scanner already records above that a shell script's stdout **is** its
output, so flagging `echo` would contradict the file's own stated model.

The distinction worth preserving: these are refusals **at HIGH**, not judgements
that the idioms are undetectable. A per-detector certainty tier would make
`|| true` shippable at `MEDIUM` for the LLM pass-2 to confirm, exactly as
`check-lifecycle` handles its candidates. Two phases have now hit this same wall
from two languages, which is what motivated filing it as
[#1003](https://github.com/joshjhall/librarian/issues/1003) rather than leaving
it implicit here.

Both refusals are pinned by **silence fixtures** — a `.sh` file carrying
`|| true` and `set -x` must emit nothing. A refusal recorded only in prose is
unfalsifiable: without the fixture, implementing the arm anyway would pass every
gate.

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

### Python docstrings are NOT modeled as comments (#841)

Phase 4 asked whether the lexical model needs a block-comment dimension for
Python's `"""…"""`. **Answered NO — line-prefix is sufficient for these
scanners.** The same answer governs `loc_engine.COMMENT_RE`'s Python entry, which
shares the question.

The cost is real and measurable. A constructed fixture whose docstring merely
*discusses* code produces HIGH-certainty rows in three scanners — here
`tech-debt-marker` on a `TODO:` and `debug-statement` on an indented
`print("…")`, plus `hardcoded-secret`/`insecure-crypto` in check-security and
`unreaped-subprocess` in check-lifecycle. So this is a declared limitation, not
an absence of one.

Three grounds for accepting it:

1. **A docstring is not lexically a comment.** It is a string literal, and a
   leading one is *the documentation these scanners exist to find*.
   `check-docs-missing-api` keys on `"""` as Python's doc marker — a comment
   model that hid docstrings would break that scanner's only Python arm. The two
   requirements are in direct opposition, and only one of them can be served by
   the same model.
2. **It needs state these scanners do not have.** Pairing an opener with its
   closer means tracking quote style, nesting, prefixes, and single-vs-triple
   across lines. Every scanner here is a **line** scanner, and the bash runtime
   cannot carry that state at all — so implementing it would guarantee exactly
   the py/sh divergence `tests/validate-python-ports.sh` exists to prevent.
3. **Measured cost on this repo: zero.** Across all 70 tracked `.py` files and
   the 99 rows the four scanners emit on them, **none** lands inside a
   docstring — checked with `ast`, by walking module/class/function bodies for a
   leading string constant, not with a quote-pairing regex. (That distinction
   matters: a first pass *did* use a regex and reported six rows, every one of
   them an artifact of mispairing quotes inside the file that defines a
   docstring regex. A measurement of docstrings must not itself be confused by
   one.) The FP needs prose that both sits in a docstring and reads like code —
   rare, and a candidate the LLM pass-2 dismisses on sight.

**A related finding from that measurement, recorded because it is the same class
in a different shape.** Widening the check from docstrings to *any* multi-line
string literal finds **3** live rows: `tech-debt-marker` firing on the words
`TODO|FIXME|XXX|HACK|WORKAROUND` inside multi-line **regex literals** — in
`loop-make-it-work/patterns.py` and `check-docs-staleness/patterns.py`, both of
which are detectors whose whole job is to match those markers. So the scanners
flag each other's patterns as tech debt.

These are true to `tech-debt-marker`'s declared contract, which is
lexical-**independent** by design (ADR 0002 § 3: *"a TODO is a TODO in any
syntax"*) and is documented above as not distinguishing a marker in a comment
from one in a string. They are noted, not fixed: suppressing them needs the same
multi-line state rejected in ground 2, and the honest scope of a marker detector
is genuinely "anywhere in the text". A project that finds them noisy should reach
for `.claude/pre-review.yml`, not for a lexical model.

Revisit only if a scanner acquires a genuine multi-line model for some other
reason; it is not worth building one for this alone.

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
