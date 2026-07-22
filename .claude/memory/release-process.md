---
name: release-process
description: "How librarian cuts a repo-level semver release (VERSION + vX.Y.Z tag + CHANGELOG) and what containers#608 pins to"
metadata:
  node_type: memory
  type: project
  originSessionId: 5ef35931-1874-450d-9431-6255128dc6e2
  modified: 2026-07-22T01:03:13.488Z
---

Librarian has a repo-level semver release flow (added in PR #35, issue #31;
first release v0.1.0 published 2026-06-28). Latest: **v0.8.0** (2026-07-22, minor
— 45 commits / 12 feats since v0.7.0 incl. #487 GOLEM_MODEL, #488 checkpoint
suppression; PR #500). NOTE: `just release-patch` was requested but the range had
12 `feat` commits → semver says **minor**; flag the bump mismatch before cutting.

**Confirmed PR-then-tag recipe (v0.7.0, re-confirmed v0.8.0):** `just release-minor` (bumps
VERSION/manifests/CHANGELOG, NO commit) → commit on a `release/vX.Y.Z` branch as
`chore(release): release version X.Y.Z` (`release` IS a valid conform scope) →
PR to main → after green CI, squash-merge → `git checkout main && git pull` →
`git tag -a vX.Y.Z -m "Release version X.Y.Z" <merge-sha> && git push origin
vX.Y.Z`. The annotated tag is **auto SSH-signed** (git `user.signingkey` config),
separate from release.yml's cosign artifact signing. `release.yml` fires on the
`v*` tag → validates, asserts VERSION==tag, cosign-keyless-signs, publishes.
Verify after: `gh release view vX.Y.Z` shows `librarian-X.Y.Z.tar.gz` +
`.tar.gz.sigstore.json`, and `gh api repos/joshjhall/librarian/releases/latest -q
.tag_name` returns the new tag (what containers' LIBRARIAN_REF discovers).

**Two version concepts — keep distinct:**

- Per-plugin semver (`plugins/*/.claude-plugin/plugin.json`) — consumed by
  `claude plugin update`.
- Repo-level release tag (`vX.Y.Z`) — what containers' `LIBRARIAN_REF` pins to,
  discovered via `gh api repos/joshjhall/librarian/releases/latest -q .tag_name`.
  Unblocks joshjhall/containers#608.

**To cut a release:** `just release-{patch,minor,major}` (never hand-edit
`VERSION`). `bin/release.sh` bumps VERSION, runs `bin/stamp-versions.mjs` to
re-align all manifests in lockstep (keeps `tests/validate-manifests.mjs` green),
and regenerates `CHANGELOG.md` via git-cliff (`cliff.toml`). It does NOT
commit/tag/push by default — review, PR the changelog to main, then push an
annotated `vX.Y.Z` tag. `.github/workflows/release.yml` fires on `v*`: runs the
CI gates on the tagged tree, asserts VERSION == tag, and publishes the GitHub
Release with the matching CHANGELOG section.

**Gotchas:**

- `_typos.toml` allow-lists `ba` (the sed `:a ... ba` branch idiom in the
  changelog-trimming commands) and excludes generated `CHANGELOG.md`.
- A bare `typos` scan also trips on pre-existing regex fragments in
  `plugins/review-audit/skills/check-docs-staleness/patterns.sh` (`deprecat`,
  `updat`) — the pre-push hook only scans pushed files, so it doesn't block
  unrelated pushes, but `just lint`/full scans will surface it.
- Verify the release landed: see [[verify-squash-merge-landed]].
