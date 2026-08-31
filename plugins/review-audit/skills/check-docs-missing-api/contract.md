# check-docs-missing-api — Output Contract

Reference companion for `SKILL.md`. Defines the output format and category
definitions for this skill.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Slug                            | Certainty Expectation           | Severity Range |
| ------------------------------- | ------------------------------- | -------------- |
| `undocumented-public-api`       | HIGH (pre-scan) or MEDIUM (LLM) | medium, low    |
| `undocumented-complex-function` | MEDIUM (heuristic) or LOW (LLM) | medium, low    |

## Language Support

Governed by [ADR 0002](../../docs/adr/0002-scanner-language-support.md).
`M` = modeled (per-language detectors run). `L` = lexical-only (no per-language
detector; the language-agnostic detectors run under its comment model).
`—` = unsupported (not scanned).

Only `undocumented-public-api` has pre-scan dispatch; the complex-function
category is LLM-side and declares no per-language arms.

<!-- contract: check-docs-missing-api-language-support -->

| Language     | ext(s)     | public-symbol form                    | doc marker | undocumented-public-api |
| ------------ | ---------- | ------------------------------------- | ---------- | ----------------------- |
| Python       | py         | def / class, `_`-prefix is private    | `"""`      | M                       |
| JavaScript   | js, jsx    | `export function\|class\|const\|…`     | `/**`      | M                       |
| TypeScript   | ts, tsx    | as JavaScript                          | `/**`      | M                       |
| Go           | go         | func + capitalized name               | `// Name`  | M                       |
| Rust         | rs         | `pub fn\|struct\|enum\|trait\|type`    | `///`      | M                       |
| Bash         | sh, bash   | `name()` / `function name`, `_` private | `#`       | M                       |
| Ruby         | rb         | def + lowercase name                  | `#`        | M                       |
| Java, Kotlin | java, kt   | `public …`                            | `/**`      | M                       |
| Swift        | swift      | `public\|open` + `func\|class\|struct\|enum\|protocol\|actor\|typealias\|var\|let` | `///`, `/**` | M           |
| every other  | —          | —                                     | —          | —                       |

<!-- contract: end-check-docs-missing-api-language-support -->

This is the broadest coverage of the four scanners, and the only one that models
Rust and Bash today.

Two things about the Swift row (#839) are worth stating rather than inferring:

- **Both public access levels count.** Swift's default is `internal`, so an
  unmarked declaration is correctly not flagged; `public` and `open` are the two
  levels that expose API outside the module. Modifiers may appear *between* the
  access level and the declarator (`public final class`, `public static func`)
  and Swift imposes no canonical order, so the arm admits a repeated modifier
  group — the same reasoning `loc_engine.py`'s Swift `UNIT_RE` records.
- **`public let` / `public var` are API surface**, which is why the declarator
  alternation includes the binding keywords rather than only the type and
  function ones. A public stored property is part of a module's contract in a way
  a private field is not.

The doc marker is matched **explicitly** as `///` or `/**`, not left to work by
accident. `///` happens to begin with `//`, so a lazier `//`-prefix test would
appear to pass every fixture while also treating an ordinary `// TODO: fix this`
comment as documentation — suppressing a real finding. #839 AC3 asks for this
case to be pinned by a fixture rather than trusted by inspection, and it is: a
`public func` preceded by a plain `//` comment still fires.

Every detector here is **language-specific** (ADR 0002 § 3) — the dispatch is a
single chain with no trailing fallthrough arm and no unconditional detector, so an
unmodeled extension yields zero rows and no error. **No false-positive risk on an
unmodeled language.**

Note the doc-marker column *is* a per-language lexical fact, but a
**doc**-comment marker rather than a line-comment one, so it is not covered by
the normative `COMMENT_RE` table named in ADR 0002 § 2. It is declared here and
is the scanner's own.

One gap: unlike the sibling scanners this one has no general test-file exclusion
— only a Go-specific `*_test.go` skip. Test files in every other language are
scanned for undocumented public symbols.

## Finding Fields

Each finding follows the parent `finding-schema.md` with these additions:

| Field       | Type   | Required | Description                                 |
| ----------- | ------ | -------- | ------------------------------------------- |
| `certainty` | object | yes      | Multi-signal certainty grading              |
| `pre_scan`  | bool   | yes      | `true` if initially detected by patterns.sh |
| `skill`     | string | yes      | Always `"check-docs-missing-api"`           |

### Certainty Object

Same schema as `check-docs-staleness/contract.md`.

## ID Format

`check-docs-missing-api-<NNN>` (zero-padded)

## Example Finding

```json
{
  "id": "check-docs-missing-api-001",
  "category": "undocumented-public-api",
  "severity": "medium",
  "title": "Exported function lacks documentation",
  "description": "The exported function `validate_schema(data, schema, strict=False)` has 3 parameters including a non-obvious `strict` flag but no docstring.",
  "file": "src/validation.py",
  "line_start": 45,
  "line_end": 72,
  "evidence": "Function signature: def validate_schema(data: dict, schema: Schema, strict: bool = False) -> ValidationResult. No docstring. 28 lines of logic with 4 branches.",
  "suggestion": "Add docstring explaining parameters (especially `strict` behavior), return value, and possible ValidationError.",
  "effort": "small",
  "tags": ["documentation", "api"],
  "related_files": [],
  "certainty": {
    "level": "HIGH",
    "support": 2,
    "confidence": 0.9,
    "method": "heuristic"
  },
  "pre_scan": true,
  "skill": "check-docs-missing-api"
}
```
