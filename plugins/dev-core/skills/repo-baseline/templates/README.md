# repo-baseline scaffold templates

Plain files a repo adopts in one step: the hooks, linter configs, justfile, test
entry point, tool installer, and CI for **GitHub Actions and GitLab CI**, rendered
for the slices that apply. The specs these encode are `../core.md` and
`../languages/<lang>.md`; the files here are what a scaffold writes.

```bash
render.sh --slices shell,python --ci github,gitlab --out /path/to/repo
```

## Manifest format

`manifest.tsv` is the whole interface. A renderer needs nothing else — no
templating language, no YAML merge, no network — so a non-LLM tool
(`stibbons setup standards`) and a skill produce identical bytes.

One row per line, four **tab**-separated columns. Blank lines and lines starting
with `#` are ignored.

| Column   | Meaning                                                                 |
| -------- | ----------------------------------------------------------------------- |
| `target` | repo-relative output path; never absolute, never containing `..`        |
| `slice`  | owner slice: `core` (always rendered) or a language slice (`shell`, `python`) |
| `when`   | `always`, `ci=github`, or `ci=gitlab`                                   |
| `source` | template path relative to this directory                                |

**Render rule.** Keep a row when its `slice` is `core` or was selected, **and**
its `when` is `always` or names a selected CI platform. Then, for each distinct
`target` in first-appearance order, write the concatenation of its kept rows'
`source` files **in manifest order**. Mark a target ending in `.sh` executable.
Nothing else: no substitution, no escaping, no trailing-newline fix-up.

That is the full contract. Any other value in `slice` is a slice the manifest
defines; any other `when` is an error, as is a missing `source`. `render.sh` is
the reference implementation: it validates every row before writing anything,
and refuses to overwrite an existing target without `--force`.

## How composition works

A file several slices contribute to — `lefthook.yml`, `justfile`,
`tests/run.sh`, `bin/install-tools.sh`, `tools.versions` — is split into
**fragments cut at block boundaries**, so that concatenation is always valid:

- `lefthook.yml` — the core fragment opens `pre-commit: commands:`; each slice
  fragment is bare command entries at 4-space indent, so it lands inside it; the
  core `commit-msg` + `pre-push` fragment comes next, and a slice's pre-push
  entries follow it, landing inside `pre-push: commands:`. Slice fragments
  start with a blank line.
- `justfile` — the core fragment ends inside the `lint:` recipe; slice fragments
  are 4-space recipe lines; the core tail opens `test:`.
- `tests/run.sh` / `bin/install-tools.sh` — a core head defines the helpers
  (`stage`, `pin`, `fetch`, `from_tar`), each slice appends a stanza, and a core
  tail turns the result into the exit code.

So **a fragment's position in the manifest is part of its meaning.** Insert a new
slice's rows next to the existing slices' rows for the same target.

Two kinds of template are stored as `*.tmpl` so they stay inert in librarian,
and the manifest maps each to its real name. One is config files a tool would
otherwise discover inside this directory (`_typos.toml`, `ruff.toml`,
`.shellcheckrc`, …). The other is partial-script fragments (`run-head.sh.tmpl`,
…): they are not runnable on their own, so they must not be linted or tested as
if they were. A complete file keeps its real extension.

## What the rendered repo does

- **Hooks** (`lefthook install`): pre-commit runs the always-on tools plus each
  slice's linters on staged files, skip-guarded on contributor machines;
  commit-msg runs conform; pre-push runs whole-tree checks and `bash tests/run.sh`.
- **CI** calls the same entry points the hooks do: `bin/install-tools.sh`, then
  `just lint` (stage `lint`), `just test` (stage `test`), and gitleaks over the
  change range (stage `security`), plus a `merge-gate` job on GitHub. Slices add
  to `just lint`, `tests/run.sh`, and `bin/install-tools.sh` rather than adding
  jobs, so one install step covers every tool and nothing runs twice. The
  per-slice CI blocks in the slice docs are the **single-slice** form.
- **`tests/run.sh`** reports each slice as `[ok]`, `[FAIL]`, `[SKIP]` (runner
  absent, exit 77), or `[none]` (no test files). With `CI=true` — set by both CI
  templates — a skip fails the run.
- **`bin/install-tools.sh`** reads `tools.versions` (and each slice's own pin
  source: `ruff.toml` via `bin/ruff-version.sh`, `uv.toml`), installs into
  `$TOOLS_BIN` (default `~/.local/bin`), and fails if any tool did not land.
  Linux x86_64/aarch64 only. Each tool lands in a fresh staging directory first,
  and `$TOOLS_BIN` is updated only once **every** tool is present there. A stale
  binary from an earlier run, or a preinstalled copy on `PATH`, can never pass
  for this run's install, and a failed run leaves `$TOOLS_BIN` as it was.
  Multi-file tools (bats-core) stage their whole prefix the same way. Once every
  tool has landed, the prefix moves under `$TOOLS_HOME` (default
  `~/.local/share/repo-baseline-tools`) and a symlink is placed in `$TOOLS_BIN`.
- **`tools.sha256`** holds the sha256 of every artifact `install-tools.sh`
  downloads, keyed `<tool>-<arch>`. Each download is verified **before** it is
  extracted or installed, and a mismatch or a missing entry aborts the run. A
  version pin alone does not stop a re-tagged or compromised release. Several of
  these tools publish no checksums, so the digests are recorded here rather than
  fetched from the same release they would vouch for.

## After rendering

Edit every line marked `# per-repo:`, then `lefthook install`. The pins and
action SHAs are current as of the template; bump them per `core.md` § 4. A
version bump also needs the matching `tools.sha256` rows, for both arches, in
the same commit: download the new artifacts, then record `sha256sum` of each.
Where upstream publishes checksums, cross-check against them.

## Adding a slice

1. Write its fragments under `<slice>/`, matching the shapes above.
2. Add its rows to `manifest.tsv` beside the other slices' rows for each shared
   target, and one row per plain config file it owns.
3. Run `bash tests/validate-repo-baseline-templates.sh`: it renders every slice
   combination, parses and lints the output, pins fragments to the slice docs'
   fences, and runs the rendered hooks in a scratch repo.
