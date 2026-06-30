---
name: git-cliff-checksum-sha512
description: "git-cliff release assets ship .tar.gz.sha512 (not .sha256) per-asset checksums + .sig; verify against the published sibling, not a hardcoded hash"
metadata:
  node_type: memory
  type: reference
  originSessionId: 01092dc9-35b3-479e-8b0b-2d7eb320b6ea
---

The orhun/git-cliff GitHub releases publish, for every binary asset
(`git-cliff-<ver>-<arch>-<os>.tar.gz`), a sibling `<asset>.tar.gz.sha512` and a
`<asset>.tar.gz.sig` — **SHA-512, not SHA-256**, and no aggregate
`checksums.txt`. The `.sha512` file is `<hexdigest>  <basename>`, directly
consumable by `sha512sum -c` (Linux) / `shasum -a 512 -c` (macOS).

`bin/lib/release/git-cliff.sh`'s fallback installer verifies the downloaded
tarball against this published `.sha512` (download → verify → extract →
install, fail-closed) rather than a hardcoded constant — a pinned hash would
need hand-updating on every `GIT_CLIFF_VERSION` bump and rots. Fixed in issue

# 94 / PR #112

Related: [[release-process]], [[release-from-worktree-gitcliff]].
