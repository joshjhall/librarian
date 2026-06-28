# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this repo is

`librarian` is a **Claude Code plugin marketplace** — a git repo with
`.claude-plugin/marketplace.json` and a set of plugins, each installable via
`claude plugin install <name>@librarian`. It holds the general-purpose skills
and agents that used to live inside
[joshjhall/containers](https://github.com/joshjhall/containers), extracted so
they install identically on a host Mac, a bare Linux box, and inside the
containers dev image — with `plugin update` semver rolling updates for free.

The extraction is tracked in joshjhall/containers#607.

## Structure

```text
.claude-plugin/marketplace.json   # lists the 3 plugins (local ./plugins/<name> sources)
plugins/
  dev-core/                       # general dev + authoring skills/agents
  review-audit/                   # codebase-audit / check-* / audit-* + issue-writer
  workflow/                       # next-issue, orchestrate, golem, file-issue, provision-agent
    scripts/                      # bundled shell scripts, called via ${CLAUDE_PLUGIN_ROOT}
    hooks/                        # e.g. golem-notify.sh
tests/validate-manifests.mjs      # zero-dep manifest validator (CI + pre-commit/pre-push)
containers/                       # pinned submodule — builds the devcontainer only
```

Each plugin has `.claude-plugin/plugin.json` (name/version/description) and
auto-discovered `skills/` and `agents/` directories.

## Key conventions

- **Bundled scripts, never `just`.** The `workflow` plugin's skills call their
  shell scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/...`, NOT via `just`, so they
  run on host / bare-linux / container identically. Env-overridable config
  (`GOLEM_WORKTREE_DIR`, branch naming, state dir) carries the genuine forks.
- **Versions are semver.** `marketplace.json` and each `plugin.json` must agree
  on name + version; `tests/validate-manifests.mjs` enforces it. Release a
  plugin with `claude plugin tag`.
- **The `containers` submodule is pinned** (`update = none`). It exists only to
  build the devcontainer (`build.context: ../containers`). Bump it deliberately.

## Common commands

```bash
just              # list recipes
just validate     # validate manifests
just lint         # dprint + taplo + rumdl + manifest validation
just fmt          # format JSON/YAML/TOML/markdown
just install-hooks
```

## Commits

Conventional Commits enforced by `conform` (`.conform.yaml`). Scopes are the
plugin names (`dev-core`, `review-audit`, `workflow`) plus repo subsystems
(`marketplace`, `manifests`, `scripts`, `tests`, `ci`, `devcontainer`, …).
