# agnix gate inertness — issue #766

Records the evidence for
[#766](https://github.com/joshjhall/librarian/issues/766)
("the agnix gate is inert — the binary never installs"), including the
**correction of the issue's stated cause**, which measurement contradicted.

This file exists because the primary symptom **cannot be observed in-session**:
the gate skips only where agnix is missing from PATH, and a development host
with agnix installed reports a healthy `[ok]`. The before/after signal lives in
CI job logs, reproduced here.

## What was wrong on `main`

`tests/lint-agnix-clean.sh` (the #734 gate asserting this repo's AI-config
artifacts are agnix-error-free) reported, on every run, in a **green** job:

```text
=== agnix error-free (#734) ===
SKIP (agnix not on PATH — optional enrichment (ADR §2/§4); install to run this gate)
[SKIP] agnix error-free — did not run (0s)
```

The sibling workflow failed the same way by its own route — `code-scanning.yml`
run `33038684447`:

```text
##[warning]agnix produced no valid SARIF (crash or empty output) — skipping
code-scanning upload. This is a signal, not a clean scan.
```

## The issue's stated cause was wrong

The issue attributed this to npm 11 gating lifecycle scripts, so that agnix's
`postinstall` never ran and `bin/agnix-binary` never landed. Measured on
npm 11.17 / node 24 (the same major CI runs):

| Probe | Result |
| --- | --- |
| `npm install --ignore-scripts` into a scratch prefix | `bin/` holds only the 707-byte JS wrapper — as the issue says |
| `npm install -g <scratch>/node_modules/agnix` | **`bin/agnix-binary` (8.5 MB) DOES land.** The postinstall runs |
| Same, with the issue's suggested `--allow-scripts=agnix` | **No change.** The warning is not even silenced |

The `npm warn allow-scripts` line in the CI log is advisory notice of a *future*
npm default. It is not the failure, and the fix derived from it is a no-op.

**The evidence that falsifies the theory outright** is in `ci.yml` run
`33038684382`: the install step **succeeded** —

```text
agnix binary restored from cache (sha256 b8fd1cd4…)
added 1 package in 264ms
```

— with no `::notice::agnix install failed`, and the gate *still* reported
`agnix not on PATH`. An install-failed theory predicts that notice; it is absent.

## Actual cause — a dangling symlink

`npm install -g <local-dir>` **symlinks** the directory rather than copying it.
The install step then ends with `rm -rf "$verify_dir"`, deleting the link's
target. Reproduced directly:

```console
$ npm install -g --prefix /tmp/gA /tmp/abA/node_modules/agnix
$ readlink /tmp/gA/lib/node_modules/agnix
../../../abA/node_modules/agnix          # a link INTO the scratch tree

$ agnix --version                        # before cleanup
agnix 0.49.0
$ rm -rf /tmp/abA                        # what the step does to itself
$ agnix --version
bash: agnix: command not found
```

By the time `tests/run-all.sh` runs (two steps later) agnix resolves nowhere, so
the gate takes its absent-binary 77 skip. The step that broke it reports success,
because the breakage happens *after* it, to a consumer it cannot see.

**Independently corroborated on this dev container**, which had been left in
exactly that state by an earlier ordinary install:

```console
$ ls -la /cache/npm-global/bin/agnix
… agnix -> ../lib/node_modules/agnix/bin/agnix
$ readlink -f /cache/npm-global/bin/agnix
                                          # empty — dangling
```

## Why no existing gate caught it

`test_scratch_dir_is_cleaned_up` already asserts the cleanup follows the
install — and it **passed on every run while the bug was live**. The ordering was
never wrong. A *correctly ordered* cleanup breaks a *symlinked* install. The
property that distinguishes the two states is the install **mode**, which no
assertion covered. That gap is now closed by
`test_global_install_copies_not_symlinks`.

## The fix, and its two load-bearing side conditions

`--install-links` makes npm **copy** the package, so the global tree outlives
`$verify_dir`. Verified:

```console
$ npm install -g --install-links --prefix /tmp/gF /tmp/abF/node_modules/agnix
$ rm -rf /tmp/abF
$ agnix --version
agnix 0.49.0                              # survives the cleanup
```

Two properties confirmed rather than assumed, because both could have regressed
silently:

1. **The #740 supply-chain guarantee holds.** `npm install -g --install-links
   --offline` from the verified tree **succeeds** — impossible if any byte still
   had to be fetched. The audited bytes remain the installed bytes. (This reuses
   the `--offline` probe `code-scanning.yml`'s own comment nominates for exactly
   this question.)
1. **#742's binary cache needed a matching change.** Under `--install-links` the
   postinstall writes into the **global** root, not `$verify_dir` — so the
   staging line would have found no file, taken its `-f` guard's silent no-op,
   and quietly stopped populating the cache forever, green. Staging now reads
   ``npm root -g``/agnix/bin. The cache-**hit** path is unaffected: seeding into
   `$verify_dir` before the global install still short-circuits the download
   (verified — no `Downloading`/`Checksum` lines on a seeded tree).

A stale comment in `ci.yml` asserted the symlink behavior and built the staging
design on it; it is rewritten rather than left to mislead the next reader. Note
the two workflows' comments **contradicted each other** on this point
(`ci.yml` "SYMLINKS" vs `code-scanning.yml` "PACKS") — measurement settled it and
both now say the same thing.

## Local evidence, before and after

The gate could not be exercised in-session until agnix was installed **with the
fix**. Once it was:

```text
  Global install passes --install-links (survives cleanup, #766) ... PASS
  agnix output carries a parsable summary (fail-loud, not skip) ... PASS
  0 agnix errors over CLAUDE.md AGENTS.md plugins ... PASS
  Scan reached the corpus (gate is not a no-op) ... PASS

Summary
  Total:   15
  Passed:  15
  Failed:  0
  Skipped: 0
```

and in the full suite `[SKIP] agnix error-free — did not run` became
`[ok] agnix error-free`.

Mutation-tested rather than trusted (both workflows, independently): removing
`--install-links` from `ci.yml` alone fails only the new assertion; removing it
from `code-scanning.yml` alone fails only that file's. The pre-existing ordering
test stays green through both — which is precisely the point.

The exit code the new CI assertion reads was probed in both states:

```console
$ bash tests/lint-agnix-clean.sh >/dev/null 2>&1; echo $?
0                                         # agnix present — gate ran
$ # with agnix removed from PATH:
77                                        # the #766 state the step now fails on
```

## The regression signal

The issue asked for a positive "did the gate actually run?" check, and correctly
noted agnix must **not** join the hard PATH assertion (it is best-effort per ADR
0001 §2/§4 — a fork PR or registry outage must still skip, not fail).

The new `Assert the agnix gate actually ran` step is conditioned on the install
step's own `installed=true` output, written only on its success branch. So the
assertion fires only on the combination that is always a defect — **agnix
installed, and the gate still did not run** — and stays silent whenever agnix is
legitimately unavailable.

## Remaining CI-only confirmation

Everything above is local or from pre-fix CI logs. The post-fix CI signal must be
read off the PR run:

- `Skill/agent quality gates` → `[ok] agnix error-free`, **not** `[SKIP] … did
  not run`.
- `agnix → code scanning` → uploads SARIF, **not** `produced no valid SARIF`.
- `Assert the agnix gate actually ran` → passes (proving it is armed, since it
  runs only when the install reported success).

Both were failing signals before this change, so they are genuine before/after
evidence rather than a check that was always green.
