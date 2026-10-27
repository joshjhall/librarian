# repo-baseline tool cache — e2e verification (#1249)

Evidence for the four acceptance criteria of #1249: the rendered GitLab CI
caches the tools `bin/install-tools.sh` installs, keyed on the pin files.

## Design: cache the verified downloads, not the installed binaries

The issue proposed caching `$HOME/.local/bin` and the `TOOLS_HOME` prefix. Two
facts ruled that out:

- **GitLab caches only paths inside `$CI_PROJECT_DIR`.** A cache of
  `$HOME/.local/bin` would never be saved.
- **`tools.sha256` hashes the release archives, not the extracted binaries.** A
  cache of installed binaries cannot be checked against it. It could only be
  trusted on the strength of its key.

So the cache holds the downloads. `install-tools.sh` reads an optional
`TOOLS_CACHE` directory, keyed like `tools.sha256`. That answers the issue's open
question ("re-verify or trust the key?"): **every cache hit is re-verified.** A
cached file goes through the same sha256 check as a fresh download. A match skips
the network; a mismatch is discarded and downloaded again. Only bytes that passed
the check are ever written to the cache, through a `.partial-*` sibling and a
rename, so an interrupted copy cannot leave a truncated entry under a real key.

The GitLab template sets `TOOLS_CACHE: $CI_PROJECT_DIR/.tools-cache`, caches
`.tools-cache/` under `cache:key:files: [tools.versions, tools.sha256]`, and the
rendered `.gitignore` excludes the directory.

## AC1 — GitLab template caches the installed tools keyed on the pin files

**VERIFIED**, and pinned by `tests/validate-repo-baseline-templates.sh`:

- `test_rendered_gitlab_tool_cache` asserts that the rendered `.gitlab-ci.yml`
  keys `default.cache` on exactly `tools.versions tools.sha256`, caches
  `.tools-cache/`, and points `TOOLS_CACHE` at that path, and that the rendered
  `.gitignore` lists `.tools-cache/`.
- `test_install_tools_cache_is_reverified` runs the rendered installer's own
  `fetch` through these cases, with `curl` stubbed:

| Case | Result |
| ---- | ------ |
| Empty cache | downloads, installs, stores the verified bytes, leaves no `.partial-*` |
| Cache hit, `curl` failing every URL | installs: no download ran |
| Tampered entry, `curl` failing | exit 1, `cached conform-x fails its sha256`, nothing installed, entry dropped |
| Tampered entry, `curl` working | re-downloads, installs the good bytes, replaces the entry |
| Download fails its sha256, cache set | exit 1, nothing cached |

**Mutation-tested.** Two mutants of `install-tools-head.sh.tmpl`, each run
against the full suite:

- Trusting a cache hit without re-verifying (`if true`): the cache case fails.
- Writing to the cache before verifying the download: the cache case fails.

The suite was green again after restoring the file, which `cmp` confirmed
byte-identical to the pre-mutation copy.

**Real installer, aarch64 (2026-10-27).** Rendered `--slices shell,python
--ci gitlab` and ran `bin/install-tools.sh` twice into separate scratch
`TOOLS_BIN`/`TOOLS_HOME` directories, sharing one `TOOLS_CACHE`:

| Run | Network | Result | Wall time |
| --- | ------- | ------ | --------- |
| 1, empty cache | live | `install-tools: ok`, all 14 tools; 14 artifacts cached, one per `tools.sha256` key | 7.2 s |
| 2, warm cache | HTTPS routed to a dead proxy (`127.0.0.1:9`) | `install-tools: ok`, all 14 tools | 1.5 s |

Run 2 could not have downloaded anything, so every tool came from the cache and
passed its sha256 check.

## AC2 — a pin bump invalidates the cache (key changes)

**VERIFIED — live, 2026-10-27** (pipeline 6815 in the AC4 run below). A commit
that changed only `tools.sha256`, appending one comment line, moved the key:

