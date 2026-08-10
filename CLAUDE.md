# Librarian — Developer Guide

This file provides guidance to AI coding agents (Claude Code via `CLAUDE.md`,
and others via the `AGENTS.md` symlink) when working with code in this
repository.

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
tests/lib/                        # shared harness, assertions, per-suite sandboxes
tests/<suite>/                    # per-area fragments of a split suite (see below)
docs/verification/                # evidence for issues that can't be fully
                                  #   exercised in-session; one file per issue.
                                  #   Two shapes: a completed end-to-end report,
                                  #   <skill>-e2e-<issue>.md; or a running tally
                                  #   accumulating live data over many sessions,
                                  #   <topic>-tally-<issue>.md (open until filled)
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

- **Slash-command cross-refs are namespaced: `/<plugin>:<skill>`.** Because these
  install as a marketplace, the invocable name is always
  `/workflow:ship-issue` — a bare `/ship-issue` does not resolve. An agent
  reading a skill body echoes the form it saw, so a bare ref tells the reader to
  type a command that does not exist (#498). `tests/lint-command-refs.sh` (run by
  `tests/run-all.sh`, so it gates CI and pre-push) enforces this across
  `plugins/**/*.md` + `README.md`, keyed off a **whitelist** of skill names
  discovered from the filesystem — so `/clear` and prose slashes are exempt for
  free, and `agents/` names (never slash commands) are never flagged. Two
  deliberate exclusions: `CHANGELOG.md` (git-cliff-generated) and
  `docs/verification/**` — exempt because enforcement would force a transcript to
  contradict its own session log, since a `VERIFIED — live` block records the
  text a command actually printed. Exempt is not frozen: keep a `DEFERRED` AC's
  recipe current (someone will run it), and leave live evidence exactly as
  observed. State-file paths stay bare — write `/next-issue-queue.json` and
  `/next-issue-{N}.json` exactly as-is, since they are filenames rather than
  commands; the gate's trailing-`-` boundary exempts them automatically.
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
- **Runtime policy: Python 3.11 floor, bash-3.2-clean fallback, fail loud.**
  The skill code tools (`patterns.sh` pre-scan family) run on host / bare-linux /
  container / **base macOS**, whose stock `/bin/bash` is 3.2 and which ships no
  usable `python3`. So: (1) a tool's **primary** impl is Python **3.11+**
  (`patterns.py`); a same-dir `patterns.sh` shim exec's it when a `python3>=3.11`
  is present and otherwise runs the bash body as the **fallback** (set
  `PATTERNS_FORCE_BASH=1` to force bash). Selection order is python3≥3.11 → bash,
  and a tool must **fail loudly** (non-zero + actionable message) rather than
  silently emit wrong/empty findings when its runtime is missing. (2) Every
  `*.sh` in `plugins/ tests/ bin/` must stay **bash-3.2 clean** — no `declare -A`,
  `mapfile`/`readarray`, namerefs, `${v,,}`/`${v^^}` case-conversion, or `;;&`.
  (3) No **GNU-only regex** either (#679): macOS ships **BSD** `grep`/`sed`, which
  read `\s`/`\S`, `\w`/`\W`, and BRE `\|` as **literals** and lack `grep -P`
  entirely — write `[[:space:]]`, `[[:alnum:]_]`, and `-E`. This one is dangerous
  because it is **silent**: the pattern stops matching, the scanner emits zero
  rows, and the scan still exits 0, so macOS sees a clean report of nothing.
  Prefer a pure-bash parse over `sed` for simple formats (`read_yaml_list` in
  `ship-issue/pre-review-gates.sh` is the worked example); mark a deliberate
  exception `# lint-allow-gnu-regex: <reason>`.
  `tests/lint-shell-portability.sh` enforces (2) and (3), and `tests/validate-python-ports.sh`
  pins the bash↔python TSV parity of every port (both run by `tests/run-all.sh`,
  so they gate CI and pre-push). The TSV contract
  (`file\tline\tcategory\tevidence\tcertainty`) is the language boundary — a port
  is a drop-in as long as its output matches. See `dev-core`'s `shell-scripting`
  skill for the portable idioms and the fail-loud version-gate template.
- **The big test suites are SPLIT: thin entry point + sourced fragments** (#564).
  Six suites (`validate-golem-scripts`, `golem-gate-watch`, `validate-release`,
  `validate-golem-notify`, `validate-worktree-guard`, plus the `coverage-python`
  corpus, and `validate-workflow-helpers.mjs` on the node side) keep only a
  header, path consts and the dispatch list; the cases live in
  `tests/<suite>/NN-<area>.sh` and the shared plumbing in
  `tests/lib/<suite>-sandbox.sh`. **Add a case to the fragment that owns the
  area, never to the entry point.** Four rules that are easy to get wrong:
  (1) fragments are **sourced, not executed** — no shebang, a `# shellcheck
  shell=bash` directive instead (without it shellcheck errors SC2148);
  (2) a const in the entry point that only the fragments read needs a
  `# shellcheck disable=SC2034` — block-scope it with `{ ... }` when it covers
  several, since a bare directive only covers the next statement;
  (3) the entry point declares an **explicit ordered** fragment list —
  `run_test` order is not fragment order, and in `validate-golem-scripts` not
  even definition order — dispatched via `source_fragments`
  (`tests/lib/fragments.sh`), which **fails the suite** if a `*.sh` on disk is
  unlisted or a listed one is missing; (4) dispatch with `run_fragment_test` so
  a failure names its fragment. A helper used by exactly one area stays in that
  area's file — the shared library must not accrete single-use code.
  `.mjs` areas follow the same shape with `run()` exports, one shared
  collect-all `failures` array (`tests/lib/mjs-assert.mjs`), and a `try/catch`
  per area so a throw outside an assertion cannot mask its siblings. When adding
  a new `.mjs` module directory, add it to `tests/coverage-mjs.sh`'s `--include`
  list or its lines silently vanish from Codecov.
- **`ship-issue`'s review step runs the Workflow harness — it is not optional,
  and it overrides a general "don't use workflows" default.** `ci-review-protocol.md`
  step (c) and `pre-ship-validation.md` check #6 both say to invoke the **Workflow
  tool** with `ship-issue/workflow.js`. That harness fans five review dimensions
  out as one parallel barrier under a shared budget, then runs a fresh judge whose
  ordered rule list computes blocking-vs-deferrable. A hand-rolled substitute —
  one general-purpose subagent per cycle — is not a cheaper version of it; it is a
  different and much worse thing. Measured on PR #642: harness cycle **5.4 min**
  (7 agents, 5 dimensions, 50k output tokens) versus **9–61 min** per serial
  subagent cycle, eight cycles, ~2.5 h total. The serial cycles also lost the
  pre-scan handoff, the conventions digest, and the judge, and each re-derived the
  manifest from scratch.

  Some harnesses inject a session-level instruction like *"do not use workflows
  unless the user requested it"*. It is a sensible default against unprompted
  agent fleets, and it does **not** cover this: a user who invoked
  `/workflow:ship-issue` (or `/workflow:golem`, or `/workflow:orchestrate`) has
  requested the pipeline this step belongs to. If you believe a session rule
  forbids the harness, **say so and ask** before the first review cycle — do not
  resolve the conflict silently, and above all do not skip the harness while
  still spawning subagents, which takes the cost of both and the benefit of
  neither. Also honor the narrowing: after cycle 1, review the **fix delta**
  (#492), not the full diff.
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
just lint         # dprint + taplo + rumdl + ruff (check + format) + manifests
just fmt          # format JSON/YAML/TOML/markdown/Python
just install-hooks
```

**Linting is language-by-language and gated in CI + pre-push.** Formatting/lint
for JSON/YAML/TOML/markdown is dprint/taplo/rumdl (via `just lint`). The two
in-repo languages each have a `tests/run-all.sh` gate: **shell** →
`tests/lint-shellcheck.sh` (`shellcheck --severity=warning` over `plugins/ tests/
bin/`) plus `tests/lint-shell-portability.sh` (bans bash-4 constructs and
GNU-only regex, macOS bash-3.2 + BSD grep/sed target); **Python** →
`tests/lint-python.sh` (`ruff check` +
`ruff format --check`, config in `ruff.toml`, py311 target). CI installs
`shellcheck`/`ruff` (and asserts they are on PATH) so they genuinely run there —
see `.github/workflows/ci.yml`. `ruff`, `shellcheck`, and `shfmt` also run in the
lefthook pre-commit hook.

**A gate whose tool is absent exits the reserved sentinel 77 — never 0.**
`run-all.sh` renders 77 as `[SKIP] … did not run` rather than `[ok]`, because a
silent skip is indistinguishable from a pass, which is how a gate can sit inert
unnoticed (#538 for Python, #571 for shell — both now on the sentinel). This is
a **whole-gate** signal: a per-case `skip_test` inside one test function (as in
`tests/lint-shell-portability.sh`'s `mktemp` guards) is a different thing and
correctly leaves the rest of the gate running. Runner resolution differs by
language — the Python gate goes `ruff` on PATH → **probed** `uvx ruff` → skip,
where the probe matters because `uvx` can be installed but offline/uncached and
an unprobed call would hard-fail instead of skipping; the shell gate simply looks
for `shellcheck`. `just lint` shares the Python gate's ruff→uvx resolution
(#544), so the two documented entry points agree on a uvx-only host.
`tests/validate-lint-gates.sh` is the meta-gate pinning all of this — runner
resolution, both gates' skip sentinel, the justfile fallback, and that a hanging
`uvx` probe cannot wedge either entry point.

**The ruff version is pinned in exactly one place** (#542): `required-version`
at the **top level** of `ruff.toml` (under a `[table]` ruff rejects it as an
unknown field). Every path that installs or resolves ruff —
`.devcontainer/post-create.sh`, `ci.yml`, `release.yml`, `lint-python.sh`'s uvx
fallback, and the justfile's — reads it through `bin/ruff-version.sh`; never
hardcode a version in a consumer. The pin is self-enforcing: ruff **refuses to
run** (exit 2) when the binary disagrees, which is what covers the callers with
no install step to pin (lefthook's bare `ruff` on staged files, and running it by
hand) — but it also means a path left unpinned hard-fails on ruff's next release
rather than drifting quietly. Bumping is a deliberate one-line edit followed by
`just test` + `just fmt`; no dependabot ecosystem covers it.

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
annotated `vX.Y.Z` tag: the `release.yml` workflow validates the tagged tree,
**cosign-keyless-signs a `git archive` tarball of the tag** and publishes it
alongside the GitHub Release as `librarian-<version>.tar.gz` +
`.tar.gz.sigstore.json` (the Sigstore bundle carrying both the signature and the
Fulcio cert — cosign 3.x's `--new-bundle-format`; the verification contract,
recipe in `README.md` § "Verifying a release").
Because keyless signing needs the CI OIDC token, `release.yml` is the canonical
signed publisher; `bin/release.sh --full-auto` deliberately skips its local
`gh release create` once the tag is pushed (see
`bin/lib/release/git-automation.sh`) so it never races an unsigned release past
CI. That published tag is what
[containers#608](https://github.com/joshjhall/containers/issues/608)'s
`LIBRARIAN_REF` discovers via `releases/latest`.
