# Repo Baseline — Core Spec

Companion to `SKILL.md`. The language-independent half of the baseline: what
every repo gets whatever it is written in, and the shape the language slices
(`languages/<lang>.md`, contract in `slice-contract.md`) plug into.

Each section ends in **checkable** statements — a file exists, a hook entry is
present, a CI job runs a command — so an audit can test a repo against it
without judgment calls.

---

## 1. Hook layout

The hook runner is **lefthook** (`lefthook.yml` at the repo root). Three stages,
each with a different cost ceiling:

| Stage        | Runs on                        | Budget     | Contents                                              |
| ------------ | ------------------------------ | ---------- | ----------------------------------------------------- |
| `pre-commit` | **staged files only**          | seconds    | formatters (auto-fix + re-stage), fast linters, secret scan, hygiene |
| `commit-msg` | the message file (`{1}`)       | instant    | conform (Conventional Commits)                         |
| `pre-push`   | the pushed range / whole tree  | minutes    | full lint, the single test entry point                |

### pre-commit

- Scope every command with `glob:` and pass `{staged_files}` — never the whole
  tree. A pre-commit that lints everything trains people to `--no-verify`.
- `parallel: true` at the stage level.
- **Auto-fixers re-stage their output** with `stage_fixed: true` (formatters:
  shfmt, dprint, taplo, a language formatter). **Linters do not** — a check that
  only reports must not touch the index.
- Exclude vendored and submodule trees (`exclude:`) consistently with the tool's
  own config, so the hook and a whole-tree run agree on the corpus.

### commit-msg

```yaml
commit-msg:
  commands:
    conform:
      skip:
        - run: "! command -v conform >/dev/null 2>&1"
      run: conform enforce --commit-msg-file {1}
```

### pre-push

- Runs the **same** test entry point CI runs (§ 6), not a hand-picked subset.
- Re-runs the cheap whole-tree checks that pre-commit only saw a slice of
  (`dprint check`, `taplo fmt --check`, `typos` over `{push_files}`).
- `glob:` may narrow *when* the suite runs (e.g. only for pushes touching
  source or tests); it must not narrow *what* it runs.

### The skip-guard rule

An **optional** tool — one a contributor may reasonably not have installed on a
bare host — carries a guard so the hook passes over it instead of blocking the
commit:

```yaml
shellcheck:
  glob: "*.sh"
  skip:
    - run: "! command -v shellcheck >/dev/null 2>&1"
  run: shellcheck --severity=warning {staged_files}
```

Spell it exactly that way — a `skip:` list whose `run:` exits 0 when the tool is
**absent**. Three classes are **never** guarded:

1. **The build toolchain.** A repo that cannot build without `cargo` (or `go`,
   `swift`, …) does not guard its clippy/rustfmt entries: a contributor without
   the toolchain cannot produce a change worth committing, and a guard there
   only hides a broken environment.
2. **In-repo gates.** A check implemented by a script in the repo that needs only
   what the repo already needs (git, the shell) has no "tool absent" case — its
   absence is a broken checkout, so it must fail.
3. **Merge-conflict detection.** Pure shell; nothing to be absent.

**CI runs every check with no skips.** CI installs each tool (pinned, § 4) and
runs it unguarded; a tool missing in CI is a **failure**, never a skip. The hook
guard exists for contributor machines only. A gate that can be skipped
everywhere is a gate that sits inert unnoticed.

When a gate script itself must express "my tool is absent", it exits a reserved
sentinel (`77`) that the runner renders as `[SKIP] … did not run` — never as
`[ok]`. A silent skip is indistinguishable from a pass.

**Never `--no-verify`.** A hook failure is fixed, not bypassed.

---

## 2. Always-on tools

Every repo gets these regardless of language. A slice adds its language's
tools; it never removes one of these.

