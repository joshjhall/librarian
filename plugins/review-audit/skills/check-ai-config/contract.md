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
  "suggestion": "Add 'model: sonnet' (or opus/haiku) to frontmatter",
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
