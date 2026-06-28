---
description: Structured GitHub/GitLab issue creation with auto-labeling and scope enforcement. Use when filing new issues, enriching existing issues, or preparing issues for agentic workflows like /next-issue.
---

# File Issue

**Companion files**: See `templates.md` for issue body templates — load when
creating or updating issues. See `label-guide.md` for the full label taxonomy
and component convention — load when assigning labels.

## Modes

- **Create** (default): `/file-issue` or `/file-issue "short description"`
- **Update**: `/file-issue update 123` — enrich existing issue with labels,
  structured sections, and scope check

## Platform Detection

Detect from `git remote -v`:

| Pattern in remote URL     | Platform | CLI    |
| ------------------------- | -------- | ------ |
| `github.com` or `ghe.`    | GitHub   | `gh`   |
| `gitlab.com` or `gitlab.` | GitLab   | `glab` |

## Create Workflow

### Step 1 — Gather Context

- If user provided a description, use it as seed
- If on a branch with uncommitted changes, offer to infer from the diff
- Ask the user for:
  - **Type**: bug, feature, refactor, docs, test, chore, operations, compliance
  - **Brief description**: what needs to change and why
  - **Severity**: critical, high, medium, low (default: medium)
  - **Affected files/areas**: specific paths or module names (if known)

### Step 2 — Auto-Label

Apply labels using the rules in `label-guide.md`:

- **`type/*`**: From user's type answer
- **`severity/*`**: From user's severity answer
- **`effort/*`**: Estimate from Step 3 scope check (user can override)
- **`component/*`**: Derive from affected file paths. Create label if it
  does not exist:
  - GitHub: `gh label create "component/<name>" --color 1D76DB --force`
  - GitLab: `glab label create "component/<name>" --color '#1D76DB'`

### Step 3 — Scope Check

Count distinct files and directories from affected files:

| Files | Directories | Effort    |
| ----- | ----------- | --------- |
| 1     | 1           | `trivial` |
| 2-3   | 1           | `small`   |
| 4-8   | 2-3         | `medium`  |
| 9+    | 4+          | `large`   |

If `effort/large`: warn the user and offer to split into smaller issues.
This is advisory — the user can proceed with a large issue.

### Step 4 — Format and Create

1. Build the issue body from `templates.md` (base template + type-specific
   sections)
1. Create the issue with all labels applied:
   - GitHub: `gh issue create --title "{title}" --body "{body}" --label "type/{type},severity/{sev},effort/{eff},component/{comp}"`
   - GitLab: `glab issue create --title "{title}" --description "{body}" --label "type/{type},severity/{sev},effort/{eff},component/{comp}"`
   - Use a HEREDOC for the body to avoid shell quoting issues
1. Show the issue URL to the user

## Update Workflow

### Step 1 — Fetch Existing Issue

- GitHub: `gh issue view {N} --json title,body,labels`
- GitLab: `glab issue view {N}`

### Step 2 — Enrich

- Identify missing label namespaces (type, severity, effort, component)
- Ask user for any missing required labels (type, severity)
- Auto-detect effort and component from the issue body
- Reformat body into the structured template if not already formatted —
  preserve existing content as the "Context" section

### Step 3 — Apply

- GitHub: `gh issue edit {N} --add-label "{labels}" --body "{new body}"`
- GitLab: `glab issue update {N} --label "{labels}" --description "{new body}"`
- Show what changed (labels added, sections restructured)

## When to Use

- Filing a new issue for work you have identified
- Enriching poorly-labeled issues before running `/next-issue`
- Preparing issues for multi-agent orchestration (need component labels)
- Converting informal notes or Slack threads into structured issues

## When NOT to Use

- Bulk issue creation from audit findings (use `/codebase-audit`)
- Closing or shipping issues (use `/next-issue-ship`)
- Triaging existing issues without changes (just read with `gh issue view`)