| Tool          | Checks                          | Stage(s)               | Config file              | Auto-fix |
| ------------- | ------------------------------- | ---------------------- | ------------------------ | -------- |
| gitleaks      | committed secrets               | pre-commit (`protect --staged`), CI | `.gitleaks.toml` (optional) | no |
| typos         | spelling in code and prose      | pre-push, CI           | `_typos.toml`            | no       |
| dprint        | YAML + JSON formatting          | pre-commit (fix), pre-push (check), CI | `dprint.json` | yes |
| taplo         | TOML formatting                 | pre-commit (fix), pre-push (check), CI | `.taplo.toml` (optional) | yes |
| rumdl         | Markdown lint                   | pre-commit, CI         | `.rumdl.toml`            | no       |
| conform       | Conventional Commits            | commit-msg, CI (PR)    | `.conform.yaml`          | no       |
| actionlint    | GitHub Actions workflows        | pre-commit, CI         | —                        | no       |
| GitLab CI lint | `.gitlab-ci.yml`               | pre-commit, CI         | —                        | no       |

Use actionlint **or** GitLab CI lint according to where the repo's CI runs (a
repo with both runs both).

Hygiene checks, also always on, all at pre-commit:

- **Merge-conflict markers** — reject `^<{7} `, `^>{7} `, `^={7}$` in staged
  files (exclude any file that documents markers on purpose).
- **Trailing whitespace** and **missing EOF newline** — usually covered by the
  formatters for the file types they own; add an explicit check for the rest.
- **Large-file guard** — refuse a staged blob over a fixed size (e.g. 1 MB)
  unless its path is allowlisted.

Pin plugin versions **inside** the config where the tool supports it (dprint
plugins are URLs with a version in the path).

---

## 3. CI shape

Three stages, in order. A later stage depends on the earlier ones; a single
**merge gate** job depends on all of them, so branch protection names one
check rather than a list that drifts.

| Stage      | Runs                                                              |
| ---------- | ----------------------------------------------------------------- |
| `lint`     | every always-on tool + every slice's linters, whole tree, no skips |
| `test`     | the single test entry point (§ 6)                                  |
| `security` | gitleaks over the change's whole range (the PR/MR base to `HEAD`; the **full history** when there is no base — never just the last commit), dependency audit from each slice |

Pinning, on both platforms:

- **Images are pinned to a version tag** (or digest) — never `:latest`, never a
  floating major (`node:22` is a float; `node:22.11.0` is a pin).
- **GitHub Actions pin a full 40-char commit SHA with a `# vX.Y.Z` comment**;
  the SHA and the comment are bumped together (Dependabot's `github-actions`
  ecosystem does this atomically).
- Tool versions come from the repo's single source per tool (§ 4), not from a
  literal in the workflow.

### GitHub Actions

```yaml
permissions:
  contents: read # least privilege; widen per job only where a job needs it

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<40-char-sha> # vX.Y.Z
      - run: bin/install-tools.sh # installs every pinned tool; fails if one is missing
      - run: just lint
  test:
    needs: lint
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<40-char-sha> # vX.Y.Z
      - run: bin/install-tools.sh
      - run: just test
  security:
    needs: lint
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<40-char-sha> # vX.Y.Z
        with: { fetch-depth: 0 }
      - run: bin/install-tools.sh
      - name: Secret scan (PR range, else full history)
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
        run: |
          if [ -n "$BASE_SHA" ]; then
            gitleaks detect --redact --log-opts="$BASE_SHA..HEAD"
          else
            gitleaks detect --redact # no PR base: scan everything, never just HEAD~1
          fi
  merge-gate:
    if: always() # a skipped required check counts as PASSED — never let it skip
    needs: [lint, test, security]
    runs-on: ubuntu-24.04
    steps:
      - run: |
          for r in ${{ join(needs.*.result, ' ') }}; do
            [ "$r" = success ] || { echo "a stage did not succeed: $r"; exit 1; }
          done
```

