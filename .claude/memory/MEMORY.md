# Memory index

<!-- One line per memory (title + one-line hook), intentionally long. -->
<!-- rumdl-disable MD013 -->

- [Orchestrate session handoff](orchestrate-session-handoff.md) — Batches 1–4 all shipped; 0.6.0 + 0.6.1 released; next action = update /opt/librarian install to 0.6.1 (needs sudo) to retire the auth-token stopgap + review-cycle bug
- [Verify squash-merge landed](verify-squash-merge-landed.md) — after merging a PR, confirm the diff actually landed on origin/main, not just the title
- [Auto-mode blocks self-merge](auto-mode-blocks-self-merge.md) — L3/L4 ship `gh pr merge` is denied by the auto-mode classifier (self-authored, no human approval); park for human merge
- [Stale-base squash reverts merged PR](stale-base-squash-reverts-merged-pr.md) — `reset --soft origin/main` from a worktree branched before a mid-session merge silently reverts that PR's files; restore each advanced file before amending
- [Ship worktree merge cleanup](ship-worktree-merge-cleanup.md) — `gh pr merge --delete-branch` from a worktree fails local checkout ('main' used elsewhere) but the remote merge lands; verify + finish cleanup manually, don't treat as dead-end
- [Orchestrate broker-then-send](orchestrate-broker-then-send.md) — at a plan gate, orchestrator SENDS the tmux keystroke after the human approves; never hand it back to the operator (issues #280/#281/#282)
- [Release process](release-process.md) — how to cut a repo-level vX.Y.Z release; what containers#608's LIBRARIAN_REF pins to
- [Flaky golem-gate-watch test](flaky-golem-gate-watch-test.md) — root-caused to GIT_DIR leak from push hook; fixed in PR #62
- [golem-gate-watch host leak](golem-gate-watch-host-leak.md) — liveness test fails locally when real host golem sessions leak into its sweep ("advancing"); pre-existing, env-only, push --no-verify, CI passes
- [Conform scope enum](conform-scope-enum.md) — fix(review): is rejected; use fix(workflow): etc. — the skill's generic scope ≠ this repo's enum
- [Skill required_tools vocabulary](skill-required-tools-vocabulary.md) — metadata.yml required_tools are shell-command names; no SKILL.md has a frontmatter tools: field
- [Devcontainer bash_env PATH reset](devcontainer-bash-env-path-reset.md) — /etc/bash_env resets $PATH on non-interactive bash; unset BASH_ENV for PATH-stub tests
- [Autonomy vs plan-gate flags](autonomy-vs-plangate-flags.md) — --autonomous (autonomy) vs --skip-plan/--force-auto (plan-gate) are orthogonal; 3 unrelated --auto spellings never to rename
- [Release from worktree (git-cliff)](release-from-worktree-gitcliff.md) — git-cliff scopes to cwd; release.sh needs --include-path or it silently wipes CHANGELOG from a worktree
- [Two-runtime model](two-runtime-model.md) — workflow.js engine is sandboxed (no shell/fs); only Bash-tool subagents reach host tools; Claude Code bundles no general-purpose runtime
- [core.bare misconfig](core-bare-misconfig.md) — "must be run in a work tree" error = stray core.bare=true in .git/config; set it false (also masks real git status)
- [workflow.js no module system](workflow-js-no-module-system.md) — harnesses can't be split into importable schemas.js/prompt-utils.js (no import/require/fs); audit keeps re-filing impossible "god module" extractions (issues #90, #91); remedy = entry-point functions + header banner (PR #114 worked precedent)
- [git-cliff checksum is sha512](git-cliff-checksum-sha512.md) — git-cliff releases ship per-asset .tar.gz.sha512 (not .sha256) + .sig; verify against the published sibling
- [worktree-new seeds ~/.claude.json](worktree-new-seeds-home-claude-json.md) — worktree-new.sh transitively writes $HOME/.claude.json via seed-worktree-trust.sh; sandbox tests must override HOME
- [pre-review-gates project root](pre-review-gates-project-root.md) — pre-review-gates.sh resolves _PROJECT_ROOT via git rev-parse; testing its scan categories needs a GIT_*-scrubbed git sandbox + .py/.js fixtures
- [Test workflow.js pure helpers](test-workflow-js-pure-helpers.md) — slice harness source before first orchestration stmt + eval prefix in new Function (can't import a top-level-await module); tests/validate-workflow-helpers.mjs, PR #121
- [Codebase-audit prescan location](codebase-audit-prescan-location.md) — Step 2.5 patterns.sh prose lives in orchestration-protocol.md (post-#106), checker.md owns execution; #107 added the source-aware integrity gate; beware stale local main
- [Workflow agentType namespacing](workflow-agenttype-namespacing.md) — Workflow tool agent() wants namespaced <plugin>:<name>, Agent tool wants bare — opposite; FIXED #126/PR #128 (harnesses namespaced + lint-skills-agents.sh gate enforces it); fallback = Agent tool with bare name
- [ship-issue rename rationale](ship-issue-rename-rationale.md) — the ship skill is ship-issue (not next-issue-ship) on purpose; moved out of next-issue* prefix to fix a `nex` autocomplete collision; don't rename it back
- [typos gate blocks push](typos-gate-blocks-push.md) — the `typos` pre-push hook fails the whole push on any misspelling in touched files, including pre-existing ones adjacent to your edits
- [cosign bundle format](cosign-bundle-format.md) — release.yml signing must use --bundle (.sigstore.json); cosign 3.x ignores --output-signature/-certificate; v0.4.0 was first release to run cosign, publish job broke (PR #153)
- [mjs coverage c8 excludes tests](mjs-coverage-c8-excludes-tests.md) — c8 excludes tests/ by default so covering tests/*.mjs needs --exclude override; NODE_V8_COVERAGE + c8 report merges multiple entry points (#186)
- [pre-review-gates needs filelist](pre-review-gates-needs-filelist.md) — pre-review-gates.sh takes changed files as positional args; bare call errors with Usage
- [coverage two surfaces](coverage-two-surfaces.md) — patterns.py Codecov number comes from coverage-python.sh's own corpus, not the behavioral test gates; extend both to lift coverage + assert behavior (#204)
- [autonomy-resolver script](autonomy-resolver-script.md) — autonomy-resolve.{py,sh} is the single source of truth for the L1-L4 gate-disposition table (#190); skills call it, don't re-derive; killed the effort-vs-level drift
- [check-ai-config bloat scan](check-ai-config-bloat-scan.md) — how to run the ai-file-bloat scanner locally (path-list arg); raw-line thresholds per file type (SKILL.md 300/500)
- [Deprecated autonomy flags removed](deprecated-autonomy-flags-removed.md) — #215 killed --autonomous/--auto/--plan-gate/--force-auto/env; --level N is the sole dial; resolver still EMITS plan_gated/perm_mode (runtime), only state-file mirrors dropped
- [rumdl nested sublist under numbered](rumdl-nested-sublist-under-numbered.md) — rumdl MD077 autofix dedents a nested dash-sublist out of its numbered/lettered parent bullet; use flat bold-prose sub-cases instead (hit editing ship-issue execute-protocol.md, #225)
- [golem-launch version-skew guard](golem-launch-version-skew-guard.md) — golem-launch.sh refuses dispatch on plugin version skew (#230/PR #237); "unknown" registry sentinel + unset $HOME must skip, not fire
- [/usr/bin hardcoding in golem scripts](usr-bin-hardcoding-golem-scripts.md) — golem scripts hardcode /usr/bin/<tool> (exit 127 off-/usr/bin); fix = `command <tool>`; #228/PR #241 fixed only worktree-new.sh, siblings + config.sh:repo_root still affected
