# Shell Test Framework and Lint Baseline

Companion to `SKILL.md`. The recorded decision for how a repo tests and lints
its shell (#1212). The repo-baseline shell slice
(`repo-baseline/languages/shell.md`) states the resulting tooling and cites this
file for the reasoning rather than re-deriving it.

## Decision: bats-core for new repos

A **new** repo tests its shell with
[bats-core](https://github.com/bats-core/bats-core), plus `bats-support` and
`bats-assert` for assertions and `bats-mock` when a test must stub an external
command. Vendor them as git submodules under `tests/` (or install them from the
package manager in CI); coverage via `kcov` is optional.

The two exemplar repos **keep their home-grown harnesses**. librarian has 127
suites on `tests/lib/harness.sh`; containers has 255 on `tests/framework.sh`.
Migrating either fixes no defect, and both encode lessons a bats repo must keep
by convention (see "Non-negotiables" below).

## Criteria

| Criterion           | bats-core                                | librarian `tests/lib/harness.sh`           | containers `tests/framework.sh`           |
| ------------------- | ---------------------------------------- | ------------------------------------------ | ----------------------------------------- |
| Install friction    | submodule or package; no harness to own  | copy ~660 LOC core + runner, then prune    | ~2.3k LOC; Docker required by default     |
| bash 3.2 / macOS    | yes                                      | yes (gated by `lint-shell-portability.sh`) | **no** — `declare -g` needs bash 4.2      |
| Failure readability | expected/actual diff, line number, trace | message then details                       | `Expected:` / `Actual:` / `Message:`      |
| Mocking             | `bats-mock` `stub`/`unstub`, call counts | ad hoc PATH stubs per sandbox              | domain-specific stubs                     |
| Coverage            | kcov recipe (community)                  | none for bash                              | none                                      |
| CI output           | TAP, JUnit                               | text report                                | text report                               |
| Coupling            | none — standalone tool                   | moderate: contract/analyzer assertions     | high: hardcoded paths, Docker tracking    |

Neither home-grown harness is worth extracting for a new repo: the bash-4.2
dependency rules out containers' on stock macOS, and librarian's would need its
repo-specific assertions pruned first, leaving a smaller bats with nobody
maintaining it.

## Non-negotiables

Whatever the framework, a repo's shell tests must keep the two properties
both exemplars learned the hard way:

- **A failed suite exits non-zero.** A suite that prints `FAIL` and exits 0
  reads as green to every caller (#899). bats does this by default; a custom
  runner must end on its reporter.
- **An absent tool is a visible skip, never a pass.** A gate whose linter is
  not installed must say it did not run (librarian reserves exit 77,
  #538/#571). In bats, `skip "shellcheck not installed"` — never an early
  `return 0`.

## Lint baseline

- **shellcheck at `--severity=warning`, on the command line.** `.shellcheckrc`
  cannot set severity: shellcheck 0.10.0 silently ignores a `severity=` key
  (`severity=error` still prints notes). Both exemplar repos carried
  `severity=info` in their rc files and enforced `warning` in every gate, so
  the "difference" #1212 set out to reconcile was one dead line in each.
  Moving the gates to `info` was measured on librarian and rejected:
  141 rows (46 SC2015, 36 SC2317, 16 SC2086) against 0 at `warning`, mostly
  style notes on intentional idioms.
- **`.shellcheckrc`**: `shell=bash`, `source-path=SCRIPTDIR`,
  `external-sources=true`, `disable=SC1090,SC2016`. The two source keys make
  a global SC1091 disable unnecessary (32 rows without them, 0 with them on
  librarian). Keep SC1090 only where sourcing is dynamic by design, and SC2016
  for shell text written into files, crontabs, or `bash -c`.
- **shfmt `-i 4 -ci`**, write mode in the pre-commit hook.

## Vendored "fleet copy" scripts

A repo that vendors copies of a script shared with other repos must not
format one copy alone: the formatted copy drifts from every sibling, and the
next sync either reverts the formatting or forks the script. Enable shfmt
across **all** copies in one sweep, or move the shared script to a single
source that the other repos consume.
