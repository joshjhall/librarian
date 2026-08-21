# check-decomposition — Output Contract

Reference companion for `SKILL.md`. Defines the finding format for
decomposition pre-scan results.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Category             | Certainty   | Method        | Confidence |
| -------------------- | ----------- | ------------- | ---------- |
| `file-length`        | HIGH/MEDIUM | deterministic | >= 0.9     |
| `god-module`         | MEDIUM      | deterministic | >= 0.9     |
| `ai-file-bloat`      | HIGH/MEDIUM | deterministic | >= 0.9     |
| `doc-file-bloat`     | HIGH/MEDIUM | deterministic | >= 0.9     |
| `decomposition-seam` | HIGH/LOW    | deterministic | >= 0.9     |

`file-length`, `ai-file-bloat` and `doc-file-bloat` emit **HIGH** over the high
threshold and **MEDIUM** over the warning threshold. `decomposition-seam` emits
**HIGH** for a proposed cut and **LOW** for a reasoned decline (see below).

**The three size categories are mutually exclusive — a file receives exactly one
size verdict** (#701). A file whose path matches a `bloat_thresholds` type
(CLAUDE.md/AGENTS.md, `skills/*/SKILL.md`, `agents/*.md`, `docs/*.md`, or a
**memory-bundle** `*.md`) is judged **only** against that per-type budget, on
**total lines**; `file-length` is skipped for it. Every other file is judged
**only** by `file-length`, on production LOC. Consumers can therefore treat a
size row as one problem rather than deduplicating two rows carrying two
different numbers.

`god-module` and `decomposition-seam` are unaffected: this splits the size
*verdict*, not the segmentation. An oversized `SKILL.md` still yields a seam, and
the seam-or-decline pairing holds for whichever size category fired.

### Memory-bundle rows (#700)

A bundle file under the configured root (`MEMORY_BUNDLE_ROOT`, default
`.claude/memory`) emits `ai-file-bloat` with the file-type label **`memory
index`** or **`memory concept`** — two budgets, because an index is loaded every
session (a read limit) and a concept is the cost of one recalled fact. An empty
root disables the classification: no rows, no error.

The bundle is the one type whose `decomposition-seam` row is **not** a line-range
seam. The generic markdown seam is suppressed and replaced by bundle-shaped
guidance, so consumers must not assume the `seam <start>-<end>:` grammar below
for a bundle path:

```text
.claude/memory/MEMORY.md	1	decomposition-seam	index split: 3 topic clusters (golem, review, release) -> index-<topic>.md; root keeps one pointer line per sub-index	HIGH
.claude/memory/two-lessons.md	1	decomposition-seam	concept split: extract second_thing to .claude/memory/second_thing.md AND add its index line (an extracted concept with no index line is an orphan)	HIGH
```

The concept arm's extraction target is a **sibling of the source file** — its own
directory, not the bundle root (#713). The two coincide for a flat bundle, as
above; for a concept nested below the root
(`.claude/memory/topics/two-lessons.md`) the target is
`.claude/memory/topics/second_thing.md`, so a consumer must not assume the root.

The index-line clause is unconditional on the concept arm: a split that omits it
orphans the extracted half. Unsplittable bundle files decline at `LOW` with a
reason, exactly like the code path.

## TSV row format

The shared five-column contract is unchanged:

```text
file<TAB>line<TAB>category<TAB>evidence<TAB>certainty
```

A decomposition finding is a per-file **span**, but the contract is per-line and
is **not** widened — every other `check-*` skill and all three parity gates
depend on the five columns. So `line` carries the seam **start**, and the span
end plus the seam metadata are encoded in `evidence`:

```text
src/parser.rs	412	decomposition-seam	seam 412-680: fn parse_* family (6 units, fan-in 1 <- parse_entry) -> src/parser/parse.rs	HIGH
src/parser.rs	1	file-length	820 production LOC (>500 high); 1120 total, 240 comment (21%), 60 blank, 0 test-excluded, max nesting 4, 31 top-level units	HIGH
```

### Seam evidence grammar

```text
seam <start>-<end>: <noun> <family>_* family (<n> units, <fan-in>) -> <target path>
```

- `<noun>` — `def` / `function` / `fn` / `func` / `section`, per language.
- `<fan-in>` — one of `no external references`, `fan-in <n> <- <callers>` (at or
  under the fan-in threshold, callers capped at 3, sorted), or `fan-in <n>`.
- `<target path>` — the proposed destination, a sibling module named for the
  family under a directory named for the source file.

Consumers parse `<start>`/`<end>` into `line_start`/`line_end`.

### Decline grammar

```text
declined: <reason> (<n> production LOC, <m> top-level units)
```

Emitted at **LOW** certainty when a file is over threshold but has no seam.
Reasons: `generated file — regenerate rather than split`, `single cohesive unit
— no internal seam to cut`, `majority prose/comment — length is documentation,
not logic`, `no low-coupling seam found — units are mutually referential`.

A decline is a **result**, not a silence — it records that the file was examined
and found legitimately long, and it is what a `baseline=` acknowledgment cites.

## Finding Format

Each finding extends the standard finding-schema.md:

```json
{
  "id": "check-decomposition-001",
  "category": "decomposition-seam",
  "severity": "medium",
  "title": "Extractable seam: the parse_* family in src/parser.rs",
  "description": "Lines 412-680 hold six consecutive parse_* functions referenced only by parse_entry. The span is contiguous and low-coupling, so it moves in one edit.",
  "file": "src/parser.rs",
  "line_start": 412,
  "line_end": 680,
  "evidence": "seam 412-680: fn parse_* family (6 units, fan-in 1 <- parse_entry) -> src/parser/parse.rs",
  "suggestion": "Move lines 412-680 to src/parser/parse.rs and re-export from src/parser.rs",
  "effort": "small",
  "tags": ["maintainability"],
  "related_files": [],
  "certainty": {
    "level": "HIGH",
    "support": 1,
    "confidence": 0.95,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-decomposition"
}
```

## ID Format

`check-decomposition-<NNN>` (e.g., `check-decomposition-001`)
