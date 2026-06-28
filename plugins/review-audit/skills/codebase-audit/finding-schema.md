# Finding Schema — JSON Contract

Reference companion for `SKILL.md`. All scanner agents must return findings in
this exact JSON structure inside a \`\`\`json markdown fence.

---

## Complete Schema

```json
{
  "scanner": "<scanner-name>",
  "summary": {
    "files_scanned": 0,
    "total_findings": 0,
    "by_severity": { "critical": 0, "high": 0, "medium": 0, "low": 0 }
  },
  "findings": [
    {
      "id": "<scanner>-<NNN>",
      "category": "<category-slug>",
      "severity": "critical | high | medium | low",
      "title": "Short description of the finding",
      "description": "Detailed explanation with context",
      "file": "path/to/file.ext",
      "line_start": 1,
      "line_end": 50,
      "evidence": "Concrete measurement or observation",
      "suggestion": "Actionable recommendation to resolve",
      "effort": "trivial | small | medium | large",
      "tags": ["maintainability"],
      "related_files": ["path/to/related.ext"],
      "certainty": {
        "level": "HIGH",
        "support": 1,
        "confidence": 0.95,
        "method": "deterministic"
      }
    }
  ]
}
```

---

## Field Reference

### Top-Level Fields

| Field      | Type   | Required | Description                        |
| ---------- | ------ | -------- | ---------------------------------- |
| `scanner`  | string | yes      | Scanner name (e.g., `code-health`) |
| `summary`  | object | yes      | Aggregate counts for the scan      |
| `findings` | array  | yes      | List of individual finding objects |

### Summary Fields

| Field            | Type   | Required | Description                          |
| ---------------- | ------ | -------- | ------------------------------------ |
| `files_scanned`  | number | yes      | Total files the scanner examined     |
| `total_findings` | number | yes      | Total findings across all severities |
| `by_severity`    | object | yes      | Count per severity level             |

### Finding Fields

| Field           | Type     | Required | Description                                                         |
| --------------- | -------- | -------- | ------------------------------------------------------------------- |
| `id`            | string   | yes      | Unique ID: `<scanner>-<NNN>` (zero-padded, e.g., `code-health-001`) |
| `category`      | string   | yes      | Category slug from the scanner's defined set                        |
| `severity`      | string   | yes      | One of: `critical`, `high`, `medium`, `low`                         |
| `title`         | string   | yes      | One-line summary (under 80 chars)                                   |
| `description`   | string   | yes      | Full explanation with context                                       |
| `file`          | string   | yes      | Relative path from project root                                     |
| `line_start`    | number   | yes      | Starting line number (1-based)                                      |
| `line_end`      | number   | yes      | Ending line number (same as start for single-line)                  |
| `evidence`      | string   | yes      | Concrete data supporting the finding                                |
| `suggestion`    | string   | yes      | Actionable fix recommendation                                       |
| `effort`        | string   | yes      | One of: `trivial`, `small`, `medium`, `large`                       |
| `tags`          | string[] | yes      | Relevant tags (e.g., `maintainability`, `security`)                 |
| `related_files` | string[] | yes      | Other files involved (empty array if none)                          |
| `certainty`     | object   | yes      | Multi-signal certainty grading (see Certainty Grading below)        |
| `pre_scan`      | boolean  | no       | `true` if initially detected by deterministic pre-scan              |
| `skill`         | string   | no       | Name of the check-\* skill that produced this finding               |

---

## Certainty Grading

Every finding MUST include a `certainty` object. All scanners — both check-\*
skills and audit-\* agents — assign certainty based on detection method.

### Certainty Object

```json
{
  "level": "HIGH",
  "support": 1,
  "confidence": 0.95,
  "method": "deterministic"
}
```

| Field        | Type   | Description                                          |
| ------------ | ------ | ---------------------------------------------------- |
| `level`      | string | `CRITICAL`, `HIGH`, `MEDIUM`, or `LOW`               |
| `support`    | int    | Number of evidence signals supporting this finding   |
| `confidence` | float  | 0.0-1.0 reliability score                            |
| `method`     | string | `deterministic` (patterns.sh), `heuristic`, or `llm` |

### Level Definitions

| Level    | Detection Method            | Meaning                                            | Action             |
| -------- | --------------------------- | -------------------------------------------------- | ------------------ |
| CRITICAL | Deterministic (security)    | Security threat (secrets, injection) — high impact | Auto-fix + warning |
| HIGH     | Deterministic (patterns.sh) | Definite problem, safe to fix automatically        | Auto-fix           |
| MEDIUM   | Heuristic + LLM context     | Probable issue, needs context to confirm           | Flag for review    |
| LOW      | LLM judgment only           | Possible concern, requires human verification      | Report only        |

### Auto-Fix Eligibility

Findings with certainty `CRITICAL` or `HIGH` and effort `trivial` or `small`
are eligible for auto-fix when `/codebase-audit --auto-fix` is enabled. See
the Auto-Fix section in `SKILL.md`.

## Check Run Audit Trail

When the unified `checker` agent produces findings, it includes a `check_run`
object at the top level (sibling to `findings`):

```json
{
  "check_run": {
    "scope": "codebase",
    "skills_executed": ["check-docs-staleness", "check-docs-deadlinks"],
    "skills_skipped": [],
    "legacy_agents_used": [],
    "timestamp": "2026-04-03T14:30:00Z",
    "timing_ms": {
      "discovery": 50,
      "pass1_deterministic": 200,
      "pass2_heuristic": 3000,
      "pass3_judgment": 500,
      "merge": 100,
      "total": 3850
    },
    "pass_stats": {
      "deterministic_hits": 42,
      "deterministic_confirmed": 15,
      "deterministic_dismissed": 27,
      "heuristic_findings": 8,
      "judgment_findings": 2
    },
    "parallelized": false,
    "files_in_scope": 150
  }
}
```

---

## Severity Rubric

| Level      | Meaning                                        |
| ---------- | ---------------------------------------------- |
| `critical` | Actively causing harm or exploitable now       |
| `high`     | Will cause problems under normal use           |
| `medium`   | Increases maintenance burden or technical debt |
| `low`      | Best-practice improvement, no immediate impact |

## Effort Rubric

| Level     | Scope                            |
| --------- | -------------------------------- |
| `trivial` | Under 30 minutes, single file    |
| `small`   | Hours of work, few files         |
| `medium`  | Day of work, multiple files      |
| `large`   | Multi-day, cross-cutting changes |

---

## Scanner Categories

Each scanner defines its own category slugs. The orchestrator uses these for
grouping and deduplication.

### code-health

`file-length`, `function-complexity`, `code-duplication`, `naming-drift`,
`magic-numbers`, `dead-code`, `unused-import`, `tech-debt-marker`,
`deprecated-api`

### security

`injection`, `auth-bypass`, `data-exposure`, `hardcoded-secret`,
`insecure-crypto`, `missing-validation`, `dependency-cve`, `xss`

### test-gaps

`untested-public-api`, `missing-error-path-test`, `missing-edge-case`,
`low-assertion-density`, `test-quality`

### architecture

`circular-dependency`, `high-coupling`, `layer-violation`, `bus-factor`,
`inconsistent-pattern`, `god-module`, `orphaned-file`

### docs

`stale-comment`, `missing-api-docs`, `outdated-readme`, `misleading-example`

### check-docs-\* (unified check skills)

These categories are produced by the `checker` agent using check-\* skills.
They replace and expand on the `docs` scanner categories above.

- **check-docs-staleness**: `stale-comment`, `outdated-reference`, `expired-date`
- **check-docs-deadlinks**: `broken-relative-link`, `broken-anchor`, `suspicious-external-link`
- **check-docs-organization**: `missing-root-doc`, `missing-dir-readme`, `inconsistent-structure`, `doc-duplication`
- **check-docs-examples**: `broken-example`, `deprecated-example`, `incomplete-example`
- **check-docs-missing-api**: `undocumented-public-api`, `undocumented-complex-function`

### ai-config

`skill-quality`, `agent-quality`, `claude-md-drift`, `mcp-misconfiguration`,
`hook-safety`, `config-inconsistency`, `ai-file-bloat`, `doc-file-bloat`

---

## Validation Rules

Scanners must ensure:

- `id` values are unique within the scanner's output
- `id` format is `<scanner>-<NNN>` with zero-padded numbers
- `category` matches one of the scanner's defined categories
- `severity` and `effort` use only the defined enum values
- `file` paths are relative to the project root (no leading `/`)
- `line_start` \<= `line_end`
- `tags` and `related_files` are arrays (empty `[]` if none)
- JSON is valid and parseable
- Output is wrapped in a \`\`\`json markdown fence

---

## Inline Acknowledgment Comments

Developers can suppress known findings by placing an `audit:acknowledge`
comment near the relevant code. Scanners must detect, parse, and respect
these comments.

### Comment Grammar

```text
audit:acknowledge category=<slug> [date=YYYY-MM-DD] [baseline=<number>] [reason="..."]
```

- `category` (required): Must match one of the scanner's category slugs
- `date` (optional): When the acknowledgment was added (ISO 8601 date)
- `baseline` (optional): Numeric threshold to allow (e.g., `baseline=450` for
  a file-length acknowledgment at 450 lines)
- `reason` (optional): Quoted free-text explanation

The comment can appear in any language's comment syntax (`#`, `//`, `/* */`,
`<!-- -->`, etc.) on the line immediately before or on the same line as the
relevant code.

