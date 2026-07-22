# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] - 2026-07-22

### Added

- Make next-issue /clear resume worktree-aware (#430)
- Agnix→TSV normalizer for check-ai-config (#433)
- Consume Mode-3 container token usage in golem-status (#440)
- PreToolUse guard blocks destructive subagent shell (#448) (#450)
- Add generic check-lifecycle scanner (#456)
- Push turn-ended/idle-at-prompt stall on pane gate-watch (#447) (#455)
- Multi-sink golem event emitter (GOLEM_EVENT_SINKS) (#468)
- Wire agnix as optional checker pre-scan source (#469)
- Headless-golem idle/error detection via session transcript (#473)
- Orchestrator-push receiver for golem gate events (#407) (#476)
- Build-order-aware orchestrate/tracks lane composition (#483)
- Add GOLEM_MODEL launch knob for golem dispatch (#487) (#496)

### CI/CD

- Bump actions/setup-node in the actions group (#434)
- Add agnix SARIF code-scanning gate (#460)

### Changed

- Rename pool.json `accepting` field to `queue` (#421)
- Resolve golem-notify feed path via GOLEM_STATUS_DIR (#423)
- Agnix precedence dedup matches per issue not per line (#402) (#477)
- Suppress no-op golem-status checkpoint sweeps (#488) (#499)

### Documentation

- Record v0.7.0 release + confirmed PR-then-tag recipe
- Foreground user-directed skills + fix component counts (#437)
- Record 2026-07-19/20 orchestrate session memory learnings
- Record #426 belt+origin-lock ship (PR #449)
- Record #448 PreToolUse bash-guard ship, #426 fully closed
- Verify /golem AC#3 + AC#5 in-session, move live ACs to #451 (#453)
- Cross-link agnix pin to containers#769 companion issue (#463)
- Record session memory learnings (#487 GOLEM_MODEL + backlog)
- Wrap memory prose to satisfy rumdl MD013 (no --no-verify)
- Record no---no-verify directive; fix the lint instead
- Record #488 checkpoint-suppression + grep -c zero-count learnings

### Fixed

- Defer plan mode to Phase 2 so next-issue persists its state file (#425)
- Clear send-keys-resolved plan gates from the BLOCKED list (#431)
- Stub tmux in _run_liveness_snapshot to stop host golem leak (#438)
- Ban destructive shell in read-only review agents (#426) (#449)
- Footer-anchor pane_is_plan_gate/pane_is_gate matchers (#457)
- Clear torn-down golem ghosts + surface API-error deaths in golem-status (#464)

### Miscellaneous

- Bump containers submodule to v4.19.17 (#418)
- Follow-up test coverage + Mode-3 started stamp for #283 (#427)
- Finalize .agnix.toml tools/disable-list/version pin (#461)
- Reset container golem status cache on issue reassignment (#466)

### Testing

- Guard golem-notify default drift + cover composed override (#439)
- Remove fragile group-signal case from validate-golem-watch (#445)
- Timestamped per-stage markers in run-all.sh (#442)
- Add GOLEM_PANE_FOOTER_LINES env-override test for pane matchers (#479)
- Add tail-window boundary cases for footer-anchored pane matchers (#480)
- Cover golem-resolve + _gate_age_suffix fail-safe arms (#482)

## [0.7.0] - 2026-07-19

### Added

- Instrument top-level token counter for the frozen-counter wedge signal (#393)
- Orchestrator-brokered gate resolution inbox (#227 slice 1) (#394)
- Surface brokered-inbox state in golem-status.sh (#395) (#396)
- /golem solo local golem skill + all-mode pre-PR review parity (#410)
- Per-track status+burn checkpoint table in golem-status.sh (#414)

### Changed

- Extract Phase M into monitor-protocol.md companion (#379)
- Keep workflow.js harness prompt prefixes cache-stable (#256) (#404)

### Documentation

- Add Mode 3 container-golem branch to slow-review takeover recipe (#385)
- ADR for agnix + check-ai-config boundary (#403)
- ADR 0001 for golem event bus decision (#343 slice 1) (#408)
- Add session team memories from recent orchestrate work
- Record #283 checkpoint-table session learnings

### Testing

- Readiness-poll golem-watch signal test settle windows (#380)
- Cover fail-loud abort on readonly-tainted GIT_DIR in worktree-new/-rm (#382)
- Drive 3 review-audit ports to 100% + fix missing-api bug (#383)
- Drive 6 dev-core loop-*/drift patterns.py ports to 100% (#389)
- Behavioral + mutation coverage for remaining #355 git-env scrub vars (#386)
- Cover golem-watch readiness-poll starvation path (#388)
- Decouple invalid-bool scrub tests from git's fatal wording (#391)
- Cover golem-status token-signal render paths (#371 follow-up) (#413)

## [0.6.2] - 2026-07-17

### Added

- Auto-run a level-scaled orchestrator status sweep (#315)
- Add check-patterns-coverage.sh deterministic-coverage tool (#340)

### Changed

- Factor shared highestBy reducer (#344)
- Replace degenerate single-item pipeline() with plain awaits (#347)
- Validate feed JSON without eval-embedding untrusted line (#351)
- Single source of truth for the git-env scrub var list (#367)

### Documentation

- Add session team memories from backlog-burndown + 0.6.x releases
- Clarify orchestrate plan-gate broker-then-send flow (#302)

### Fixed

- Repair polluted main-repo core.worktree in worktree-rm.sh (#303)
- Bound Workflow invocations in wall-time at the caller (#307)
- Thread autonomy level through golem-launch.sh (#309)
- Validate id/related_ids in code-reviewer merge output (#313)
- Floor merged-finding severity at highest constituent ref (#316)
- Settle the stale #29 'not agent-drivable' plan-gate hedge (#318)
- Catch AskUserQuestion escalation forks in gate-watch pane channel (#320)
- Surface MAX_REBASES-capped rebase remainder in orchestrate (#326)
- Document classifier as a separate gate from the allow-list (#282) (#322)
- Scrub git-hook env vars in repo_root() to protect the trust guard (#329)
- Clamp planRefill lane pass to freeSlots (#331)
- Filter orphan golem-? sentinel from feed_snapshot BLOCKED set (#333)
- Bound codebase-audit + orchestrate Workflow callers in wall-time (#334)
- Resolve superproject root in repo_root() inside a submodule (#335)
- Mechanize ship-issue review wall-time stop decision (#339)
- Document golem-notify feed can't classify in-turn forks (#342)
- Init submodules in worktree-new so consuming-repo hooks pass (#346)
- Scrub git-hook env process-wide in worktree-new/-rm (#354)
- Recalibrate orchestrator review-wedge takeover heuristic (#369)
- Extend git-env scrub to GIT_CONFIG_* / GIT_CEILING_DIRECTORIES (#375)

### Miscellaneous

- Bump containers submodule to v4.19.14

### Testing

- Drive liveness_snapshot() tmux-pane wiring end-to-end (#305)
- Cover stamp-versions.mjs error paths (#308)
- Cover golem-notify golem-id derivation fallback (#310)
- Pin golem-notify second idle classifier arm (#314)
- Cover ensure_git_cliff install orchestration (#319)
- Cover golem-notify cwd-independence from a subdirectory (#330)
- Assert new_named_sandbox setup succeeds in validate-golem-notify.sh (#332)
- Drive check-docs-* patterns.py ports to 100% line-rate (#349)
- Cover highestBy malformed-input edge case (#350)
- Harden check-patterns-coverage.sh coverage (#353)
- Cover repo_root() super_root relative-path absolutize (#357)
- Cover super_root probe GIT_DIR scrub inside a submodule (#362)
- Assert golem-watch trap arms INT/TERM, not just EXIT (#358)
- Cover worktree-new-from-submodule placement end-to-end (#338) (#364)
- Close the 2×2 taint matrix — readonly GIT_DIR × super_root arm (#366)
- Cover worktree-new submodule placement under a tainted git env (#365) (#373)
- Add assert_valid_json self-test to validate-harness.sh (#374)
- Add setsid-free behavioural INT signal-path test for golem-watch (#377)

## [0.6.1] - 2026-07-15

### Fixed

- Normalize PR comment id comparison in ship-issue triage (#290)
- Anchor pane_liveness_class to the pane footer region (#291)
- Train mode fails closed on an unresolvable PR file list (#292)
- Surface budget-skipped/scan-failed domains in audit report (#294)
- Harden safeRef against traversal, absolute, and leading-dash values (#296)
- Resolve config.sh repo_root() tools via PATH, not /usr/bin (#295)
- Make code-review merge step ref-based to stop finding drift (#297)

### Miscellaneous

- Pin the rebase-agent's worktree context in poll+rebase (#293)

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

[0.8.0]: https://github.com/joshjhall/librarian/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/joshjhall/librarian/compare/v0.6.2...v0.7.0
[0.6.2]: https://github.com/joshjhall/librarian/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/joshjhall/librarian/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/joshjhall/librarian/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/joshjhall/librarian/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/joshjhall/librarian/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/joshjhall/librarian/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/joshjhall/librarian/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joshjhall/librarian/compare/568c46603b0561440d3b1a151780f71d5e4c3e7b...v0.1.0
