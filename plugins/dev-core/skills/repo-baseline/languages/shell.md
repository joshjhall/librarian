# Repo Baseline — Shell Slice

Language slice for shell (bash). Conforms to `../slice-contract.md`; adds to
`../core.md`, never relaxes it. For shell **idioms** — naming, error handling,
bash-3.2 and BSD portability, the fail-loud runtime gate — use the
`shell-scripting` skill; this slice covers only the tooling.

Values are librarian's current configuration, which is the reference this slice
was drawn from.

## Tools & versions

| Tool       | Purpose                       | Pinned version | Single source / accessor | Class    |
| ---------- | ----------------------------- | -------------- | ------------------------ | -------- |
| shellcheck | static analysis               | unpinned       | — (devcontainer / apt)   | optional |
| shfmt      | formatting (auto-fix)         | unpinned       | — (devcontainer)         | optional |
| bats-core  | test framework                | 1.14.0         | `bin/install-tools.sh`   | required |
| bash       | runtime; the floor is **3.2** | n/a (floor)    | stock macOS `/bin/bash`  | required |

bash is the runtime, not a lint tool: the floor is 3.2 because that is what
stock macOS ships, and every script must run on it (see `shell-scripting`
§ Portability & Runtime Selection). It is never skip-guarded — there is nothing
to run the scripts without it.

## Config files

`.shellcheckrc` — required.

```ini
# No severity key: .shellcheckrc cannot carry one (shellcheck 0.10.0 silently
# ignores `severity=`), so the floor is --severity=warning on every command line.

shell=bash

# Follow relative `source` lines, so SC1091 needs no global disable.
source-path=SCRIPTDIR
external-sources=true

# per-repo: disable only codes that are wrong for this repo's structure, with
# the reason inline. SC1090: helpers sourced through a runtime-resolved path.
# SC2016: single-quoted `$` that is deliberately not expanded.
disable=SC1090,SC2016
```

The settings lines of this block equal librarian's own `.shellcheckrc`;
`tests/validate-repo-baseline-slices.sh` fails if they drift apart.

shfmt has no config file here; its flags are fixed in the hook and gate
invocations (`-i 4 -ci`: 4-space indent, indented `case` arms). An
`.editorconfig` with `[*.sh] indent_style = space` / `indent_size = 4` /
`switch_case_indent = true` is the equivalent if a repo prefers a file.

## Hook entries

`lefthook.yml` — pre-commit:

```yaml
pre-commit:
  commands:
    shellcheck:
      glob: "*.sh"
      skip:
        - run: "! command -v shellcheck >/dev/null 2>&1"
      run: shellcheck --severity=warning {staged_files}

    shfmt:
      glob: "*.sh"
      skip:
        - run: "! command -v shfmt >/dev/null 2>&1"
      run: shfmt -w -i 4 -ci {staged_files}
      stage_fixed: true
```

No separate pre-push entry: the whole-tree shellcheck and portability lint run
inside the single test entry point, which pre-push already calls (`core.md` § 1).

## CI job

GitHub Actions — `lint` stage:

```yaml
shell-lint:
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/checkout@<40-char-sha> # vX.Y.Z
    - run: sudo apt-get install -y shellcheck
    - run: command -v shellcheck # fail, never skip, when the install did not land
    - run: bash tests/lint-shellcheck.sh
    - run: bash tests/lint-shell-portability.sh
```

GitLab CI — `lint` stage:

```yaml
shell-lint:
  stage: lint
  image: koalaman/shellcheck-alpine:v0.10.0 # pinned tag, never :latest
  script:
    - apk add --no-cache bash
    - bash tests/lint-shellcheck.sh
    - bash tests/lint-shell-portability.sh
```

`tests/lint-shellcheck.sh` runs `shellcheck --severity=warning` per file over the
shell trees — the same invocation as the hook, so the two agree.
`tests/lint-shell-portability.sh` bans the bash-4 constructs and GNU-only
flags/regex that bash 3.2 and BSD `grep`/`sed`/`env` do not support. Both exit
the `77` sentinel only when their tool is absent; in CI that cannot happen,
because the job installs the tool first.

## Test framework & runner

[bats-core](https://github.com/bats-core/bats-core), with `bats-support` and
`bats-assert` for assertions and `bats-mock` when a test must stub an external
command. Suites are `tests/*.bats`, run as `bats tests/` **from** the single
entry point `tests/run.sh` (`core.md` § 6) — never as a separate CI job, so the
hook, CI, and a developer all run the same thing. When `bats` is absent the
entry point reports the stage as skipped, never as passed. Tests follow
Arrange-Act-Assert (`shell-scripting` § Testing). The reasoning, and the two
properties any shell test framework must keep, are in `shell-scripting`'s
`test-framework.md`.

**Legacy exception — librarian itself.** The reference repo predates this
decision and keeps its home-grown harness, `tests/lib/harness.sh`, dispatched
by `tests/run-all.sh`. Migrating its suites would fix no defect. A new repo
does not copy it.

## Size-budget override

`sh` — the `per_language.sh` key under `review_size_thresholds` in
`check-decomposition/thresholds.yml`. Shell carries more lines per unit of
logic than the default budget assumes, so the review lens gives it a looser
pair; the audit lens uses the default.

## Open decisions

- **Pinning shellcheck and shfmt** to an exact version with one source, per
  `core.md` § 4. Both are unpinned today; bats-core is pinned above.
