# drift-detect — Output Contract

Reference companion for `SKILL.md`. Defines the drift detection report format.
The `/next-issue-ship` skill reads this when drift-detect is invoked as a
pre-ship validation step.

## Contract Version

```yaml
version: "1.0"
compatible_with: "drift-detect >= 1.0"
```

## Report Format

The skill produces a JSON drift report:

```json
{
  "skill": "drift-detect",
  "version": "1.0",
  "issue": 320,
  "branch": "feature/issue-320-drift-detect",
  "status": "drift-detected",
  "planned_files": [
    "src/feature/module.ts",
    "src/feature/helpers.ts"
  ],
  "actual_files": [
    "src/feature/module.ts",
    "src/feature/contract.ts",
    "unrelated/file.py"
  ],
  "findings": [
    {
      "category": "planned-not-touched",
      "severity": "high",
      "file": "src/feature/helpers.ts",
      "description": "Listed in Affected Files but not modified"
    },
    {
      "category": "unplanned-modification",
      "severity": "medium",
      "file": "unrelated/file.py",
      "description": "Modified but not listed in plan"
    }
  ],
  "acceptance_criteria": {
    "total": 4,
    "addressed": 3,
    "unaddressed": [
      "Integrates with next-issue-ship as optional pre-ship check"
    ]
  },
  "summary": {
    "total_findings": 2,
    "by_severity": {
      "high": 1,
      "medium": 1,
      "low": 0
    }
  }
}
```

## Finding Categories

| Category                 | Description                                    |
| ------------------------ | ---------------------------------------------- |
| `planned-not-touched`    | File listed in plan but absent from git diff   |
| `unplanned-modification` | File in git diff but absent from plan          |
| `unchecked-criteria`     | Acceptance criterion not addressed             |
| `scope-addition`         | Unplanned new functionality beyond issue scope |

## Status Values

| Status           | Meaning                                             |
| ---------------- | --------------------------------------------------- |
| `clean`          | No drift detected — implementation matches the plan |
| `drift-detected` | One or more findings at any severity level          |
| `partial`        | Plan sections missing — only partial analysis done  |
| `skipped`        | No plan sections found in issue body                |

## Severity Levels

| Severity | Meaning                                           |
| -------- | ------------------------------------------------- |
| `high`   | Planned work skipped or acceptance criteria unmet |
| `medium` | Unplanned changes that may be legitimate          |
| `low`    | Informational scope additions                     |

See `thresholds.yml` for configurable severity mappings per category.
