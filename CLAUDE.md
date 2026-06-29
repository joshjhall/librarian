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

**Agent files MUST be flat: `agents/<name>.md`.** Claude Code discovers plugin
agents only as flat markdown files directly under `agents/` — a nested
`agents/<name>/<name>.md` is silently NOT discovered (`claude plugin details`
shows `Agents (0)`). Skills are the opposite: directory form
`skills/<name>/SKILL.md`. An agent that ships a `workflow.js` harness keeps the
flat `agents/<name>.md` AND puts the harness in a same-named sibling subdir
`agents/<name>/workflow.js` — discovery ignores the subdir; the harness still
resolves. The `tests/lint-skills-agents.sh` gate enforces the flat layout, but
always sanity-check packaging with `claude plugin marketplace add <path>` +
`claude plugin details <name>@librarian` (manifest validation does not exercise
component discovery).

**Bundled hooks need `hooks/hooks.json`.** A hook script dropped in
`hooks/<name>.sh` is NOT registered on its own — `claude plugin details` shows
`Hooks (0)` and installing the plugin wires up nothing. The plugin must ship
`hooks/hooks.json` mapping the event (e.g. `Notification`) to a `command` that
invokes the script via `${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh`. After adding or
changing it, re-verify with `claude plugin details <name>@librarian` showing
`Hooks (N)` — same discovery gotcha as the flat-agents rule above.

## Key conventions

- **Bundled scripts, never `just`.** The `workflow` plugin's skills call their
  shell scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/...`, NOT via `just`, so they
  run on host / bare-linux / container identically. Env-overridable config
  (`GOLEM_WORKTREE_DIR`, branch naming, state dir) carries the genuine forks.
- **Versions are semver.** `marketplace.json` and each `plugin.json` must agree
  on name + version; `tests/validate-manifests.mjs` enforces it. Two distinct
  version concepts: **per-plugin** semver (each `plugin.json`, consumed by
  `claude plugin update`) and the **repo-level release tag** (`vX.Y.Z`, what
  containers' `LIBRARIAN_REF` pins to). `bin/release.sh` re-aligns all plugin
  versions to the repo version on each release — see **Releases** below.
- **The `containers` submodule is pinned** (`update = none`). It exists only to
  build the devcontainer (`build.context: ../containers`). Bump it deliberately.
- **GitHub Actions are SHA-pinned with a version comment.** Every `uses:` in
  `.github/workflows/*.yml` pins a full 40-char commit SHA followed by a
  `# vX.Y.Z` comment (`actions/checkout@<sha> # v4.3.1`). The SHA and the
  comment MUST be bumped **together** — a drift means CI runs a different
  version than advertised. `.github/dependabot.yml` (github-actions ecosystem)
  does this atomically in a weekly grouped PR; `tests/lint-action-pins.sh`
  (run by `tests/run-all.sh`, so it gates CI and pre-push) enforces the
  pinned-SHA + version-comment **format** offline. Dependabot's PRs commit as
  `ci(deps): …` to satisfy the `conform` scope enum (`.conform.yaml`).

## Common commands

```bash
just              # list recipes
just validate     # validate manifests
just test         # run the full local test suite (tests/run-all.sh; mirrors CI)
just lint         # dprint + taplo + rumdl + manifest validation
just fmt          # format JSON/YAML/TOML/markdown
just install-hooks
```

## Commits

Conventional Commits enforced by `conform` (`.conform.yaml`). Scopes are the
plugin names (`dev-core`, `review-audit`, `workflow`) plus repo subsystems
(`marketplace`, `manifests`, `scripts`, `tests`, `ci`, `devcontainer`, …).

## Releases

**Never hand-edit `VERSION`** — always release through the script so the
`VERSION` file, all three `plugin.json`, the `marketplace.json` entries, and
`CHANGELOG.md` stay consistent (`tests/validate-manifests.mjs` enforces the
name+version agreement).

```bash
just release-patch   # 0.1.0 -> 0.1.1 (bug fixes)
just release-minor   # 0.1.0 -> 0.2.0 (new skills/agents, additive)
just release-major   # 0.1.0 -> 1.0.0 (breaking changes)
```

`bin/release.sh` bumps `VERSION`, stamps every manifest in lockstep
(`bin/stamp-versions.mjs`), and regenerates `CHANGELOG.md` from conventional
commits (git-cliff, `cliff.toml`). It does **not** commit/tag/push by default —
review the diff, commit on a branch, and open a PR. Cut the actual release from
`main` with the auto flags (`bin/release.sh --full-auto patch`) or by pushing an
annotated `vX.Y.Z` tag: the `release.yml` workflow validates the tagged tree and
publishes the GitHub Release. That published tag is what
[containers#608](https://github.com/joshjhall/containers/issues/608)'s
`LIBRARIAN_REF` discovers via `releases/latest`.
