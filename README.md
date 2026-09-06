# Librarian

[![CI](https://github.com/joshjhall/librarian/actions/workflows/ci.yml/badge.svg)](https://github.com/joshjhall/librarian/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/joshjhall/librarian/branch/main/graph/badge.svg)](https://codecov.io/gh/joshjhall/librarian)
[![Release](https://img.shields.io/github/v/release/joshjhall/librarian?sort=semver)](https://github.com/joshjhall/librarian/releases/latest)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-blue.svg)](#license)

A [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins)
of general-purpose skills and agents — usable on a host Mac, a bare Linux box,
and inside the [containers](https://github.com/joshjhall/containers) dev image
alike.

These artifacts used to live inside the `containers` repo and were baked into
every image. They were extracted here so they install the same way everywhere
via Claude Code's native plugin system — with `plugin update` semver rolling
updates for free — instead of being container-build-bound. The migration is
tracked in
[joshjhall/containers#607](https://github.com/joshjhall/containers/issues/607).

## Release notes

Per-release highlights and full notes live in [CHANGELOG.md](CHANGELOG.md),
regenerated from conventional commits on every release.

## Verifying a release

Every `vX.Y.Z` release is signed with [cosign](https://github.com/sigstore/cosign)
keyless signing (Sigstore — no long-lived keys) by the tag-triggered
`release.yml` workflow. This lets a consumer prove the marketplace it fetched
was published by this project and has not been tampered with.

**What is signed.** A deterministic archive of the whole marketplace tree at the
tag, produced by:

```bash
git archive --format=tar.gz --prefix=librarian-<version>/ v<version>
```

**Assets published per release** (attached to the GitHub Release):

| Asset | Contents |
|---|---|
| `librarian-<version>.tar.gz` | the signed archive (bytes covered by the signature) |
| `librarian-<version>.tar.gz.sigstore.json` | the Sigstore bundle — carries both the cosign signature and the Fulcio-issued signing certificate |

**Verification recipe.** Download both assets for a release, then:

```bash
cosign verify-blob \
  --bundle librarian-<version>.tar.gz.sigstore.json \
  --certificate-identity 'https://github.com/joshjhall/librarian/.github/workflows/release.yml@refs/tags/v<version>' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  librarian-<version>.tar.gz
```

The expected signer identity is this repo's `release.yml` workflow at the
release tag (`--certificate-identity` pins the **exact** ref — substitute the
concrete `v<version>`); the OIDC issuer is GitHub Actions
(`https://token.actions.githubusercontent.com`). A `Verified OK` result proves
both provenance and integrity. To verify without knowing the version up front,
swap in a semver-anchored regexp rather than a bare wildcard:

```bash
  --certificate-identity-regexp '^https://github.com/joshjhall/librarian/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
```

Signing is **additive** — the plain `vX.Y.Z` tag remains resolvable, so
clone-by-tag consumers that don't verify keep working unchanged.

## Plugins

| Plugin | Components | What's inside |
|---|---|---|
| **[dev-core](plugins/dev-core/README.md)** | 20 skills · 6 agents | General development + authoring: code review, debugging, refactoring, testing, git/error/doc workflow skills, and the skill/agent/workflow authoring guides. |
| **[review-audit](plugins/review-audit/README.md)** | 12 skills · 11 agents | The `codebase-audit` / `check-*` / `audit-*` suite plus the issue writer. |
| **[workflow](plugins/workflow/README.md)** | 10 skills · 3 agents · 1 hook | Issue-driven and parallel automation: the user-directed `/workflow:file-issue`, `/workflow:golem`, and `/workflow:orchestrate` entry points, the `next-issue` → `ship-issue` pipeline they drive, `provision-agent`, the `rebase-*` resolvers, and the bundled shell scripts they call. |

### Start here — what to invoke

Most of the components above run **automatically** or as sub-steps of something
else. Three workflow skills are the ones a human actually types:

- **`/workflow:file-issue`** — the front door. Turn a bug, idea, or note into a
  well-formed, auto-labeled issue ready for the pipeline below.
- **`/workflow:golem <issue>`** — work **one** issue end-to-end, solo, in the current
  session: an isolated worktree, the full `next-issue` → `ship-issue` pipeline,
  and the adversarial pre-PR review (the **Workflow tool** with
  `ship-issue/workflow.js`). No orchestrator, `tmux`, or containers.
- **`/workflow:orchestrate`** — work **2+** issues in parallel, one golem (worktree +
  branch + PR) each, then land the batch with a single integration train.

**Golem vs orchestrate:** reach for `/workflow:golem` when you have *one* issue and want
it worked with full rigor in-session; reach for `/workflow:orchestrate` when you have
*several* independent issues to run at once and integrate together.

### Common workflows

**Ship one issue, solo:**

```bash
# In a Claude Code session, at the repo root:
/workflow:file-issue        # (optional) capture the work as a labeled issue first
/workflow:golem 512         # worktree + next-issue → ship-issue + adversarial review → PR
```

`/workflow:golem` creates the worktree, plans and implements the fix, runs the pre-PR
review — the **Workflow tool** with `ship-issue/workflow.js`, which fans five
review dimensions out under one budget and judges them — opens the PR, and tears
the worktree down, pausing only at the gates your chosen autonomy level (L1–L4)
keeps.

**Run several issues in parallel, then integrate:**

```bash
/workflow:orchestrate dispatch 512 517 device-auth   # one golem per issue
/workflow:orchestrate status                         # watch PR + issue-label state
/workflow:orchestrate integrate                      # merge→rebase→merge the green PRs
```

Each golem owns its own branch, worktree, and PR; the integration train lands
the green batch (rebasing across them) behind one approval. See the
[workflow plugin README](plugins/workflow/README.md) for the autonomy-level
model and first-run launch-permission setup.

## Install

### Host (Mac / bare Linux)

```bash
claude plugin marketplace add joshjhall/librarian
claude plugin install dev-core@librarian
claude plugin install review-audit@librarian
claude plugin install workflow@librarian
```

`plugin update` rolls each plugin forward by semver.

### Container (pinned / offline)

The `containers` image clones this repo at a pinned tag/SHA and registers it as
a local on-disk marketplace, then installs offline. The pin is the version
contract that keeps headless container builds reproducible. See
[joshjhall/containers#608](https://github.com/joshjhall/containers/issues/608).

## License

Dual-licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
  <https://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or
  <https://opensource.org/licenses/MIT>)

at your option — the standard dual-license used across the ecosystem, matching
[containers](https://github.com/joshjhall/containers) and
[octarine](https://github.com/joshjhall/octarine).

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual-licensed as above, without any additional terms or conditions.
