---
name: check-decomposition
description: Deterministic file-sizing and language-aware decomposition pre-scan. Counts production LOC with per-language test/comment exclusion and emits actionable decomposition seams (which lines move where), not just a line count. Runs patterns.sh before LLM analysis. Used by the checker agent and the audit-decomposition agent.
---

# check-decomposition

Deterministic sizing + segmentation. This is the **single source of truth for
production-LOC counting** across the audit plugins: the per-language exclusion
rules that `audit-code-health`, `audit-architecture` and `audit-ai-config` each
carried as their own drifting prose copy now live here, in code, computed once
(issue #663).

The deliverable is **the seam, not the number**. A finding names the lines to
move and where — "lines 412-680, the `parse_*` family, 6 units, fan-in 1 ←
`parse_entry` → `src/parser/parse.rs`" — because "consider splitting this file"
is advice nobody acts on.

**Companion files**: See `contract.md` for the output format and the seam
evidence grammar. See `thresholds.yml` for configurable sizes.

## Pre-Scan Categories

| Category             | What it detects                                              |
| -------------------- | ------------------------------------------------------------ |
| `file-length`        | Production LOC over the warning/high threshold                |
| `god-module`         | Size **and** many top-level units **and** several concerns    |
| `ai-file-bloat`      | CLAUDE.md / SKILL.md / agent md / **memory bundle** over its per-type threshold |
| `doc-file-bloat`     | `docs/*.md` over its threshold                                |
| `decomposition-seam` | A concrete cut point — or a **reasoned decline** to split     |

**One size verdict per file** (#701). A file matched by the per-type
`bloat_thresholds` table gets `ai-file-bloat`/`doc-file-bloat` (measured on
**total lines**) and **not** `file-length`; everything else gets `file-length`
(measured on **production LOC**). Having a per-type budget *is* the statement
that the generic code thresholds do not apply — running both produced two rows
for one problem and flagged docs pages that were under their own budget.
Segmentation is unchanged; only the verdict is exclusive.

## Memory bundles

A **memory bundle** — `.claude/memory/**` by default — is a first-class file
type with two budgets, because it holds two distinct things (#700):

- **index** (`MEMORY.md`, `index-*.md`, `index.md`) — loaded every session, so
  it is budgeted as a **read limit**: the failure mode is "too long to read",
  not "too long to maintain".
- **concept** (every other bundle `.md`) — budgeted by what one recalled fact
  should cost to load.

Before #700 a bundle file matched no arm here and fell through to the
**production-LOC code thresholds** — prose silently sized by a rule written for
source. Only `*.md` under the root is bundle prose; a `.sh`/`.py` sitting in a
bundle is code and keeps the code thresholds.

The root is **configurable** (`memory_bundle.root` / `MEMORY_BUNDLE_ROOT`), not
hardcoded. An **empty** root disables memory classification entirely — no
findings, no error — which is how a consuming repo opts out.

`thresholds.yml` is the **single authoritative source** for these budgets: the
audit lens, #695's review lens, and #669's index health all read the one table
rather than forking their own.

**Split guidance is bundle-shaped, and the generic markdown heading seam is
suppressed** — a `seam 40-96:` row would be actively wrong advice here:

- An oversized **index** splits into **topic clusters** (its `##` sections),
  each becoming an `index-<topic>.md` with the root keeping one pointer line per
  sub-index — never a line range.
- An oversized **concept** usually holds two lessons; the guidance extracts the
  second **and requires it get an index line in the same breath**. A split that
  omits that produces an orphan — an extracted concept nothing ever recalls.

## What it measures

**Generic layer** (every file): total LOC, blank lines, comment lines and
comment ratio, test lines excluded, production LOC, max nesting depth, top-level
declaration count.

**Language layer** — Python, JS/TS, Rust, Go, Shell, Markdown. Each segmenter
locates top-level units and their spans, groups **consecutive** units sharing a
name family (`parse_entry` / `parse_header` / `parse_body`), and measures each
group's **fan-in** — how much of the rest of the file reaches into that span. A
contiguous, low-fan-in group is a seam: it can be moved in one mechanical edit.

Test code is excluded **per unit** using the computed spans, which is stricter
than the "to end of file" approximation the old prose specified.

## Declining is a finding

A long file with no seam emits a `decomposition-seam` row at `LOW` certainty
recording **why** — generated artifact, single cohesive unit, majority prose, or
no low-coupling cut. A generated file, a lookup table, one exhaustive `match`
are long and correct; an auditor that cannot decline is a nuisance generator.

The decline is never a silent drop: silence is indistinguishable from "not
examined". The recorded reason is what the `baseline=` acknowledgment carries.

## Pass 2 — LLM Analysis

After the pre-scan, `audit-decomposition` judges what the numbers cannot:
whether a proposed seam is *semantically* coherent, whether a declined file
should be split for a reason the metrics miss, and what the extracted module
should be named. `audit-architecture` consumes the LOC number from here and adds
the cross-file coupling half of `god-module`.

## Exclusions

The pre-scan skips lock files and non-source data files (JSON/YAML/TOML/INI).
Markdown is deliberately **not** skipped — it is segmented by heading hierarchy
and owns `doc-file-bloat`.

## Two lenses on the same engine

This skill is the **audit lens**: a whole-repo sweep at `300/500` production LOC.
`ship-issue`'s `sizing.{py,sh}` is the **review lens**, running per-PR at
`500/800` with per-language overrides (#695).

They share the LOC engine — the per-language comment/test/blank exclusion rules —
through `# >>> shared:loc-*` sentinel regions kept byte-identical by
`tests/validate-shared-scanner-sync.sh`, because the two plugins install
independently and a sourced library is impossible across that boundary.

The thresholds differ **on purpose**, and `thresholds.yml` records why: an audit
produces a backlog somebody triages later and can afford to nag; a per-PR gate
spends a reviewer's attention every time and gets switched off if it fires on
most PRs. The review lens is also **growth-aware** — it reads a
`git diff --numstat` sidecar, so a one-line touch to a pre-existing oversized
file is informational rather than blocking. That is a different question ("did
this diff make it worse?"), not the same question at a higher number.
