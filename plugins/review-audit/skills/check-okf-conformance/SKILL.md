---
description: Deterministic Open Knowledge Format (OKF) pre-scan for a memory bundle — schema conformance (type, frontmatter, reserved files, version drift) plus whole-bundle health (orphans, dangling index lines, staleness). Runs patterns.sh before LLM analysis. Used by the checker agent.
---

# check-okf-conformance

Memory-bundle validation in two passes:

1. **Conformance (per file)** — is it a conformant OKF bundle at the schema
   floor? Parseable frontmatter, a non-empty `type`, reserved files per §8/§9.
1. **Health (whole bundle, #669)** — is the bundle usable as a graph? Are
   concepts reachable from an index, do index lines point at files that exist,
   has a memory outlived its own expiry date.

The second pass exists because a bundle can be **100% conformant and unusable**:
two hundred perfectly-formed concepts that no index names are written but never
recallable. That is invisible to any per-file rule, because it is a property of
the bundle as a whole.

Still out of scope: semantic quality (near-duplicates, tier placement) is slice
C, and migration is separate. **Index SIZING is out of scope too, deliberately**
— see § Index sizing is delegated below.

**Companion files**: See `contract.md` for the output format and the
conformance-vs-health distinction the certainty tiers carry. See
`thresholds.yml` for the OKF version pin, the health pass's configurable index
names and per-type body requirements, and severity levels. The whole-bundle pass
lives in `bundle_graph.py` (mirrored by a section of `patterns.sh`).

## The floor

OKF §11 defines conformance as three things, and this scanner checks exactly
those three:

1. Every non-reserved `.md` file contains a parseable YAML frontmatter block.
1. Every such block contains a non-empty `type` field.
1. Every reserved filename (`index.md`, `log.md`) follows §8 / §9 when present.

`type` is the **sole always-required key**. A concept carrying only `type` is
fully conformant. That is the entire floor, and this validator does not invent
more.

## Permissive conformance — the rule that shapes everything

**A bundle is reported, never rejected.** Spec §11 states that a consumer MUST
NOT reject a bundle because of unknown `type` values, unrecognized extra
frontmatter keys, broken cross-links, or missing `index.md` files; §12 adds that
a consumer meeting an unfamiliar declared version SHOULD attempt best-effort
consumption rather than refusing. So **every** conformance problem this scanner
finds — version drift included — is a finding emitted at **exit 0**.

That is the opposite posture from the **runtime**, which fails loud: an
unresolvable version pin, a usage error, or an unreadable file list exits
**non-zero** with an actionable message. Failing loud because the *tool* cannot
run is correct; failing loud because the *bundle* declares something unfamiliar
is not. These two paths are kept strictly apart, with separate fixtures on each
in `tests/validate-okf-detectors.sh` — conflating them is how a validator like
this lands wrong.

## Pre-Scan Categories

`patterns.sh` detects these. Unlike a lifecycle candidate, each is decidable
from the document itself, so the structural categories are `HIGH` certainty
rather than candidates awaiting confirmation.

| Category                      | What it detects                                                                                                                                            |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `okf-missing-type`            | A non-reserved `.md` whose frontmatter has no `type` key, or whose `type` is empty/whitespace-only (§4.1). The two cases carry distinct evidence labels.     |
| `okf-unparseable-frontmatter` | No frontmatter block at all, an opening `---` that is never closed, or a line inside the block that is neither a key, a list item, a comment, nor indented. |
| `okf-version-drift`           | A bundle-root `index.md` declaring an `okf_version` that differs from the pinned version. Emitted at **LOW**, at exit 0 (§12).                              |
| `okf-reserved-file-structure` | An `index.md` carrying frontmatter other than a bundle-root `okf_version` (§8), or a `log.md` date heading that is not ISO 8601 `YYYY-MM-DD` (§9).          |

### Health categories (whole bundle, #669)

These need the whole bundle, not one file. The graph three are pure facts about
files that exist, so they emit `HIGH`; the two judgment categories emit `MEDIUM`
as candidates for Pass 2. `contract.md` § Kind states that split as a contract.

| Category                | What it detects                                                                                                                                    |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `memory-orphan`         | A concept no index names — written but never recallable. Silent when the bundle has **no** index at all: §11 forbids requiring one.                 |
| `memory-dangling-index` | An index line naming a file that does not exist. Distinct from a dangling `[[wiki-link]]`, which is **tolerated** (knowledge not yet written).      |
| `memory-multi-index`    | One concept named by two different indexes. A single index naming it twice is a repeated line, not this.                                            |
| `memory-stale`          | `stale_after` before the (injected) current date, or `status: deprecated`. Quotes the memory's own `stale_check` so the row names what to re-verify. |
| `memory-missing-why`    | A `type` whose **configured** body sections are absent. A type nobody configured has no requirement.                                                |

## Index sizing is delegated

`memory-index-bloat` is deliberately **not** implemented here. `check-decomposition`
already sizes memory indexes and recommends a topic-clustered split, measured
2026-09-05 on a 275-line `MEMORY.md`:

```text
ai-file-bloat       memory index exceeds high threshold: 275 lines (>250)
decomposition-seam  index split: 3 topic clusters (...) -> index-<topic>.md
```

Defining an index budget in this skill's `thresholds.yml` would create a second
threshold table over the same files that must agree with the first — exactly the
duplication #663 was filed to eliminate. The budgets live in
`check-decomposition/thresholds.yml` § `bloat_thresholds`; this scanner reads
none of them. `tests/validate-okf-detectors.sh` pins the delegation so it cannot
decay into a silent gap.

## Staleness is judged against an injected date

`$OKF_TODAY` overrides the current date. Production falls back to the real one,
but every fixture injects, because a staleness test pinned to the real clock
stops testing what it claims the moment the date rolls past its fixture — the
failure mode is a silent false pass, not a red test.

## Bundle discovery

The bundle root is resolved from the environment, not hardcoded:

```text
$OKF_BUNDLE_ROOT  ->  $MEMORY_BUNDLE_ROOT  ->  .claude/memory
```

`MEMORY_BUNDLE_ROOT` is `check-decomposition`'s existing convention, so one
setting moves every bundle-aware scanner together; `OKF_BUNDLE_ROOT` is the
escape hatch for a repo whose OKF bundle is not its memory bundle. Every
spelling of one root — `.claude/memory`, `./.claude/memory`, `.claude/memory/` —
is normalized so all decide alike; an unnormalized root would silently match
nothing and still exit 0.

An **empty** root means no bundle is configured, and a repo with **no bundle**
produces nothing: "nothing to check" is exit 0, not an error.

## Version pinning

The pinned OKF version lives in **exactly one place**: `okf.pinned_version` in
`thresholds.yml`, overridable by `$OKF_PINNED_VERSION`. Both `patterns.py` and
`patterns.sh` read it from there and neither carries a version literal of its
own — the same rule `ruff.toml`'s `required-version` follows in this repo. A
hardcoded copy in a consumer is how the pin drifts out of agreement with itself.

Currently pinned: **OKF v0.2**, spec checked **2026-08-19** (see
`thresholds.yml` for the source URL). An unresolvable or malformed pin is a
loud non-zero failure, because without it version drift cannot be judged at all
and an exit-0 report would describe a bundle that was never fully checked.

## Portability

No repo-specific value is hardcoded. The reserved names are the spec's
`index.md` and `log.md` and nothing else.

The health pass needs two things the spec does not define — which files are
indexes, and what a given `type` must contain — so both are **configuration with
librarian's conventions as the default**, never the contract:

| Setting                    | Default                              | Override                    |
| -------------------------- | ------------------------------------ | --------------------------- |
| `health.index_names`       | `MEMORY.md`, `index.md`, `index-*.md` | `$OKF_INDEX_NAMES`          |
| `health.body_requirements` | `feedback`/`project` need `**Why:**` + `**How to apply:**` | edit `thresholds.yml` |

`check-decomposition` hardcodes those same three index names; here they are a
default precisely **because** a consuming repo whose index is `toc.md` must not
be told its entire bundle is orphaned. A repo with an entirely different type
vocabulary gets **zero** `memory-missing-why` rows rather than a wrong one for
every file — §4.1 registers no types centrally and requires consumers to tolerate
unfamiliar ones. Pinned by a fixture: a foreign bundle validates correctly with
configuration alone and no code change.

## Pass 2 — LLM Analysis

The pre-scan decides the structural questions on its own; the LLM pass adds the
judgment a regex cannot:

- **Is a `type` value meaningful?** `type: thing` is conformant and always will
  be — the floor cannot reject it — but a reviewer can note that it carries no
  routing information, which is what `type` exists for (§4.1 asks producers to
  pick descriptive, self-explanatory values).
- **Does an `index.md` actually enumerate its directory?** §8's purpose is
  progressive disclosure; an index listing three of thirty files is structurally
  valid and functionally useless.
- **Is the declared `okf_version` a deliberate choice?** Drift is reported at
  LOW without judgment. Whether a bundle targeting an older revision is
  intentional (pinned for a reason) or stale (nobody re-read the spec) is
  context the scanner does not have.

## Exclusions

The pre-scan automatically skips:

- Any file outside the configured bundle root
- Non-markdown files inside the bundle (a `.sh` or `.py` living in a bundle is
  code, not a concept)

Findings carry a category label and at most a fragment of the offending line —
**never** a document's body. A memory bundle holds operator-specific working
notes and, in a consumer repo, material this repo has never seen.