`merge-gate` is the one check branch protection requires. It must run even when
a stage fails, and fail on anything but `success`: with plain `needs:` a failed
stage **skips** the gate, and GitHub treats a skipped required check as passing.

### GitLab CI

```yaml
stages: [lint, test, security]

default:
  image: registry.example.com/dev-tools:1.4.2 # pinned tag, never :latest
  before_script:
    - bin/install-tools.sh

lint:
  stage: lint
  script:
    - just lint

test:
  stage: test
  script:
    - just test

security:
  stage: security
  variables:
    GIT_DEPTH: 0
  script:
    - |
      if [ -n "${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}" ]; then
        gitleaks detect --redact --log-opts="$CI_MERGE_REQUEST_DIFF_BASE_SHA..HEAD"
      else
        gitleaks detect --redact # branch pipeline: no MR base, scan everything
      fi
```

GitLab runs stages in order and fails the pipeline on any failed job, so the
stage list *is* the merge gate; require "Pipelines must succeed" on the project.

`bin/install-tools.sh` and `just lint` / `just test` are placeholders for the
repo's own entry points. The checkable property is that **CI and the hooks call
the same entry points**, and that the install step **fails** when a tool cannot
be installed.

---

## 4. Version-pinning policy

**Policy: an exact pin, in one source of truth per tool, read through one
accessor.** Every consumer — the devcontainer post-create, the CI install step,
any gate's fallback runner, the `justfile` — reads the pin through the accessor;
none hardcodes a version.

The reference implementation is librarian's ruff pin: `required-version` at the
top level of `ruff.toml` is the one source, `bin/ruff-version.sh` is the
accessor, and ruff itself **refuses to run** (exit 2) when the binary on PATH
disagrees. That last property is what makes an exact pin self-enforcing: even a
caller with no install step (a bare `ruff` in a hook) cannot run the wrong
version silently.

Where the tool has no built-in version check, the single source is a small
pins file (e.g. `tools.versions`, or `.mise.toml` / `.tool-versions` when the
repo uses mise or asdf) and the accessor is the script that reads it; the CI
install step compares `tool --version` against the pin and fails on mismatch.

### Why exact, not a floor or per-machine installs

- **A floor drifts silently.** `>=0.16` lets a contributor run 0.17 while CI runs
  0.16; a new lint rule fires on one side only and the disagreement surfaces as
  a confusing red build, not as "your tool is the wrong version".
- **Per-machine installs without a pinned source** (whatever `brew`/`apt`
  delivered) are the same drift with no bound at all.
- **An exact pin makes drift loud and local.** The mismatch fails on the
  contributor's machine with the version in the message, before a push.

### What a contributor does when a local tool disagrees

Example: Homebrew upgraded ruff to 0.17 and the repo pins 0.16.10, so ruff exits
2 in the hook.

1. **Install the pinned version, ahead of the system one on PATH** — via a
   per-user tool manager, reading the pin through the accessor:

   ```bash
   uv tool install --force "ruff==$(bin/ruff-version.sh)"   # or:
   pipx install --force "ruff==$(bin/ruff-version.sh)"      # or: mise use ruff@<pin>
   ```

   Ask the tool where it installs rather than assuming a path — the directory is
   configurable and platform-dependent (`uv tool dir --bin`, `pipx environment
   --value PIPX_BIN_DIR`) — and make sure that directory precedes the system
   package manager's prefix on PATH.
2. **Or run the pinned version ephemerally** where the repo's gate supports it
   (`uvx ruff@<pin>`).
3. **Never edit the pin to match your machine.** Bumping a pin is a deliberate
   one-line change in its own commit, followed by the full lint and test run,
   because it changes what every contributor and CI runs.

Bumping: one edit to the single source, then `just lint` + `just test`. A
dependency bot covers only what it has an ecosystem for (GitHub Actions SHAs,
lockfiles); a tool pin in a config file is bumped by hand.

