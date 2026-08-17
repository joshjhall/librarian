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
(CLAUDE.md/AGENTS.md, `skills/*/SKILL.md`, `agents/*.md`, `docs/*.md`) is judged
**only** against that per-type budget, on **total lines**; `file-length` is
skipped for it. Every other file is judged **only** by `file-length`, on
production LOC. Consumers can therefore treat a size row as one problem rather
than deduplicating two rows carrying two different numbers.

`god-module` and `decomposition-seam` are unaffected: this splits the size
*verdict*, not the segmentation. An oversized `SKILL.md` still yields a seam, and
the seam-or-decline pairing holds for whichever size category fired.

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