| Pipeline | Cache key | Restore | Install |
| -------- | --------- | ------- | ------- |
| 6814, before | `0_tools_tools-d44e0a536bcefe639aaa84aca428ff6dd4331ef2-protected` | `Successfully extracted cache` | 4.2 s |
| 6815, after | `0_tools_tools-a4f667d3b9983b11e13fd0d522edfc86d1e2ff12-protected` | `Cache file does not exist` | 19.9 s, then `Created cache` under the new key |

That is the lint job of each pipeline. Why it holds for every bump: GitLab
derives a `cache:key:files` key from the commits that last changed those files,
so editing either file yields a new key. Every pin bump touches
`tools.sha256`, including ruff and uv, whose version pins live in `ruff.toml` and
`uv.toml` but whose digests are recorded there. Even an entry that somehow
survived a bump would fail its sha256 check against the new digest and be
downloaded again: the key decides freshness, but it is never what decides trust.

## AC3 — rendered `.gitlab-ci.yml` passes `glab ci lint` and the templates gate

**VERIFIED.**

- `glab ci lint .gitlab-ci.yml` against the self-hosted GitLab CE instance:
  **`✓ CI/CD YAML is valid!`**
- `tests/validate-repo-baseline-templates.sh`: **24 passed, 0 failed, 0
  skipped**.

## AC4 — second pipeline on a self-hosted GitLab shows a cache hit

**VERIFIED — live, 2026-10-27**, on the self-hosted GitLab CE instance (shared
runner, gitlab-runner 19.5.1, Docker executor, linux/amd64, local cache only, no
shared cache server). The scaffold was rendered with `--slices shell,python --ci
gitlab` and pushed with a sample `bin/hello.sh` + `tests/hello.bats` and
`tests/test_ok.py`. It ran as four pipelines in an operator-provided project.
Every job of every pipeline succeeded, and every test job printed `[ok] shell
(bats)` and `[ok] python (pytest)`.

| Pipeline | What changed | Cache restore | `install-tools.sh` |
| -------- | ------------ | ------------- | ------------------ |
| 6812 | initial push, stock template | lint: `Cache file does not exist`; test, security: `Successfully extracted cache` | lint 13.9 s (cold); test 11.2 s; security 13.3 s |
| 6813 | install run under `time` with HTTPS sent to a dead proxy | `Successfully extracted cache` | lint **3.1 s**, `install-tools: ok`, all 14 tools |
| 6814 | stock install line under `time`, network on | `Successfully extracted cache`, all 3 jobs | lint 4.2 s; test 2.8 s; security 7.7 s |
| 6815 | one comment line appended to `tools.sha256` | `Cache file does not exist` (new key, see AC2) | lint 19.9 s (cold again) |

Within 6812, lint saved the cache (`.tools-cache/: found 15 matching artifact
files and directories`, the directory plus 14 artifacts), and test and security
restored it in the same pipeline. 6813's lint job printed
`TOOLS_CACHE=/builds/personal/test-project/.tools-cache`: the variable reaches
the job and names the cached path.

**6813 is the decisive run.** HTTPS went to `127.0.0.1:9`, so any download would
have failed the job. The install succeeded, so every tool came from the cache and
passed its sha256 check.

**Install time on a hit is noisy, not a download.** 6812's test and security jobs
restored the cache yet took 11–13 s. 6814 measured hits at 2.8–7.7 s. No job
printed `cached … fails its sha256`, the line every cache-to-download fallback
emits. With every entry present, that fallback is the only path to `curl`, so
the spread is hashing and unpacking on a shared runner. This is inferred from
the code path; 6813 is the direct proof that a hit downloads nothing.

**What the cache does not remove.** Each job still pulls the image and runs
`apt-get`, about 13 s of the 22–29 s warm job time in 6813. The issue also notes
the apt packages are unpinned. Both are outside this change; see the PR's
follow-ups.

The two probe commits (6813, 6814) edited only the project's own
`.gitlab-ci.yml`, never the template, and 6815 edited only a comment. The
shipped template is exactly what 6812 ran.

To re-run on another instance, use the recipe in
`repo-baseline-templates-e2e-1219.md` § AC3, then push a second commit and look
for `Successfully extracted cache` on every job.
