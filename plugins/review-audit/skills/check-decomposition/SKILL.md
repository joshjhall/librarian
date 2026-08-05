---
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
| `ai-file-bloat`      | CLAUDE.md / SKILL.md / agent md over its per-type threshold   |
| `doc-file-bloat`     | `docs/*.md` over its threshold                                |
| `decomposition-seam` | A concrete cut point — or a **reasoned decline** to split     |

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
