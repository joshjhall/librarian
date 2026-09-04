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
                                  #   <topic>-tally-<issue>.md (open while it
                                  #   fills, then closed with a verdict)
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
  **One documented exception, forced by the harness (#809, corrected by #815):**
  a recipe that runs while the session is **`EnterWorktree`-isolated** must be
  spelled so the Bash tool can **statically evaluate** it — that tool refuses a
  command it cannot verify stays in-tree, and `${CLAUDE_PLUGIN_ROOT}` trips it
  (`CLAUDE_PLUGIN_ROOT` is not exported into the Bash environment either, so that
  spelling has two independent reasons to fail). The operative property is
  evaluability, **not** the presence of a `$`: an inline-assigned variable is
  fine, while a command substitution is not.
  **This is many recipes, not one.** `golem/SKILL.md` § Phase C was merely the
  first found: Phase C delegates to `/workflow:next-issue`, which chains
  `/workflow:ship-issue` in-turn at L3–L4, so **every** recipe those two skills
  execute runs worktree-isolated too. The boundary is isolation, not cwd — a
  detached tmux/container golem sets its cwd at launch and is **not** affected.
  The measured spelling matrix, the boundary condition, and the two safe
  rewriting patterns live in **one** companion,
  `next-issue/worktree-safe-recipes.md`; read it before adding or editing a
  recipe in `next-issue/`, `ship-issue/`, or `golem/`, and do not re-derive the
  rule from memory. `tests/lint-worktree-recipes.sh` (run by `tests/run-all.sh`,
  so it gates CI and pre-push) enforces it.
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
- **The two biggest `workflow.js` harnesses are GENERATED — edit the fragment,
  never the artifact** (#806). `ship-issue/workflow.js` and
  `codebase-audit/workflow.js` are the byte concatenation of the ordered
  fragments in their `workflow.src/` sibling directory. After editing any
  fragment run `just gen-workflow-js`; `tests/lint-workflow-js-generated.sh`
  (run by `tests/run-all.sh`, so it gates CI and pre-push) fails the tree while
  an artifact is stale. Four things to know:
  (1) **Concatenation, not bundling.** A workflow.js is parsed as a *script*, so
  every `import` spelling fails at parse (#712 probed all three) — which is why
  a sibling-module split is impossible and why `BUDGET_FLOOR` is duplicated
  across harnesses rather than shared. Concatenation needs no module system, so
  the artifact contains no import even though it came from nine files.
  (2) **The manifest is explicit and ordered, never a glob** — same shape and
  same reason as `tests/lib/fragments.sh`. It fails in *both* directions (an
  unlisted fragment on disk, a listed one missing), and the order is
  load-bearing: `sanitize` is called at module load by `NEW_DIMENSIONS`, so
  reversing those two fragments is a TDZ throw on the `issue`-truthy branch only
  — invisible to a test that extracts without an issue (#260).
  (3) **The artifact stays committed and freshness is checked locally, not at PR
  time.** `claude plugin install` copies `plugins/` as-is with no build hook, and
  the ship-issue harness runs on every local review cycle — so a PR-tied
  generator would let a fragment edit silently review with the old bytes.
  (4) **Enrollment rule:** a harness enrolls when it exceeds the js `high`
  production-LOC budget. Measured 2026-08-25: ship-issue 916 and codebase-audit
  803 are over it; orchestrate 797 and code-reviewer 670 are over `warn` only,
  and rebase-agent 331 / ci-fixer 310 are well under. Re-measure with
  `ship-issue/plan-lens.sh` before enrolling another. Note the `@generated`
  banner does **not** silence the size row (verified) — this convention is
  justified by editing ergonomics, not by quieting the lens.
- **`ship-issue`'s review step runs the Workflow harness — it is not optional,
  and it overrides a general "don't use workflows" default.** `ci-review-protocol.md`
  step (c) and `pre-ship-validation.md` check #6 both say to invoke the **Workflow
  tool** with `ship-issue/workflow.js`. That harness fans six review dimensions
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
- **Plugin prose has a size budget, ratcheted** (#589). Markdown is the largest
  surface here (~20.6k lines, more than the shell and JS combined) and grows
  faster than either, so `tests/lint-prose-budget.sh` (run by `tests/run-all.sh`,
  so it gates CI and pre-push) budgets every `plugins/**/*.md` by file type.
  Three rules to know:
  (1) **One threshold table.** The budgets are
  `check-decomposition/thresholds.yml`'s `bloat_thresholds` — the same table the
  audit lens, the review lens, and index health read. The gate **parses** it; it
  keeps no copy. Never hardcode a prose threshold in a consumer, for the reason
  stated in that file: two tables over the same files that must agree is exactly
  the duplication #663 was filed to eliminate.
  (2) **The ceiling is `max(type budget, baseline entry)`,** where the baseline
  is `tests/prose-budget.baseline`. This is what lets the gate land green on a
  tree that already exceeds its budgets while still failing on **growth** — a
  fixed constant cannot do both. A file may shrink freely
  (`tests/lint-prose-budget.sh --regen` then **tightens** the entry); **raising**
  an entry is a deliberate one-line diff that wants a reason in the commit
  message. A brand-new file gets its real type budget, never the loosest number
  in the repo.
  (3) **`docs/verification/**` is exempt**, by construction rather than by a
  filter — the gate's root is `plugins/`, so those dated transcripts are simply
  never walked. Same reason `lint-command-refs.sh` exempts them: their length is
  evidence, and a budget over them would pressure someone to edit a session log
  to fit. Note this gate **fails loud** on a missing runtime rather than
  returning the 77 sentinel — 77 is for an absent *linter*, and coreutils being
  gone is a broken environment, not an unavailable optional tool.

## Common commands

```bash
just              # list recipes
just validate     # validate manifests
just test         # run the full local test suite (tests/run-all.sh; mirrors CI)
just lint         # dprint + taplo + rumdl + ruff (check + format) + manifests
just fmt          # format JSON/YAML/TOML/markdown/Python
just install-hooks
```

**Capture the suite's output — never pipe it** (#854). `bash tests/run-all.sh |
tail -45` exits **0 on a red suite**: a pipeline reports its *last* command's
status, so the caller reads `tail`'s success. Capture instead, and read the code:

```bash
bash tests/run-all.sh > /tmp/run.log 2>&1; echo $?
```

The runner mirrors its failure verdict — banner plus the names of the failed
stages — to **stderr**, which a stdout-only pipe cannot swallow, so a piped run
is loud even though its exit code is still lost. That is a backstop, not a
license: only the captured form gives a caller an exit code it can trust.
`tests/validate-run-all-reporting.sh` pins both halves.

**`git push` already runs the full suite — do not run it by hand first.**
lefthook's **pre-push** `quality-gates` step is `bash tests/run-all.sh`, globbed
to `plugins/**`, `tests/**`, and `.github/workflows/**`, so nearly every change
here triggers it. Running `just test` (or `just lint`, whose `typos`/
`dprint-check`/`taplo-check` the hook also repeats) before pushing pays the same
~5-9 minutes twice on the same tree, and buys no safety: the hook runs *after*
the manual pass and is what actually blocks the push. Measured on a one-line
codeql SHA pin: ~300 s local + 516 s hook, for a line no test in the suite
exercises. Instead, run the **targeted** gate for what changed when it is cheap
(`tests/lint-action-pins.sh` is 2 s for a pinned `uses:`), then push with a
600 s timeout. Reach for the full local suite only while iterating on a failure,
or when a late failure is expensive - mid-release, or before pushing a tag.

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
