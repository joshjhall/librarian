---
description: Git commit conventions, branch naming, and PR workflow. Use when committing, creating branches, reviewing PRs, or investigating git history.
---

# Git Workflow

## Commit Messages

- Use conventional commits: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`
- Keep subject line under 72 characters
- Use imperative mood, add body for non-trivial changes explaining why
- One logical change per commit — keep commits atomic and bisectable

```text
Bad:  "fixed stuff"
Bad:  "Updated the login and also refactored utils and added tests"
Good: "fix(auth): prevent session fixation on token refresh"
Good: "feat(api): add pagination to /users endpoint"
```

## Branch Naming

| Prefix           | Purpose           | Example                     |
| ---------------- | ----------------- | --------------------------- |
| `feature/<desc>` | New features      | `feature/user-pagination`   |
| `fix/<desc>`     | Bug fixes         | `fix/session-timeout-crash` |
| `chore/<desc>`   | Maintenance tasks | `chore/update-dependencies` |
| `docs/<desc>`    | Documentation     | `docs/api-authentication`   |

## Pre-commit Hooks

- Run existing hooks; don't skip with --no-verify
- Fix issues rather than bypassing checks
- If a hook fails, the commit did NOT happen — create a new commit after fixing

## PR Workflow

- Keep PRs focused and reviewable
- Include tests for new functionality
- Update documentation when changing behavior
- Use descriptive PR titles under 70 characters
- Document breaking changes with migration instructions

## Merge Strategy

- Rebase feature branches onto the target branch before merging when possible
- Resolve conflicts by understanding both sides — don't blindly accept one
- Use `git stash` to preserve work-in-progress before switching contexts
- After merge conflicts, verify tests pass before committing the resolution

## Git Archaeology

When investigating unfamiliar code, use git history for context:

- `git log --oneline <file>` — understand a file's evolution
- `git blame <file>` — find who changed what and why
- `git log -S "search_term"` — find when a string was introduced or removed
- `git log --all --grep="keyword"` — search commit messages across branches
- Read commit messages before modifying code you don't understand

## When to Use

- Making commits, creating branches, writing PR descriptions
- Resolving merge conflicts or rebasing
- Investigating unfamiliar code history

## When NOT to Use

- Initial repository setup (use project-specific docs)
- CI/CD pipeline configuration
- Git server administration

## Git Safety

- Never force-push to main/master without explicit instruction
- Never run destructive commands (reset --hard, clean -f) without asking
- Prefer creating new commits over amending published commits
- Stage specific files rather than using git add -A
- Investigate unexpected state (unfamiliar files, branches) before deleting
