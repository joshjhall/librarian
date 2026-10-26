# Repo Baseline — Slice Contract

Companion to `SKILL.md`. What a **language slice** (`languages/<lang>.md`) must
define, so that audit and scaffold tooling can consume any slice generically:
the audit reads a slice to know which files, hook entries, and CI job to look
for; the scaffold reads it to know which files to write and with what contents.

A slice **adds** to the core (`core.md`); it never removes or relaxes a core
rule. Where a slice needs an exception (e.g. a toolchain that is never
skip-guarded), it states it under the relevant heading.

## Required headings

Every slice has exactly these `##` headings, in this order, spelled exactly as
listed. `tests/validate-repo-baseline-slices.sh` reads this list from between
the markers below and fails any slice that is missing one — so editing the list
here changes the gate, and no second copy exists to drift.

<!-- slice-contract:required-headings -->

1. `## Tools & versions`
1. `## Config files`
1. `## Hook entries`
1. `## CI job`
1. `## Test framework & runner`
1. `## Size-budget override`
1. `## Open decisions`

<!-- slice-contract:end-required-headings -->

A slice may add further `##` headings **after** these (language idioms,
portability notes) — but link to the language's dev-core skill for idioms rather
than restating them.

## What each heading must contain

### Tools & versions

A table: tool, purpose, **pinned version**, and the pin's **single source**
(the file the version lives in) and **accessor** (the command that reads it),
per `core.md` § 4. Mark each tool **optional** (skip-guarded in hooks) or
**required** (the build toolchain — never guarded). A tool with no pin yet says
`unpinned` and is listed under Open decisions; never leave the column blank.

### Config files

For each config file the slice owns: its **repo-relative path**, whether it is
**required** or **optional**, and its **literal contents** in a fenced block —
the exact bytes the scaffold writes. Where a value is repo-specific, mark it
with a `# per-repo:` comment and give the default.

### Hook entries

The literal `lefthook.yml` entries, in a fenced `yaml` block, grouped by stage.
Each entry has a `glob:`, a `run:` over `{staged_files}` (pre-commit) or the
whole tree (pre-push), a `skip:` guard if and only if the tool is optional, and
`stage_fixed: true` if and only if it rewrites files.

### CI job

The literal job(s) for **both** GitHub Actions and GitLab CI, each in a fenced
`yaml` block, slotting into the `lint` / `test` / `security` stages of
`core.md` § 3. The jobs install the pinned tools and run them **unguarded**.

### Test framework & runner

The test framework, the command that runs the slice's tests, and how that
command is invoked **from** the repo's single test entry point (`core.md` § 6)
— never as a second entry point beside it.

### Size-budget override

Either `none` (the language uses the default budget) or the language key the
slice expects in `check-decomposition/thresholds.yml`. The **numbers** live in
that table, not here (`core.md` § 7).

### Open decisions

Choices the slice has not settled, one bullet each with the options and who
owns the decision. `none` when there are none. An audit treats an item here as
"not yet checkable", not as a failure — which is why it must be listed rather
than left implicit.

## Machine-readability rules

- Paths are repo-relative and in backticks.
- Literal file contents and hook/CI entries are in fenced blocks with a language
  tag (`yaml`, `toml`, `ini`, …), one file per block, with the target path on
  the line immediately before the fence.
- Versions are exact (`0.10.0`), never ranges.
