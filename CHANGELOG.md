# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2026-07-15

### Added

- Route codebase-audit output by artifact type (#223) [**BREAKING**]
- Add 3 check-ai-config detector categories (#255)

### Changed

- Hard-remove deprecated autonomy flags, --level is the sole dial (#226) [**BREAKING**]
- Extract oversized SKILL.md sections into companions (#234)

### Documentation

- Fix stale skill cross-reference in check-docs-staleness (#231)
- Document generate_changelog() contract in release.sh (#232)
- Drop nonexistent check-patterns-coverage.sh reference (#239)

### Fixed

- Make ship-issue auto-merge worktree-aware (#235)
- Hard-abort release when changelog generation fails (#236)
- Fail loud on golem-launch plugin version skew (#237)
- Resolve worktree-new.sh tools via PATH, not /usr/bin (#241)
- Distinguish idle/errored golems from working ones in liveness (#245)
- Reap pane pipeline on golem-watch exit + cover git-cliff/golem-notify/golem-watch (#249)
- Only mark a PR rebased:true on a complete rebase (#274)
- Disqualify budget-truncated review cycles from clean:true (#275)
- Inject ANTHROPIC_AUTH_TOKEN into golem dispatch (#244) (#277)
- Resolve seed-worktree-trust root via cwd-independent repo_root (#276)
- Harden review harnesses against prompt injection (#287)
- Retry ci-fixer on transient agent failure, preserve applied fixes (#286)
- Stop routing the diff through the manifest StructuredOutput round-trip (#285)
- Budget-gate terminal agent awaits so a ceiling cannot throw the run away (#288)

### Miscellaneous

- Bump containers submodule to v4.19.12 (#213)

## [0.5.0] - 2026-07-03

### Added

- Install Python 3.12 for the patterns.sh port (#17) (#154)
- Wire codegraph MCP + track .codegraph cache symlink
- Queue dependencies first for an explicitly-named blocked issue (#160)
- Python-primary check-security pre-scan + bash-3.2 portability (#169)
- Port check-docs-missing-api pre-scan to Python 3.11+ (#170)
- Port check-code-health pre-scan to Python 3.11+ (#172)
- Port high-tier pre-scan tools to Python 3.11+ (phase 2) (#173)
- Port moderate-tier pre-scan tools to Python 3.11+ (phase 2) (#182)
- Port simple-tier pre-scan tools to Python 3.11+ (phase 2)
- Autonomy-level contract & gate taxonomy (L1–L4) (#188)
- Next-issue autonomy_level (1–4) replaces binary autonomous (#191)
- Scope sudo to a command allowlist (drop NOPASSWD:ALL) (#192)
- Mid-flight escalation gate for architectural/directional decisions (#194)
- Ship-issue merge-on-green+clean-review as level-aware routine gate (#195)
- Add Codecov coverage reporting + expand README badges (#196)
- Structured dead-end summary for unresolvable gates (#197)
- Orchestrate tracks composition mode (#178 Part A) (#201)
- Orchestrate setup flow + lone /next-issue L1–L4 prompt (#202)
- Orchestrate lane-aware serial refill (#199 Part C) (#203)
- Extract autonomy-level gate disposition into a resolver script (#207)

### CI/CD

- Add Python (ruff) + shellcheck lint gates across the board (#185)

### Changed

- Retier agents/skills for the 5-gen models (#156)
- Cap critical at L3, remove force-auto-critical overrides (#200)
- Remove deprecated AUTOMERGE auto-merge fast path (#211)

### Documentation

- Document passwordless-sudo + SYS_ADMIN threat model (#158)
- Document tmux launch permission setup for first dispatch (#165)
- Reconcile autonomy language to L1–L4 + bake in never-time-out rule (#210)
- Add session team memories for autonomy/ship-issue work

### Fixed

- Correct 3 latent check-security scanner regex bugs (#171)
- Correct 5 latent pre-scan scanner bugs found during the port (#184)
- Namespace golem launch commands to /workflow:next-issue (#163)
- Make bash/python pre-scans byte-equivalent + add differential gate (#187)
- Guard check-ai-config get_frontmatter against pipefail abort (#208)

### Miscellaneous

- Bump containers to v4.19.10; disable /run tmpfs

### Testing

- Add source-level category-slug parity gate (patterns.sh ↔ patterns.py) (#193)
- Behavioral coverage gate for check-ai-config detectors (#206)

## [0.4.0] - 2026-07-02

### Added

- Sign releases (cosign keyless) + extend empty-handler test coverage (#142)

### Changed

- Rename next-issue-ship skill to ship-issue (#129)
- Dedupe debug-statement scanner via drift guard (#131)
- Unify test-file classification across scanners (#138)
- Gate project audit-* dispatch + mirror gate into checker.md (#151)

### Documentation

- Add typos-gate-blocks-push memory note

### Fixed

- Harden release pipeline (PR #142 follow-ups) (#147)
- SwiftPM/Swift Testing detection + release Group D coverage + release.yml tempfile cleanup (#150)
- Sign releases with cosign 3.x bundle format (--bundle) (#153)

### Testing

- Add positive fixtures for tech-debt-marker and empty-handler (#140)

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

[0.6.0]: https://github.com/joshjhall/librarian/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/joshjhall/librarian/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/joshjhall/librarian/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/joshjhall/librarian/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/joshjhall/librarian/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joshjhall/librarian/compare/568c46603b0561440d3b1a151780f71d5e4c3e7b...v0.1.0
