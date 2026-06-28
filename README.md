# Librarian

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-blue.svg)](#license)

A [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins)
of general-purpose skills and agents — usable on a host Mac, a bare Linux box,
and inside the [containers](https://github.com/joshjhall/containers) dev image
alike.

These artifacts used to live inside the `containers` repo and were baked into
every image. They were extracted here so they install the same way everywhere
via Claude Code's native plugin system — with `plugin update` semver rolling
updates for free — instead of being container-build-bound.

> **Status:** scaffolding. The marketplace structure and plugin manifests are
> being stood up; the skills/agents are migrated in
> [joshjhall/containers#607](https://github.com/joshjhall/containers/issues/607).

## Plugins

| Plugin | What's inside |
|---|---|
| **dev-core** | General development + authoring: code review, debugging, refactoring, testing, git/error/doc workflow skills, and the skill/agent/workflow authoring guides. |
| **review-audit** | The `codebase-audit` / `check-*` / `audit-*` suite plus the issue writer. |
| **workflow** | Issue-driven and parallel automation: `next-issue`, `orchestrate`, golem, `file-issue`, `provision-agent`, and the bundled shell scripts they call. |

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
