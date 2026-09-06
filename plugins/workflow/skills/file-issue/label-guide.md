# Label Guide — Taxonomy and Auto-Detection

Reference companion for `SKILL.md`. Load when assigning labels, establishing
`component/*` labels, or reviewing the full label taxonomy.

---

## Complete Label Taxonomy

### Type Labels (namespace: `type/`)

Owned by: `/workflow:file-issue`. Consumed by: `/workflow:ship-issue` (branch prefix).

| Label             | Branch Prefix | When to Apply                         |
| ----------------- | ------------- | ------------------------------------- |
| `type/bug`        | `fix/`        | Something broken that worked before   |
| `type/feature`    | `feature/`    | New capability or enhancement         |
| `type/refactor`   | `refactor/`   | Restructuring without behavior change |
| `type/docs`       | `docs/`       | Documentation-only change             |
| `type/test`       | `test/`       | Test addition or fix                  |
| `type/chore`      | `chore/`      | Dependency updates, CI, maintenance   |
| `type/operations` | `chore/`      | Infrastructure, CI/CD, deployment     |
| `type/compliance` | `chore/`      | Regulatory or compliance requirement  |

**Rule**: Every issue gets exactly one `type/*` label. Default to `type/chore`
if unclear.

### Severity Labels (namespace: `severity/`)

Owned by: `/workflow:next-issue`, `/review-audit:codebase-audit`, `/workflow:file-issue` (shared).

| Label               | Meaning                                        |
| ------------------- | ---------------------------------------------- |
| `severity/critical` | Actively causing harm, data loss, or downtime  |
| `severity/high`     | Will cause problems under normal use           |
| `severity/medium`   | Increases maintenance burden or tech debt      |
| `severity/low`      | Best-practice improvement, no immediate impact |

**Rule**: Ask the user. If they are unsure, default to `severity/medium`.

### Effort Labels (namespace: `effort/`)

Owned by: `/workflow:next-issue`, `/review-audit:codebase-audit`, `/workflow:file-issue` (shared).

| Label            | Scope Heuristic                              |
| ---------------- | -------------------------------------------- |
| `effort/trivial` | 1 file, under 30 minutes                     |
| `effort/small`   | 2-3 files in same directory, hours of work   |
| `effort/medium`  | 4-8 files or 2-3 directories, day of work    |
| `effort/large`   | 9+ files or 4+ directories, multi-day effort |

**Rule**: Estimate from file/directory count in Affected Files section. The
user can override.

### Component Labels (namespace: `component/`)

Owned by: `/workflow:file-issue`. Created on-demand.

**Convention**: Derive from the top-level directory of affected files:

- `src/auth/login.py` → `component/auth`
- `lib/payments/charge.go` → `component/payments`
- `docs/architecture/caching.md` → `component/docs`
- `tests/integration/checkout/` → `component/tests`

**Naming rules**:

- Lowercase, hyphens for separators
- Use the most meaningful directory level (usually 1st or 2nd)
- Collapse to project-specific groupings when obvious (e.g., `component/api`
  for all `src/api/**` files)
- Color: `1D76DB` (blue) for all component labels

**Creation commands** (idempotent):

- GitHub: `gh label create "component/<name>" --color 1D76DB --force`
- GitLab: `glab label create "component/<name>" --color '#1D76DB'`

### Status Labels (namespace: `status/`)

Owned by: `/workflow:next-issue`, `/workflow:ship-issue`. Do not apply from `/workflow:file-issue`.

| Label                   | Set By             |
| ----------------------- | ------------------ |
| `status/in-progress`    | `/workflow:next-issue`      |
| `status/pr-pending`     | `/workflow:ship-issue` |
| `status/commit-pending` | `/workflow:ship-issue` |
| `status/on-hold`        | Manual             |
| `status/blocked`        | Manual             |

### Audit Labels (namespace: `audit/`)

Owned by: `/review-audit:codebase-audit`. Only apply from `/workflow:file-issue` when the user
explicitly states the issue originates from an audit finding.

### Certainty Labels (namespace: `certainty/`)

Owned by: `/review-audit:codebase-audit` (via scanner agents). Orthogonal to severity —
a `severity/critical` finding can be `certainty/medium` if detected
heuristically rather than deterministically.

| Label                | Detection Method    | Action                | Example                     |
| -------------------- | ------------------- | --------------------- | --------------------------- |
| `certainty/critical` | Exact pattern match | Auto-fix with warning | Hardcoded API key in source |
| `certainty/high`     | Deterministic rule  | Auto-fix              | Empty catch block           |
| `certainty/medium`   | Heuristic + LLM     | Flag for human review | Function complexity warning |
| `certainty/low`      | LLM judgment only   | Report only           | Possible over-engineering   |

**Rule**: Derive from the detection method. Regex/AST match → high or
critical. LLM-assisted → medium or low. When uncertain, default to
`certainty/medium`.

Color: `D4A017` (gold) for all certainty labels.

**Creation commands** (idempotent):

- GitHub: `gh label create "certainty/<level>" --color D4A017 --force`
- GitLab: `glab label create "certainty/<level>" --color '#D4A017'`

---

## Auto-Detection Summary

| Namespace     | Detection Method                                   |
| ------------- | -------------------------------------------------- |
| `type/*`      | Ask user (required)                                |
| `severity/*`  | Ask user, default `medium`                         |
| `effort/*`    | Count files/directories, user can override         |
| `component/*` | Derive from file paths in Affected Files section   |
| `audit/*`     | Only if user says issue is from an audit finding   |
| `certainty/*` | From detection method (regex=high, LLM=medium/low) |
| `status/*`    | Never — managed by other skills                    |
