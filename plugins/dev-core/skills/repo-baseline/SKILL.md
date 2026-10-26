---
description: Repo baseline standard — the hook layout, always-on tools, CI shape, version-pinning policy, and docs/test minimums every repo gets, plus the contract a per-language slice fills in. Use when setting up a new repo's tooling, auditing one against the baseline, or writing a language slice.
---

# Repo Baseline

One written baseline for a repo's tooling, so a new repo does not copy config by
hand and drift, and so an audit has something to check against. It has two
layers:

- **Core** (`core.md`) — language-independent: what runs at each hook stage, the
  skip-guard rule, the always-on tools, the CI shape (GitHub Actions and GitLab
  CI), the version-pinning policy, and the docs and test minimums.
- **Slices** (`languages/<lang>.md`) — one per language: its tools and pinned
  versions, config files, hook entries, CI job, test runner, and size-budget
  override. Every slice fills in the same headings, defined by
  `slice-contract.md`, so audit and scaffold tooling can read any slice
  generically.

## Which file to load

| You are…                                         | Load                                  |
| ------------------------------------------------ | ------------------------------------- |
| Setting up hooks / CI / tool pins for a repo     | `core.md`, then the slice per language |
| Writing or reviewing a language slice            | `slice-contract.md`                   |
| Working in a shell-heavy repo                    | `languages/shell.md`                  |
| Working in a Python repo (scripts or package)    | `languages/python.md`                 |
| Checking a repo against the baseline             | `core.md` § Checklist, each slice      |

## The rules that matter most

1. **Hooks may skip; CI may not.** An optional tool carries a `skip:` guard so a
   hook never blocks a machine without it. CI installs every tool and runs every
   check unguarded — a tool missing in CI is a failure, never a skip.
2. **One entry point.** The pre-push hook and CI call the same test command, so
   "green locally" and "green in CI" mean the same thing.
3. **Exact pins, one source each.** Every tool version lives in exactly one
   file, read through one accessor; a mismatched local install fails loudly
   rather than drifting.
4. **Never `--no-verify`.** Fix the finding; a skipped hook is a CI failure
   deferred.

## When to Use

- Bootstrapping a repo's `lefthook.yml`, CI workflow, and lint config
- Deciding how to pin a tool version, or what a contributor does when a local
  tool disagrees with the pin
- Adding a language slice under `languages/`
- Reviewing a PR that changes hooks, CI stages, or tool pins

## When NOT to Use

- Language idioms and coding style — use `shell-scripting`, `code-quality`,
  `testing-patterns`
- Commit message and branch conventions — use `git-workflow`
- Per-file size thresholds themselves — they live in
  `check-decomposition/thresholds.yml` (see `core.md` § Size budgets)
