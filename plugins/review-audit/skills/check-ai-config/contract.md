# check-ai-config — Output Contract

Reference companion for `SKILL.md`. Defines the finding format for AI config
pre-scan results.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

| Category               | Certainty | Method        | Confidence |
| ---------------------- | --------- | ------------- | ---------- |
| `agent-frontmatter`    | HIGH      | deterministic | >= 0.9     |
| `skill-frontmatter`    | HIGH      | deterministic | >= 0.9     |
| `ai-file-bloat`        | HIGH      | deterministic | >= 0.9     |
| `doc-file-bloat`       | HIGH      | deterministic | >= 0.9     |
| `claude-md-drift`      | MEDIUM    | heuristic     | 0.7-0.9    |
| `config-inconsistency` | MEDIUM    | heuristic     | 0.7-0.9    |
| `mcp-misconfiguration` | HIGH      | deterministic | >= 0.9     |
| `hook-safety`          | HIGH      | deterministic | >= 0.9     |
| `harness-logic`        | MEDIUM    | heuristic     | 0.7-0.9    |

## Finding Format

Each finding extends the standard finding-schema.md:

```json
{
  "id": "check-ai-config-001",
  "category": "agent-frontmatter",
  "severity": "high",
  "title": "Missing required frontmatter field: model",
  "description": "Agent definition is missing the required 'model' frontmatter field. Without a model specification, the agent will use the default model which may not be appropriate for its task complexity.",
  "file": "agents/my-agent/my-agent.md",
  "line_start": 1,
  "line_end": 1,
  "evidence": "Frontmatter missing 'model' field",
  "suggestion": "Add 'model: sonnet' (or fable/opus/haiku/inherit) to frontmatter",
  "effort": "trivial",
  "tags": ["ai-config"],
  "related_files": [],
  "certainty": {
    "level": "HIGH",
    "support": 1,
    "confidence": 0.95,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-ai-config"
}
```

## ID Format

`check-ai-config-<NNN>` (e.g., `check-ai-config-001`)

## agnix normalization (optional enrichment)

`agnix-normalize.{py,sh}` (Python-3.11 primary / bash-3.2 fallback, same runtime
policy and TSV contract as `patterns.*`) maps external
[agnix](https://github.com/agent-sh/agnix) `--format json` findings into the
rows above so the `checker` path can merge them with this floor. It is the
boundary object of the agnix integration spine (ADR
[`0001`](../../docs/adr/0001-agnix-check-ai-config-boundary.md); issue #397). It
is invoked exactly like the pre-scan: `agnix-normalize.sh <file-list>`.

**No-op when the binary is absent.** If the agnix executable (`AGNIX_BIN`,
default `agnix`) is not found, it emits nothing, logs one `[skip]` line to
stderr, and exits 0 — the floor stands alone. It fails loud (exit 2) only when
agnix *is* present but runs unusably: empty/unparsable output, a non-object
top level, or a `diagnostics` array holding a non-object element (both impls
buffer so no partial rows leak). A `diagnostics` value that is JSON `null` or
absent, and any diagnostic field that is `null`, coalesce to empty (matching
jq's `//`) — never a hard failure or a literal `"None"`. The bash fallback also
fails loud (exit 2) when selected without `jq`. Manifest paths pass through a
`--` end-of-options marker so a filename beginning with `-`/`--` (untrusted
tree, ADR §5) can never be parsed as an agnix flag.

### Rule-ID → category map

Keyed on the agnix **rule-ID prefix** (stable across agnix's per-rule
additions), NOT agnix's own `category` field. Only the overlap set with
check-ai-config is imported; a diagnostic whose prefix is unmapped, or whose
`file` is empty (project-level advisories like `VER-001`), is **dropped**.

| agnix rule prefix   | check-ai-config category |
| ------------------- | ------------------------ |
| `CC-AG-*`           | `agent-frontmatter`      |
| `CC-SK-*`           | `skill-frontmatter`      |
| `CC-HK-*`           | `hook-safety`            |
| `CC-MCP-*` / `MCP-*`| `mcp-misconfiguration`   |
| `CC-PL-*`           | `config-inconsistency`   |
| `CC-MEM-*`          | `claude-md-drift`        |

The `CC-MEM-*` bloat rules (`CC-MEM-009`/`CC-MEM-014`) are **agnix-disabled**
per ADR §3 (the env-tunable `ai-file-bloat` thresholds stay authoritative), so
only non-bloat memory rules (import-path drift, etc.) arrive here.

### Emitted columns

- `file` / `line` — passed through from the agnix diagnostic (agnix echoes the
  path as supplied, so downstream location-keyed dedup works).
- `category` — the mapped check-ai-config slug (never an agnix category string).
- `evidence` — `[<RULE-ID>] <message>` truncated to 80 codepoints (matching the
  pre-scan `EVIDENCE_CAP`); the rule ID is preserved inside the evidence since
  the TSV has no dedicated rule-ID column.
- `certainty` — the agnix `rule_severity` (`HIGH`/`MEDIUM`/`LOW`) passed through.
