# repo-baseline scaffold templates — e2e verification (#1219)

Evidence for the three acceptance criteria of #1219. All three are verified;
AC3 ran on a self-hosted GitLab the operator provided for the run.

## AC1 — a shell+python render passes hooks and CI on a clean checkout

**VERIFIED — live, 2026-10-26**, and pinned by
`tests/validate-repo-baseline-templates.sh` (`test_live_hooks_pass`).

Rendered `--slices shell,python --ci github,gitlab` into a fresh `git init`
repo with a sample `bin/hello.sh`, `bin/greet.py`, and `tests/test_greet.py`,
ran `lefthook install`, then:

| Step                                   | Result |
| -------------------------------------- | ------ |
| `git commit` (pre-commit, 13 commands) | exit 0; `gitlab-ci-lint` skipped by condition (glab not authenticated) |
| commit-msg (conform)                   | exit 0 |
| `lefthook run pre-push`                | exit 0; `[ok] python (pytest)`, 1 passed |
| `just lint` (CI lint stage)            | exit 0 |
| `just test` (CI test stage)            | exit 0 |
| negative control: commit an unused import | rejected by `ruff-check` |

The shell stage reported `[SKIP] shell (bats)` locally — bats is not installed
in the devcontainer. CI does not take that path: the test job runs
`bin/install-tools.sh` first and sets `CI=true`, under which a skip fails.

**CI install path.** The rendered `bin/install-tools.sh` was run for real into a
scratch `TOOLS_BIN` with `PATH=/usr/bin:/bin` (aarch64 Linux): it downloaded all
14 tools and each reported exactly its pin — typos 1.51.1, dprint 0.61.1, taplo
0.10.0, rumdl 0.2.78, actionlint 1.7.12, gitleaks 8.30.1, conform
v0.1.0-alpha.31, lefthook 2.2.1, just 1.58.0, shellcheck 0.10.0, shfmt 3.14.1,
bats 1.14.0, ruff 0.16.10, uv 0.12.23. x86_64 was exercised by the AC3
pipeline below, where every job's install step reported the same 14 tools.

**Not run in session:** the rendered GitHub workflow on a real runner. It is
`actionlint`-clean and calls exactly the entry points exercised above.

## AC2 — manifest format documented for the stibbons integration

**VERIFIED.** `plugins/dev-core/skills/repo-baseline/templates/README.md` §
Manifest format states the full render rule (columns, `when` values, row
selection, concatenation in manifest order, the executable bit) — no templating
language or network, so stibbons can implement it independently.
`render.sh` is the reference implementation, and the gate checks determinism.

## AC3 — GitLab CI output validated on a self-hosted GitLab

**VERIFIED — live, 2026-10-27**, on a self-hosted GitLab CE 19.5.1 instance,
in a scratch project created for this run and removed afterwards.

Rendered `--slices shell,python --ci gitlab` into a fresh repo with a sample
`bin/hello.sh` + `tests/hello.bats` and `bin/greet.py` + `tests/test_greet.py`,
committed through the rendered hooks (all passed), then:

- `glab ci lint .gitlab-ci.yml` against the instance: **`✓ CI/CD YAML is valid!`**
- Pushed to `main`. Pipeline **6779: success**, all three jobs on one shared
  runner (gitlab-runner 19.5.1, Docker executor, linux/amd64), each pulling the
  pinned `debian:trixie-20261005-slim`:

| Job      | Result  | Duration | What ran |
| -------- | ------- | -------- | -------- |
| lint     | success | 100 s    | `install-tools: ok` (all 14 tools), then `just lint`: rumdl, ruff check + format, shellcheck, shfmt, typos, dprint, taplo |
| test     | success | 45 s     | `install-tools: ok`, then `just test` under `CI=true`: `ok 1 hello greets` → `[ok] shell (bats)`; `1 passed` → `[ok] python (pytest)` |
| security | success | 46 s     | `install-tools: ok`, then gitleaks on the branch pipeline (no MR base → full history): `1 commits scanned`, `no leaks found` |

Both test stages printed `[ok]`, not `[SKIP]` or `[none]`. Under `CI=true` a
skipped stage would have failed the job, so a green test job here proves the
suites ran. Most of the lint job's 100 s was the image pull plus `apt-get`. The
push used `LEFTHOOK=0` to bypass the probe repo's own pre-push hook: that hook
had already passed locally (AC1), and this run tests the pipeline.

**Changed after this run: download verification.** The pre-PR review found that
`install-tools.sh` pinned versions but not content, so a re-tagged release would
have run unverified in CI. Every download is now checked against `tools.sha256`
before it is installed (`templates/README.md`). Pipeline 6779 ran the
pre-verification script. A re-run on the instance was not possible because the
scratch project had already been removed. The replacement evidence:

- **aarch64, real run:** a full install verified and installed all 14 tools. A
  tampered digest and a missing entry each aborted with the tool **not**
  installed, on both the direct-binary and the tarball path.
- **x86_64, `uname` faked:** every x86_64 artifact the script downloads matched
  its digest and installed. Exit 0, all 14 tools.
- **Digests cross-checked:** 18 of the 27 recorded digests match upstream's own
  published checksums. typos, taplo, shfmt, shellcheck and bats publish none.
- **Offline gate:** `tests/validate-repo-baseline-templates.sh` pins the
  verification, and mutation-testing it killed every variant.

The one unexercised combination is the new script on a real x86_64 runner.
Pipeline 6779 already ran the same binaries there.

**Defect found and fixed by this run.** The rendered `gitlab-ci-lint`
pre-commit hook had two problems:

- **It skipped silently.** Its guard was `glab auth status`, which checks
  *every* configured host. One stale, unauthenticated gitlab.com entry made the
  guard fail, so the hook skipped on a machine that was logged in to the
  project's own instance.
- **It would have blocked the first commit.** Dropping that guard alone makes
  the hook fail in a freshly scaffolded repo, which has no remote yet
  (`no git remotes found`).

The guard now checks only that glab is installed and that a remote exists. Both
cases were re-run: with no remote the hook skips and the commit goes through;
with the instance remote it runs (`✓ CI/CD YAML is valid!`).
`tests/validate-repo-baseline-templates.sh` pins both guards.

To re-run on another instance:

```bash
out=$(mktemp -d)
plugins/dev-core/skills/repo-baseline/templates/render.sh \
  --slices shell,python --ci gitlab --out "$out"
cd "$out" && git init -b main && mkdir -p bin tests
printf '#!/usr/bin/env bash\necho "hello ${1:-world}"\n' > bin/hello.sh && chmod +x bin/hello.sh
printf '#!/usr/bin/env bats\n\n@test "hello" {\n    run bin/hello.sh x\n    [ "$output" = "hello x" ]\n}\n' > tests/hello.bats
printf 'def test_ok():\n    assert True\n' > tests/test_ok.py
printf '# Sample\n' > README.md
git add -A && git commit -m "feat: initial scaffold"
git remote add origin <self-hosted-project-url>
glab ci lint .gitlab-ci.yml                       # server-side schema check
git push -u origin main && glab ci view           # expect lint, test, security all passed
```

The runner must take untagged jobs (the template sets no `tags:`), use a Docker
executor on Linux x86_64 or aarch64, and reach `deb.debian.org`, `github.com`
(release downloads), `pypi.org`, and `plugins.dprint.dev`.
