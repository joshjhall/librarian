# checker Step 7 — Direct-dispatch audit trail and return shape

On-demand companion to `../../agents/checker.md` (**Step 7: Build Audit Trail
and Return**). Load this **only on the direct-dispatch path** — a checker
invoked with no `Mode:` line, running the full Steps 1–7 pipeline and returning
a single ` ```json ` fence.

Under the `workflow.js` harness this step does not apply. Each harness mode
(`map`, `scan:<domain>`, `verify`, `aggregate`) returns its own typed object via
the `StructuredOutput` tool against the schema the harness passes, and no
`check_run` trail is built at all — see the **Modes & Structured Output** table
in `checker.md`.

## Step 7: Build Audit Trail and Return

Construct the `check_run` audit trail object:

```json
{
  "scope": "<scope parameter>",
  "skills_executed": ["check-docs-staleness", "check-docs-deadlinks"],
  "skills_skipped": [],
  "legacy_agents_used": [],
  "timestamp": "<ISO 8601>",
  "timing_ms": {
    "discovery": 0,
    "pass1_deterministic": 0,
    "pass2_heuristic": 0,
    "pass3_judgment": 0,
    "merge": 0,
    "total": 0
  },
  "pass_stats": {
    "deterministic_hits": 0,
    "deterministic_confirmed": 0,
    "deterministic_dismissed": 0,
    "heuristic_findings": 0,
    "judgment_findings": 0
  },
  "parallelized": false,
  "files_in_scope": 0
}
```

`skills_skipped` includes any project-level check-\* skill **or `audit-*`
agent** dropped by the Step 2 integrity gate (untrusted project source,
`CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS` not `1`), alongside skills skipped for
other reasons — so a suppressed hostile `SKILL.md` or project agent is visible
in the audit trail rather than silently absent. This `check_run` trail is built
only on the **direct-dispatch path** (Steps 1–7 with no `Mode:` line). Under the
harness the gate fires in **`map` mode**, whose `MAP_SCHEMA`
(`{platform, context, excluded[], domains[]}`) has no `skills_skipped` field: a
dropped project skill or agent is simply absent from `domains[]` (so no `scan`
is ever dispatched for it) and is recorded only in the
`[discovery] skipped project skill …` / `[map] skipped project agent …` **log
line**, not in structured output. The security property holds identically on
both paths — the untrusted `SKILL.md` or agent `.md` is never loaded — only the
machine-readable trail differs.

Return a single JSON object in a \`\`\`json fence:

```json
{
  "scanner": "checker",
  "check_run": { ... },
  "summary": {
    "files_scanned": 0,
    "total_findings": 0,
    "by_severity": {"critical": 0, "high": 0, "medium": 0, "low": 0},
    "by_certainty": {"HIGH": 0, "MEDIUM": 0, "LOW": 0}
  },
  "findings": [ ... ],
  "acknowledged_findings": [ ... ]
}
```

Each finding includes the standard finding-schema.md fields plus:

- `certainty`: `{"level": "HIGH|MEDIUM|LOW", "support": <int>, "confidence": <float>, "method": "deterministic|heuristic|llm"}`
- `pre_scan`: `true` if initially detected by deterministic pre-scan
- `skill`: name of the check-\* skill that produced this finding
