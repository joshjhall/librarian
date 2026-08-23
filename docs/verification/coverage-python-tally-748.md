# Python coverage measurement — issue #748

Records the live CI evidence for
[#748](https://github.com/joshjhall/librarian/issues/748)
("`coverage-python` drives only `patterns.py` — four shipped Python files are
never measured"), specifically **AC1**: *verify against a real CI run whether the
four files appear in `coverage.xml` at 0% or are absent entirely; record which.*

The issue asked for this to be **checked rather than assumed**, noting
`coverage.py` is not installed in the devcontainer. That was the right
instruction, because the answer turned out to be neither of the two options the
question offered.

## VERIFIED — live: the answer is "neither"

`coverage.xml` is **never produced at all**. The four files are not reported at
0%, and they are not merely missing from an otherwise-valid report — there is no
report. Python coverage has never run in CI.

- **Job**: `Coverage (python + mjs) → Codecov` — `.github/workflows/ci.yml`
- **Run**: [32624627255](https://github.com/joshjhall/librarian/actions/runs/32624627255),
  job `97157951856`, branch `main`, conclusion **success**
- **Date observed**: 2026-08-23

Transcribed verbatim from the job log:

```text
2026-08-23T07:05:31.4637296Z ##[group]Run pipx install coverage
2026-08-23T07:05:34.3264913Z   installed package coverage 7.15.4, installed using Python 3.12.3
2026-08-23T07:05:34.4894493Z [skip] python-coverage — coverage.py not installed (pip install coverage)
2026-08-23T07:05:39.6812664Z warning -- No coverage data found to transform
2026-08-23T07:05:39.7067070Z warning -- Some files were not found --- {"not_found_files": ["coverage.xml"]}
```

Three consecutive lines that should not be able to coexist: coverage.py installs
successfully, the script reports it as not installed, and Codecov finds no file.

## Why it happened

`pipx` installs into an **isolated venv** and exposes only the `coverage` console
script on PATH. `tests/coverage-python.sh` probed with
`python3 -c 'import coverage; coverage.Coverage'` and drove every port with
`python3 -m coverage` — neither of which resolves a pipx install. So the runtime
gate took its skip branch on every run.

The skip branch exited **0**. That is what made it invisible: a green step inside
a green job, with `fail_ci_if_error: false` on the upload, so the missing file
never surfaced either. This is the #538/#571 lesson — *silence is
indistinguishable from a pass* — reaching the one Python gate that had not
adopted the sentinel convention.

Reproduced locally after `pipx install coverage`: `command -v coverage` succeeds
while `python3 -c 'import coverage'` raises `ModuleNotFoundError`.

## Consequence for the issue's framing

The issue reasoned that the fix ("drive them") was the same either way. That
holds for the drivers, but it means the **runner fix is a prerequisite**: drivers
added to a script that skips before reaching them would have been exactly as
inert as the seventeen `patterns.py` ports already were. Both are in the same PR
for that reason.

The measured local run (post-fix, `coverage` resolved on PATH):

```text
Runner: coverage on PATH
[ok] python-coverage — 23 ports run, coverage.xml written (TOTAL 91%)
```

| File | line-rate |
| --- | --- |
| `scripts/autonomy-resolve.py` | 94.3% |
| `scripts/golem-event-listener.py` | 86.8% |
| `ship-issue/plan-lens.py` | 78.3% |
| `ship-issue/sizing.py` | 76.1% |
| `ship-issue/split-verify.py` | 89.7% |

Five files, not the four the issue named: `plan-lens.py` landed via #756 **after**
this issue was filed, and fell into the same hole while the issue describing that
hole sat open. It is the clearest possible argument for the last acceptance criterion
(a new non-`patterns.py` tool must not be able to ship unmeasured), now enforced
by `tests/validate-coverage-corpus.sh`.

## CLOSED — VERIFIED live on CI

The one claim that could not be closed in-session was that **CI itself** now
produces and uploads the report. Observed on PR
[#777](https://github.com/joshjhall/librarian/pull/777),
[run 32651064533](https://github.com/joshjhall/librarian/actions/runs/32651064533),
job `97222647155`, 2026-08-23 — the same job and the same evidence path that
produced the finding above:

```text
2026-08-23T16:14:57Z Runner: coverage on PATH
2026-08-23T16:15:18Z [ok] python-coverage — 23 ports run, coverage.xml written (TOTAL 91%)
2026-08-23T16:15:23Z info -- Your upload is now queued for processing.
2026-08-23T16:15:23Z info -- Upload queued for processing complete
```

- [x] the step prints `Runner: …` and `[ok] python-coverage — N ports run` —
      **not** `[skip]`
- [x] the Codecov upload no longer warns `not_found_files: ["coverage.xml"]` —
      the warning is gone and the file is uploaded by path
- [x] a `codecov/patch` PR status appears, which could not exist before: Codecov
      had no Python data for this repo to compare against

The step also went from ~1s (skip) to **38s** of real work, and the five
previously-unmeasured files are in the report at the line-rates tabulated above.

### What this tally did NOT verify

The `main`-branch run, specifically. The evidence is from the PR run of the same
job, on the same workflow file — the flag, the runner resolution, and the upload
are identical on both event types, and the coverage job's `if:` guard admits
same-repo PRs and pushes alike. If the post-merge `main` run should ever differ,
`COVERAGE_PYTHON_REQUIRED=1` turns it into a **red job** rather than a silent
skip, and the log names which runner failed to resolve:

```bash
gh run list --workflow=ci.yml --branch=main --limit 1 --json databaseId --jq '.[0].databaseId'
gh run view --job <coverage-job-id> --log | grep -E 'python-coverage|not_found_files'
```
