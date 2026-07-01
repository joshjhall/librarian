# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-07-01

### Added

- Retrofit codebase-audit onto the Workflow tool (#77)

### Changed

- Split oversized SKILL.md files into companion docs (#104)
- Split oversized SKILL.md files into companion docs (#106)
- Document single-file constraint and guard template drift (#109)
- Split orchestrate harness modes into entry-point functions (#114)
- Gate codebase-audit patterns.sh execution by source (#122)
- Gate project check-* SKILL.md content loading (#127)

### Documentation

- Add CI build-status badge to README (#76)
- Add session team memories to .claude/memory (#79)
- Fix golem-gate-watch.sh path in orchestrate skill (#108)
- Fix stale nested-layout refs in agent-author Orchestrator Detection (#111)
- Correct agent count to 3 and drop misattributed issue-writer (#116)
- Replace version-pinned README highlights with CHANGELOG pointer (#118)
- Retitle CLAUDE.md H1 to a neutral developer-guide heading (#119)
- Note namespaced agentType convention; refresh #126 memory

### Fixed

- Verify git-cliff binary checksum before sudo install (#112)
- Pin cargo install git-cliff to GIT_CLIFF_VERSION with --locked (#113)
- Namespace Workflow agentType refs to <plugin>:<name> (#128)

### Miscellaneous

- Align audit-ai-config model to sonnet (#115)

### Testing

- Cover the release toolchain with validate-release.sh (#101)
- Self-test the harness; add assert_not_contains (#102)
- Enforce BUDGET_FLOOR consistency across workflow harnesses (#103)
- Cover inline-flow and multi-value block-list subagent_type forms (#105)
- Cover seed-worktree-trust.sh path validation (#110)
- Cover untested golem/worktree helper scripts (#82) (#117)
- Cover pre-review-gates scan categories and skip policy (#83) (#120)
- Add unit tests for workflow.js pure helpers (#121)

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

### Fixed

- Guard null .ts in golem-gate-watch feed filter (#39)

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

[0.3.0]: https://github.com/joshjhall/librarian/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/joshjhall/librarian/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joshjhall/librarian/compare/568c46603b0561440d3b1a151780f71d5e4c3e7b...v0.1.0