---

## 5. Docs minimum

Every repo has:

- **`README.md`** — what the repo is, why it exists, and how to run it (install,
  build, the main commands). A reader with no context can get from clone to a
  working run from the README alone.
- **`CLAUDE.md`**, with **`AGENTS.md`** as a symlink to it (or the reverse) — the
  conventions an AI agent needs that are not derivable from the code: invariants,
  gotchas, what not to touch, how releases work.
- **A "Lint and tests" section** — in the README or CLAUDE.md — listing the
  **exact** commands: the lint entry point, the test entry point, how to install
  the hooks (`lefthook install`), and how to install the pinned tools (§ 4).
  Exact means copy-pasteable, not "run the linters".

---

## 6. Test minimum

- **Logic that decides what gets deleted, kept, or published has tests.**
  Retention and pruning, secret and path guards, release and publish selection,
  anything that removes data or makes something public. These are the paths
  where a silent wrong answer costs the most and is noticed last.
- **One test entry point** — `tests/run.sh` (or `tests/run-all.sh`, or
  `just test` wrapping it) — that the pre-push hook and CI **both** call. Per
  slice test runners are invoked *from* it, not alongside it.
- The entry point **exits non-zero on any failure**, and a caller must read its
  exit code directly: `tests/run.sh | tail` reports `tail`'s status, so a piped
  run exits 0 on a red suite. Capture output to a file instead.
- A gate that cannot run (tool absent) reports itself as **skipped** (§ 1,
  sentinel `77`), never as passed.

---

## 7. Size budgets

Per-file size budgets have **one** definition:
`review-audit`'s `check-decomposition/thresholds.yml`. This spec does not
restate the numbers — two tables over the same files that must agree is the
duplication that table exists to remove. A language slice may declare an
override (`slice-contract.md` § Size-budget override); the override's value
lives in that same table, not in the slice. The per-language overrides
themselves are defined by the size-budgets work in the repo-baseline epic.

---

## 8. Checklist

What an audit tests, per repo:

- [ ] `lefthook.yml` exists with `pre-commit`, `commit-msg`, and `pre-push` stages
- [ ] pre-commit commands use `glob:` + `{staged_files}`; formatters set `stage_fixed: true`
- [ ] every optional tool has a `skip:` guard; toolchain and in-repo gates have none
- [ ] all always-on tools (§ 2) are present at the listed stages
- [ ] CI has lint → test → security, plus a single merge gate that runs `if: always()` and fails unless every stage succeeded
- [ ] the secret scan covers the whole change range, falling back to full history (not `HEAD~1`) when there is no base
- [ ] CI installs every tool and runs every check with no skip guard
- [ ] no CI image uses `:latest` or a floating tag; every action is SHA-pinned with a version comment
- [ ] each tool version has one source of truth and one accessor; no consumer hardcodes it
- [ ] `README.md`, `CLAUDE.md` + `AGENTS.md`, and a "Lint and tests" section with exact commands
- [ ] one test entry point, called by both pre-push and CI
- [ ] delete/keep/publish logic has tests

---

## 9. Status in librarian (as of this spec)

Librarian is the reference these rules were drawn from, and it does **not** yet
meet all of them. Recorded here so an audit run against it starts from a known
answer rather than a false green:

- **CI does not install or run** dprint, taplo, rumdl, gitleaks, shfmt,
  actionlint, or conform — they run in the hooks only. The § 1 rule "CI runs
  every check with no skips" is therefore not met.
- **Only ruff and typos are pinned** (ruff via `ruff.toml` + `bin/ruff-version.sh`;
  typos as a literal in `ci.yml`, not a single source). The rest come unpinned
  from the devcontainer.
- **CI is not split into lint/test/security stages** — every gate runs inside
  `tests/run-all.sh`, sharded as a matrix, behind a single merge gate.
- **No trailing-whitespace, EOF-newline, or large-file hook.**
