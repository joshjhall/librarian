# okf-migrate — Output Contract

Reference companion for `SKILL.md`. Defines the three modes' output shapes, the
edit-record format, and the exit codes.

## Contract Version

```yaml
version: "1.0"
compatible_with: "check-okf-conformance/contract.md >= 1.0"
```

## There is deliberately no `## Categories` table

Every `check-*` skill in this plugin carries one, and `bin/check-patterns-coverage.sh`
reads it to compute per-domain deterministic coverage — contract categories
versus the slugs `patterns.sh` actually emits.

This tool has none, because it emits **transforms, not findings**. A Categories
table here would be a false claim in a machine-readable place: the coverage tool
would treat a migration engine as a scanner and report a coverage figure over
rows it never emits. The naming follows from the same fact — the skill is
`okf-migrate` rather than `check-okf-migrate`, and its tool is `migrate.sh`
rather than `patterns.sh`, so neither the checker agent's `check-*` discovery nor
`tests/validate-prescans.sh`'s `patterns.sh` discovery picks it up.

Findings about a bundle come from `check-okf-conformance`. This tool consumes
that verdict's *subject* and changes it.

## Modes

| Mode | Writes? | Purpose |
| --- | --- | --- |
| `check` | never | Report what would need migrating. **The default.** |
| `plan` | never | Render the full change set as a reviewable diff. |
| `apply` | yes | Execute the plan. Explicit subcommand **and** `--confirm`. |

`check` is the default because the safe mode must be the one you get by
accident. `apply` is reachable only by naming it *and* passing `--confirm`, so
neither a bare invocation nor a typo can write.

### `check` output

One line per applicable transform, then the plan-only notes, then any ambiguity:

```text
adopt-bundle          1 file(s)     1 edit(s)  [applicable]
backfill-type         2 file(s)     2 edit(s)  [applicable]
wikilink-convert      1 file(s)     1 edit(s)  [applicable]
split-index: plan-only — requires a human decision this engine did not make
confirmed-merge: plan-only — requires a human decision this engine did not make
AMBIGUOUS  <root>/orphan.md  no inference rule matched  candidates: user, feedback, project, reference
```

A bundle needing nothing prints `bundle needs no mechanized migration`. That
line is deliberate: silence would be indistinguishable from a tool that failed
to run, which is the silence-reads-as-a-pass shape (#538/#571) this repo keeps
filing issues about.

### `plan` output

Unified-diff-shaped, every file and every edit, before anything is touched:

```text
--- a/<root>/alpha.md
+++ b/<root>/alpha.md
@@ wikilink-convert: convert wikilink(s) to bundle_relative markdown links @@
-See [[beta]] and [[missing-one|the missing one]].
+See [beta](/beta.md) and [the missing one](/missing-one.md).
# split-index: plan-only — requires a human decision this engine did not make
```

**This is also the write allowlist.** `apply` writes only paths that appear
here — see the safety model below.

## The edit record

Internal to the implementation, documented because the two runtimes must agree
on it byte for byte. Tab-separated, one per line:

```text
transform \t path \t kind \t line \t old \t new \t note
```

`kind` is `create`, `replace-line`, or `insert-line`. A `create` carries its
whole body in `new` with newlines escaped as `\n`, since the record itself is
line-oriented.

**Every field is prefixed with a colon, which the reader strips.** That is not
decoration. `read` splits on `IFS`, and when `IFS` holds a *whitespace*
character — tab is one — a run of them collapses to a single delimiter. An empty
`old` on an `insert-line` record would therefore shift every later field left by
one, landing `note` in `new`. Measured before fixing: bash rendered
`@@ backfill-type:  @@` / `-type: project` where python rendered
`@@ backfill-type: infer type: project @@` / `+type: project`. The break appears
only on records with an empty field — which is every create and every insert.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, **including "this bundle needs migrating"** |
| 1 | Usage error, unresolvable version pin, or an unreadable bundle |
| 2 | `apply` refused — dirty tree, missing `--confirm`, or a plan-only transform |
| 3 | `apply` blocked on an ambiguity requiring a human choice |

### The bundle is never rejected; the tool fails loud

The same split `check-okf-conformance` draws, and the epic (#664) says
conflating the two is how a tool like this lands wrong:

- **The bundle** is never rejected. A non-conformant bundle is precisely what
  this tool exists to fix, so every migration finding is reported at **exit 0**.
- **The tool** fails loud. A usage error, an unresolvable version pin, a refusal,
  or an ambiguity exits **non-zero** with an actionable message — a tool that
  cannot do its job must not report a clean bundle it never migrated.

Codes 2 and 3 are refusals rather than failures, and they are distinct on
purpose: 2 means *you* have something to do (commit the tree, pass `--confirm`,
make the decision yourself), 3 means the engine needs an answer it will not
invent. A caller can branch on them; a single code would force it to parse
prose.

## The safety model

`apply` enforces both halves:

1. **It refuses a dirty working tree** (`--allow-dirty` escapes), so every
   applied change is reviewable as its own diff against a clean baseline. A
   directory not under version control is **not** dirty — this tool migrates any
   repo's bundle, and refusing there would make the safety gate a portability
   bug.
2. **It writes only paths the plan listed.** The plan is the allowlist, not
   merely a preview. A transform that discovered a new file between plan and
   apply is a bug, not a permitted widening, so the mismatch is a hard error
   rather than a skip.

Partial application is not a thing. An ambiguity anywhere blocks the whole
`apply` and writes nothing — a half-migrated bundle is harder to reason about
than an unmigrated one.

## Transform applicability

| Transform | `plan` | `apply` |
| --- | --- | --- |
| `adopt-bundle` | ✓ | ✓ |
| `backfill-type` | ✓ | ✓ (ambiguous ⇒ exit 3) |
| `wikilink-convert` | ✓ | ✓ |
| `split-index` | ✓ | refused (exit 2) |
| `confirmed-merge` | ✓ | refused (exit 2) |

The split is **structural, not a preference**, and it lives in `thresholds.yml`
so it is inspectable. The three applicable transforms are mechanical: given the
bundle, the edit is determined. The two plan-only ones each execute a judgment
made somewhere else — `split-index` needs a seam chosen from
`check-decomposition`'s topic-cluster *recommendations*, and `confirmed-merge`
needs slice C's (#670) human confirmation. The engine renders what it would do
and refuses to do it.

## Guarantees every transform holds

- **Idempotent** — applying twice equals applying once, byte-compared.
- **Reversible in the checker's sense** — after `apply`, re-running
  `check-okf-conformance` yields zero rows for that transform's category.
- **Lossless on links** — an unresolvable wikilink target is converted to the
  path it *would* occupy rather than dropped. OKF §6.1 tolerates a broken link
  as knowledge not yet written, so the conversion preserves the fact that
  someone meant to link there.

All three are fixture-pinned in `tests/validate-okf-migrate.sh`.

## Portability

No librarian convention is hardcoded. Type-inference rules, the known-type
vocabulary, the link form, and which transforms may write are all
`thresholds.yml` keys with documented defaults. The bundle root is an
environment variable shared with every bundle-aware tool
(`$OKF_BUNDLE_ROOT` → `$MEMORY_BUNDLE_ROOT` → `.claude/memory`), and the OKF
version pin is read from `check-okf-conformance/thresholds.yml` — the single
source for the whole toolset, never copied here.
