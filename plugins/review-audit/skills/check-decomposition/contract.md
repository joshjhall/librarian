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
| `size-headroom`      | HIGH/MEDIUM | deterministic | >= 0.9     |

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

### What counts as production LOC in a TEST FILE (#851)

`production` is `total - blank - comment - test_excluded`, **except in a test
file, where `test_excluded` is not subtracted**. The two cases turn on how the
ecosystem places its tests, and both are deliberate:

- **Same-file conventions** — Rust `#[cfg(test)]`, Python's trailing
  `if __name__`, shell's `# --- tests ---` banner — still **subtract**. Those
  tests are not what makes the production file too big, and the exclusion keys
  off the file's **content**.
- **Separate-file conventions** — `*.test.ts`, `*.spec.js`, `test_*.py`,
  `*_test.go`, anything under `tests/**` — **do not**. There the test code *is*
  the file's content: a 3,000-line `foo.test.ts` is a 3,000-line file and splits
  by area like any other. The predicate keys off the **path** only.

`test-excluded` is still reported in every row, in both cases — it stays a
truthful diagnostic of what was classified as test code. In a test file it is
therefore **non-zero while contributing nothing to the subtraction**, so a
consumer must not re-derive `production` from the other four numbers. The
`top-level units` count follows the same rule: a test file's suites and test
functions are counted, and they cluster into seams, so an oversized test file
gets an actionable destination rather than a bare size row.

Before #851 the subtraction was unconditional and two defects compounded: a
`test_*.py` measured **0** production LOC, while a `describe`-only `.test.ts`
was never even segmented (a call expression was not a unit header, so the test
classifier was unreachable) and measured its full size by accident. The two
languages disagreed on the same construct and neither answer was the one the
sizing lens wanted.

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

**Both lenses emit these rows (#729).** The audit lens and the per-PR review
lens (`ship-issue/sizing.{py,sh}`) share the row shape through the
`bundle-seam-py` / `bundle-seam-awk` sentinel regions, so they cannot disagree
about what a bundle split looks like. What still differs is the **disposition**,
which each lens owns: the audit lens emits every row including the `LOW`
declines (a backlog reader must be able to distinguish
examined-and-unsplittable from not-scanned), while the review lens drops those
and gates the rest on its growth disposition. Bundle classification is checked
**first** on both, so a `docs/` or `agents/` directory nested inside the bundle
still gets bundle rules.

**The index-line clause is checkable, not just advisory (#729).**
`ship-issue/split-verify.{py,sh}` emits `split-memory-orphan` (HIGH) when a
split extracts a concept that no index names. Scope is decomposition-side only
— "the split just proposed must not orphan its own output". The check
classifies the **post-split** path, since the pre-split argument is typically a
temp snapshot outside the bundle root.

Whole-bundle graph health — orphans in files this split never touched, plus
dangling index lines and multi-indexed concepts — now ships in
`check-okf-conformance`'s health pass (`bundle_graph.py`, #669). The two are
complementary and neither subsumes the other: `split-verify` judges one proposed
split at the moment it is made, while the health pass audits the bundle as it
stands. **Index sizing stays here**: `check-okf-conformance` deliberately
implements no index budget of its own and delegates to this skill's
`bloat_thresholds`, so the table above remains the single source.

### CLAUDE.md / AGENTS.md need no bundle-style seam (#729)

Recorded deliberately, because the question is natural to re-ask: a
`CLAUDE.md`/`AGENTS.md` gets its file-type **budget** (#724) and the ordinary
generic markdown seam — progressive disclosure, move detail to linked files,
leave a one-line pointer. It gets **no** bundle-shaped rule.

The reason is that the bundle rules exist for a recall structure these files do
not have. An index splits by topic cluster because something routes lookups
through it; a concept carries the anti-orphan clause because an extracted
memory absent from the index is never loaded again. `CLAUDE.md` is read whole,
every session, by path — there is no index to orphan a file from, so the
invariant has nothing to protect and progressive disclosure is the complete
remedy.

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

### Headroom grammar (plan lens, #756)

`size-headroom` is emitted **only by the plan lens** (`ship-issue/plan-lens.{py,sh}`,
run from `next-issue` Phase 2) and is the one row neither other lens can produce:
it fires on a file **under** its budget, which both the audit and review lenses
return early on.

```text
<label> has <n> <unit> of headroom (<current>/<warn>); this plan adds ~<estimate>, projecting <total> — over the <limit> <band> budget. Fold the decomposition into the plan before adding to this file (<n> top-level units)
```

- `<unit>` — `production LOC` for code, `lines` for classified prose (whose
  budget is measured on total lines, per #701).
- Certainty is `HIGH` when the **projection** lands over the high threshold,
  `MEDIUM` when it lands over the warning threshold. It is graded on the
  projection, not on today's size — the file is under budget by definition here.
- Requires an estimate at or above `plan_size_thresholds.headroom_min_estimate`;
  below that floor an under-budget file stays silent whatever it projects to.

A file **already over** budget takes its ordinary `file-length` /
`ai-file-bloat` / `doc-file-bloat` category instead, with plan-lens wording that
distinguishes three cases: an estimate that grows it, a sidecar that names no
growth for it, and no sidecar at all. Unlike the review lens, the plan lens
raises an already-over file **regardless of estimate** — the planner is about to
open it anyway, which is the cheapest moment its split will ever have.

### Decline grammar

```text
declined: <reason> (<n> production LOC, <m> top-level units)
```

Emitted at **LOW** certainty when a file is over threshold but has no seam.
Reasons: `type declaration file — no runtime units to extract` (a `*.d.ts`, which
is type-level by construction), `generated file — regenerate rather than split`,
`single cohesive unit — no internal seam to cut`, `majority prose/comment —
length is documentation, not logic`, `no low-coupling seam found — units are
mutually referential`.

The declaration-file reason is tested **first**, ahead of `generated`: a `.d.ts`
is frequently banner-marked as generated too, and naming it a declaration file
is the more specific fact — it explains why there is nothing to extract even
from a hand-maintained one.

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