Examples:

```python
# audit:acknowledge category=file-length date=2025-06-01 baseline=450 reason="Intentionally large config module"
```

```javascript
// audit:acknowledge category=magic-numbers date=2025-03-15 reason="Protocol-defined constants"
```

```markdown
<!-- audit:acknowledge category=claude-md-drift date=2025-09-01 reason="Roadmap section, not current state" -->
```

### Scanner Behavior

1. **Parse**: Before analyzing each file, scan for `audit:acknowledge` comments
   and build a per-file acknowledgment map keyed by `(category, line_range)`
1. **Match**: When generating a finding, check the acknowledgment map for the
   same file + same category + overlapping line range (acknowledgment line
   within 5 lines of finding's `line_start`)
1. **Suppress or re-raise**:
   - **Numeric categories** (those with measurable thresholds like
     `file-length`, `function-complexity`, `code-duplication`,
     `low-assertion-density`, `ai-file-bloat`, `doc-file-bloat`): Suppress
     only if the current measurement is
     at or below the `baseline` value. If the measurement exceeds the
     baseline, re-raise with `acknowledged: true` and
     `acknowledged_baseline` set to the baseline value
   - **Boolean categories** (all others): Suppress entirely — move to
     `acknowledged_findings`
   - **Stale acknowledgments**: If `date` is present and older than 12
     months, re-raise the finding with a note that the acknowledgment
     has expired

### Schema Extensions

When acknowledgments are present, scanners add these fields:

**Top-level** (sibling to `findings`):

```json
{
  "scanner": "<scanner-name>",
  "summary": { ... },
  "findings": [ ... ],
  "acknowledged_findings": [
    {
      "id": "<scanner>-ack-<NNN>",
      "category": "<category-slug>",
      "severity": "...",
      "title": "...",
      "file": "path/to/file.ext",
      "line_start": 1,
      "line_end": 50,
      "acknowledged": true,
      "acknowledged_date": "2025-06-01",
      "acknowledged_baseline": 450,
      "acknowledged_reason": "Intentionally large config module"
    }
  ]
}
```

**Additional finding fields** (on re-raised findings in `findings` array):

| Field                   | Type    | Required | Description                                    |
| ----------------------- | ------- | -------- | ---------------------------------------------- |
| `acknowledged`          | boolean | no       | `true` if finding was previously acknowledged  |
| `acknowledged_baseline` | number  | no       | Baseline value from the acknowledgment comment |
| `acknowledged_date`     | string  | no       | Date from the acknowledgment comment           |
| `acknowledged_reason`   | string  | no       | Reason from the acknowledgment comment         |

Re-raised findings (baseline exceeded or stale) appear in `findings` with
`acknowledged: true`. Fully suppressed findings appear only in
`acknowledged_findings`.

---

## Batch Sub-Agent Output

When a scanner fans out to batch sub-agents (manifests >2000 source lines),
each sub-agent returns the same JSON schema as the parent scanner.

### Sub-Agent Conventions

- Sub-agents use **temporary IDs**: `<scanner>-tmp-<NNN>` (e.g.,
  `code-health-tmp-001`). These are never exposed outside the scanner
- The parent scanner assigns **final sequential IDs** (`code-health-001`,
  `code-health-002`, ...) after merging all sub-agent results
- `summary` fields are re-computed by the parent from the merged findings
  (sub-agent summary counts are discarded)

### Merge Protocol

The parent scanner (coordinator) performs these steps:

1. **Concatenate** all `findings` arrays from sub-agents into one list
1. **Concatenate** all `acknowledged_findings` arrays
1. **Deduplicate within-scanner**: Same file + category + overlapping line
   ranges → merge into one finding (keep broader range, combine evidence)
1. **Re-sequence IDs**: Assign final `<scanner>-<NNN>` IDs in the order
   findings appear (sorted by file path, then line number)
1. **Recompute summary**: Count `files_scanned`, `total_findings`, and
   `by_severity` from the merged findings list
