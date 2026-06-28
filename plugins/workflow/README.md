# workflow

Part of the [librarian](../../README.md) Claude Code plugin marketplace.

Issue-driven and parallel-automation workflow: pick the next issue, run the
autonomous pipeline, and fan work out across per-issue golems (one
issue/branch/worktree/PR each) — on a host, on bare Linux, or inside a
devcontainer.

## Skills (9)

- `file-issue` — structured GitHub/GitLab issue creation with auto-labeling
- `next-issue` / `next-issue-ship` — issue-driven development + delivery
- `orchestrate` — master orchestrator for PR-per-golem parallel work
- `provision-agent` — provision headless agent containers (assumes a
  devcontainer-based setup; see its `SKILL.md`)
- `rebase-generated` / `rebase-imports` / `rebase-lockfile` / `rebase-version`
  — targeted merge-conflict resolvers

## Agents (4)

`issue-writer`, `issue-filer`, `ci-fixer`, `rebase-agent`.

## Hook

- `hooks/golem-notify.sh` — Notification hook that records each golem's
  permission-gate / idle transitions to the central status feed.

## Bundled scripts (`scripts/`)

The golem/worktree flow runs **without `just`** — these standalone scripts
replace the containers justfile recipes the skills used to call. Skills invoke
them as `${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh`.

| Script | Purpose |
| --- | --- |
| `worktree-new.sh <N>` | Create a push-ready worktree + branch for issue N |
| `worktree-rm.sh <N>` | Remove issue N's worktree + branch |
| `golem-status.sh` | Central golem status table + BLOCKED list (TTY-free) |
| `golem-attach.sh <N>` | Attach to issue N's golem (worktree tmux or container) |
| `golem-watch.sh` | Stream proactive gate notifications until Ctrl-C |
| `golem-gate-watch.sh` | Gate-detection engine shared by status + watch |
| `seed-worktree-trust.sh` | Seed Claude Code workspace trust for a worktree |
| `config.sh` | Shared env-overridable config + `repo_root` helper (sourced) |

### Configuration (env-overridable; defaults in `scripts/config.sh`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `GOLEM_WORKTREE_DIR` | `.worktrees` | Per-issue worktree directory |
| `GOLEM_STATUS_DIR` | `<worktree-dir>/.status` | Golem status JSON + feed |
| `GOLEM_BRANCH_PREFIX` | `feature/issue-` | Branch for issue N is `<prefix><N>` |
| `GOLEM_BASE_REF` | `origin/main` | Ref new worktree branches fork from |
| `GOLEM_WORKTREE_LOCAL_FILES` | `.env .claude/settings.local.json` | Gitignored files copied into a fresh worktree |
| `GOLEM_BLOCK_TTL` | `3600` | Feed gate-freshness window (seconds) |
| `GOLEM_WATCH_INTERVAL` | `5` | `--stream*` poll interval (seconds) |
