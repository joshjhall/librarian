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
`APT_SOURCES_LIST_D` with `APT_INSTALL_SKIP_APT=1`. That covers the **decision**
— which files get disabled, that a deb822 `.sources` is caught alongside a
legacy `.list`, that a re-run does not double-rename, that the constructed
command carries `Acquire::Retries=3` and every package argument.

It does **not** cover whether `apt-get` then succeeds, because that arm never
invokes apt. That is precisely the half this file records.

`tests/lint-apt-hardening.sh` covers the other acceptance criterion (AC2 — the
fix applied to *every* workflow step running `apt-get`) offline and permanently,
by failing the tree on any workflow `apt-get` not routed through
`bin/apt-install.sh`.

## The run

- **Job**: the three shard legs of `quality-gates` — `10-portability`,
  `20-golem`, `30-scanners` — plus their dependent `Merge gate`
- **Step**: `Install jq + shellcheck` → `bash bin/apt-install.sh jq shellcheck`
- **PR**: [#1028](https://github.com/joshjhall/librarian/pull/1028)
- **Run**: [34792260225](https://github.com/joshjhall/librarian/actions/runs/34792260225)
  (2026-09-14) — all checks green

## VERIFIED — live

Transcribed verbatim from the `Install jq + shellcheck` step of
`Skill/agent quality gates (10-portability)`
([job 103818564011](https://github.com/joshjhall/librarian/actions/runs/34792260225/job/103818564011)).
Identical output on `20-golem`; the step exited 0 on all three shards and each
went on to run its tests.

```text
apt-install: disabled third-party source /etc/apt/sources.list.d/microsoft-prod.list
apt-install: disabled third-party source /etc/apt/sources.list.d/google-chrome.sources
apt-install: disabled third-party source /etc/apt/sources.list.d/ubuntu.sources
apt-install: disabled 3 third-party source(s) in /etc/apt/sources.list.d
Reading package lists...
jq is already the newest version (1.7.1-3ubuntu0.24.04.2).
shellcheck is already the newest version (0.9.0-1).
apt-install: installed jq shellcheck
```

Against the three conditions stated in advance:

1. **N >= 1** — yes, N = 3. The image does ship third-party sources, and the
   Chrome source from the original report is among them (now as deb822
   `google-chrome.sources` rather than the `.list` of 2026-09-09).
2. **Step exits 0 and the shard runs its tests** — yes, on all three shards.
3. **Named sources include Google Chrome** — yes.

## What this run caught that no sandbox test could

The evidence **fails on its own terms**, and that is the point of collecting it.

Line 3 disables `/etc/apt/sources.list.d/ubuntu.sources` — **Ubuntu's own
archive**. Ubuntu 24.04 moved the main archive out of `/etc/apt/sources.list`
into a deb822 file in that directory, so the original "everything here is
third-party" premise was simply false on this image, and `apt-get update` ran
with **no sources at all**.

The run went green anyway, which is the dangerous part: `jq` and `shellcheck`
were *already the newest version* on the image, so nothing needed downloading.
The first package that genuinely required a fetch would have failed, and the
failure would have pointed nowhere near its cause.

No sandbox test could have found this. `tests/validate-apt-install.sh` builds
its own sources directory, and a directory contains an `ubuntu.sources` only if
a test puts one there — the bug lived in an assumption about the real image,
which is exactly the class of thing AC3 exists to check.

**Fixed** in the same PR: the script now keeps Ubuntu's own sources
(`ubuntu`, `ubuntu-esm-*`, `ubuntu-pro-*`) and reports each one it keeps, with
`test_keeps_ubuntu_own_sources` pinning the behaviour.

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
