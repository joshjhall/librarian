# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-06-29

### Added

- Pin GitHub Actions to commit SHAs (#46)
- Threshold checkpoints + env-var overrides for long-running ship actions (#62)
- Harden release.yml release-create against expression injection (#61)

### CI/CD

- Restrict fork-PR untrusted script execution in quality-gates (#51)
- Tighten release.yml tag trigger to semver (#54)
- Add per-job timeout-minutes to ci.yml and release.yml (#55)
- Keep pinned-action SHAs and version comments in sync (#57)
- Sandbox fork-PR manifest gate; add action-pin lint and merge-gate (#63)
- Bump the actions group across 1 directory with 2 updates (#60)
- Bump CI and release workflows to Node 24 (#74)

### Changed

- Rename --auto autonomy flag to --autonomous (deprecated alias) (#72)

### Documentation

- Drop removed needs_regen field from rebase-agent doc table (#71)
- Add "What's new in 0.2.0" section to README

### Fixed

- Guard null .ts in golem-gate-watch feed filter (#39)
- Force full-repo git-cliff scope in release.sh

### Miscellaneous

- Allow-list intentional regex stems in typos + add team memory (#37)
- Pin Node 24 for the next devcontainer build (#73)

### Testing

- Add test-framework architecture doc + wire run-all.sh into CI/lefthook (#44)
- Harden gate suite — phase↔meta, agentType, required_tools, and pre-scan robustness (#65)

## [0.1.0] - 2026-06-28

### Added

- Scaffold marketplace + dev-core/review-audit/workflow manifests + CI (#7)
- Migrate general dev + authoring skills/agents (#10)
- Migrate audit/check suite + issue-writer (#11)
- Migrate golem/issue flow + de-just bundled scripts (#13)
- Add semver release flow (VERSION + vX.Y.Z tag + CHANGELOG) (#35)

### Documentation

- Document flat agents/<name>.md layout requirement (#15)

### Fixed

- Flatten plugin agents to agents/<name>.md for discovery (#14)
- Register golem-notify Notification hook + de-scaffold docs (#30)
- Register golem-notify Notification hook + de-scaffold docs (#34)

### Miscellaneous

- Seed repository (README, dual license, gitignore)
- Bootstrap dev environment (#9)

### Testing

- Relocate skill/agent quality gates + fixtures (#12)

[0.2.0]: https://github.com/joshjhall/librarian/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joshjhall/librarian/compare/568c46603b0561440d3b1a151780f71d5e4c3e7b...v0.1.0
