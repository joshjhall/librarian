# apt hardening verification — issue #983

Records the live CI evidence for
[#983](https://github.com/joshjhall/librarian/issues/983)
("a broken third-party apt source in the runner image fails 3 shards before any
test runs"), specifically **AC3**:

> Verified by a run that installs `jq`/`shellcheck` successfully with the chrome
> source present-but-broken, or with it removed.

This file exists because that criterion **cannot be closed in-session**. The
failure lives in the GitHub-hosted `ubuntu-latest` image — its bundled
`/etc/apt/sources.list.d/google-chrome.list`, and an upstream index that is
corrupt only during a bad window. No local sandbox reproduces either half: this
devcontainer ships neither that source nor that runner's apt state.

## What the in-session suite does and does not cover

`tests/validate-apt-install.sh` drives `bin/apt-install.sh` against a sandbox
`APT_SOURCES_LIST_D` in `APT_INSTALL_DRY_RUN=1` mode. That covers the **decision**
— which files get disabled, that a deb822 `.sources` is caught alongside a
legacy `.list`, that a re-run does not double-rename, that the constructed
command carries `Acquire::Retries=3` and every package argument.

It does **not** cover whether `apt-get` then succeeds, because the dry-run arm
never invokes apt. That is precisely the half this file records.

`tests/lint-apt-hardening.sh` covers the other acceptance criterion (AC2 — the
fix applied to _every_ workflow step running `apt-get`) offline and permanently,
by failing the tree on any workflow `apt-get` not routed through
`bin/apt-install.sh`.

## The run

- **Job**: the three shard legs of `quality-gates` — `10-portability`,
  `20-golem`, `30-scanners` — plus their dependent `Merge gate`
- **Step**: `Install jq + shellcheck` → `bash bin/apt-install.sh jq shellcheck`
- **PR**: _pending — fill in from this PR's own CI run_
- **Run**: _pending_

## PENDING — to transcribe from the PR's CI run

Fill the block below verbatim from the `Install jq + shellcheck` step log of any
one shard, then change this heading to `VERIFIED — live`. The lines to capture
are the script's own report and the install result:

```text
apt-install: disabled third-party source /etc/apt/sources.list.d/<name>.list
apt-install: disabled N third-party source(s) in /etc/apt/sources.list.d
...
apt-install: installed jq shellcheck
```

What the evidence must show, stated before it is collected so it cannot be read
to fit:

1. **N ≥ 1** — the runner image did ship at least one third-party source, and it
   was disabled. An `N = 0` line would mean the image changed and this run
   proves nothing about the failure mode; it is not a pass for AC3.
2. The step **exits 0** and the shard proceeds to run tests. The original
   failure never reached a test.
3. The named sources include the Google Chrome one from the original report, or
   the log shows the image no longer ships it — either is informative, but they
   are different findings and should be recorded as such.

## Notes

- Original failure: PR #979,
  [run 34383263162](https://github.com/joshjhall/librarian/actions/runs/34383263162)
  (2026-09-09), `Hash Sum mismatch` on
  `dl.google.com/linux/chrome-stable/deb`. Re-running the failed jobs cleared it
  that time, which is exactly why it was worth fixing rather than re-running:
  the clearing is what makes each occurrence cost an operator decision instead
  of leaving a durable signal.
- A green run here does **not** prove the fix works during a bad upstream
  window — it proves the broken source is no longer consulted at all, which is
  the stronger property and the one the fix actually asserts.
