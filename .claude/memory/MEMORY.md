# Memory index

<!-- One line per memory (title + one-line hook). Detail lives in the topic file. -->
<!-- rumdl-disable MD013 MD033 -->

## Operator directives

- [No --no-verify: fix the lint](no-noverify-fix-the-lint.md) — never skip rumdl/typos; don't `rumdl fmt` blind (mangles #NNN→heading); only this index is exempt
- [Librarian runs outside containers](librarian-runs-outside-containers.md) — installs Mac/bare-linux/container alike; never hard-depend on the containers submodule
- [L3 broker plan-gate (standard)](l3-broker-plan-gate.md) — orchestrator presents each plan in-session, human decides HERE; never route to a TTY
- [Orchestrate broker-then-send](orchestrate-broker-then-send.md) — orchestrator SENDS the keystroke after approval; never hand back to operator (#280)
- [Umbrella issue Closes vs Contributes](umbrella-issue-closes-vs-contributes.md) — one slice → "Contributes to #N" + follow-up, never "Closes #N" (#243)
- [Closes trailer in squash commit](closes-trailer-in-squash-commit.md) — squash-COMMIT body Closes trailer auto-closes even if PR body says Contributes; fix BOTH (#411)

## Runtime & tooling gotchas

- [Two-runtime model](two-runtime-model.md) — workflow.js engine is sandboxed (no shell/fs); only Bash-tool subagents reach host tools
- [workflow.js no clock](workflow-js-no-clock.md) — no Date.now/timers; bound at the CALLER (background→poll→TaskStop); #224
- [workflow.js no module system](workflow-js-no-module-system.md) — no import/require/fs; remedy = entry-point fns + header banner (#90)
- [Workflow agentType namespacing](workflow-agenttype-namespacing.md) — Workflow agent() wants `<plugin>:<name>`, Agent tool wants bare — opposite; fixed #126
- [Test workflow.js pure helpers](test-workflow-js-pure-helpers.md) — slice source before first orchestration stmt + eval in new Function; validate-workflow-helpers.mjs
- [Collect-all assertions must not throw](collect-all-test-assertions-must-not-throw.md) — bare `.field` on a missing entry aborts the run + masks later assertions; use `?.`
- [grep -c exits 1 on zero count](grep-c-zero-count-exit-1.md) — prints 0 but EXITS 1; `|| echo 0` double-appends; use `grep -o P | wc -l`
- [jq empty vs jq -e for JSON validity](jq-validate-empty-vs-e.md) — validity = `jq empty`; `jq -e .` misreports valid scalars false/null as invalid (#253)
- [core.bare misconfig](core-bare-misconfig.md) — "must be run in a work tree" = stray core.bare=true; set false (also masks real git status)
- [Devcontainer bash_env PATH reset](devcontainer-bash-env-path-reset.md) — /etc/bash_env resets $PATH non-interactively; unset BASH_ENV for PATH-stub tests
- [typos gate blocks push](typos-gate-blocks-push.md) — fails the whole push on any misspelling in touched files, incl pre-existing adjacent ones
- [rumdl nested sublist under numbered](rumdl-nested-sublist-under-numbered.md) — MD077 autofix dedents nested sublists out of numbered parents; use flat bold prose (#225)
- [Conform scope enum](conform-scope-enum.md) — `fix(review):` is rejected; the skill's generic scopes ≠ this repo's enum
- [Skill required_tools vocabulary](skill-required-tools-vocabulary.md) — metadata.yml required_tools are shell-command names; no SKILL.md has a frontmatter tools: field

## Git & release

- [Release process](release-process.md) — how to cut a repo-level vX.Y.Z release; what containers#608's LIBRARIAN_REF pins to
- [Release from worktree (git-cliff)](release-from-worktree-gitcliff.md) — git-cliff scopes to cwd; release.sh needs --include-path or it wipes CHANGELOG
- [cosign bundle format](cosign-bundle-format.md) — release.yml must use --bundle (.sigstore.json); cosign 3.x ignores --output-signature (#153)
- [git-cliff checksum is sha512](git-cliff-checksum-sha512.md) — per-asset .tar.gz.sha512 (not .sha256) + .sig; verify against published sibling
- [Verify squash-merge landed](verify-squash-merge-landed.md) — confirm the diff landed on origin/main, not just the title
- [Stale-base squash reverts merged PR](stale-base-squash-reverts-merged-pr.md) — `reset --soft origin/main` from a pre-merge worktree silently reverts that PR's files
- [Git index corruption → partial commit](git-index-corruption-partial-commit.md) — truncated .git/index committed 1 of ~384 files with NO error; verify `gh pr view --json files`
- [Edits landed in main not worktree](edits-landed-in-main-not-worktree.md) — main-checkout abs paths from a worktree land edits in MAIN; target .worktrees/issue-N/
- [Auto-mode blocks self-merge](auto-mode-blocks-self-merge.md) — L3/L4 `gh pr merge` denied (self-authored); park for human merge; classifier is non-deterministic
- [Marketplace source = reaped worktree](marketplace-source-reaped-worktree.md) — marketplace against a golem worktree → reap → plugins DOA; add /workspace/librarian

## Review harness & cost

- [Classify tool calls before optimizing](classify-tool-calls-before-optimizing.md) — aggregate tokens say WHICH agent; only the call log says WHY; my predicted hot spot was <10% of burn twice in one session
- [Review cost BASELINE 2026-07-28](review-cost-baseline-2026-07-28.md) — frozen pre-change per-cycle/per-dimension numbers (deduped); compare "after" against THIS, not the raw figures in PR #554
- [Review cost AFTER 2026-07-28](review-cost-after-2026-07-28.md) — #559: per-cycle output 173k/281k/207k → 34k/9k (#557 did it), recall UNPROVEN at n=2; arm the runs by UTC, not local mtime
- [blocking==[] is not "nothing to fix"](blocking-empty-is-not-nothing-to-fix.md) — the DEFERRABLE bucket held a real defect twice running (#544, #549); a fix commit invalidates the cycle before it
- [#553 review token ceiling](issue-553-review-token-ceiling.md) — PR #554: budget gates are DEAD CODE without a runtime turn directive; ceiling shipped OFF (a too-low one dead-ends the PR); no turn cap on agent()
- [Token-burn audit 2026-07-21](token-burn-audit-2026-07-21.md) — 4-axis burn audit → #487-#495; biggest lever = golems had no --model dial (#487)
- [#256 cache-stability pass](issue-256-cache-stability.md) — prompt-prefix cache stability; stableStringify, instructions-first/volatile-last; helpers module-scope
- [Review-wedge root cause](review-wedge-root-cause.md) — golems wedge in unbounded reviews; #307 wall-bound is PROSE not code; takeover recipe (#327)
- [Wall-timeout decision helper](wall-timeout-decision-helper.md) — TaskStop is model-only; mechanized decision via workflow-wall-timeout.sh (#327)
- [ship review diff must be faithful](ship-review-diff-must-be-faithful.md) — the `diff` arg IS the bytes reviewers read (#267); capture `git diff origin/main...HEAD` verbatim
- [#426 harness rm -rf](issue-426-harness-rm-rf.md) — CRITICAL: review subagents could rm -rf the LIVE tree; belt+origin-lock PR #449 then bash-guard hook PR #450
- [#494 checklist relocation](issue-494-checklist-relocation.md) — checklists .md→workflow.js SUBREVIEWERS; issue premise was WRONG; bloat-glob missed FLAT agents
- [#491 fable-tail merge](issue-491-fable-tail-merge.md) — PR #514: rescore+classify → one fresh-judge fable pass; halves fable tail/cycle
- [#490 verify collapse](issue-490-verify-collapse.md) — PR #519: per-domain fable verify O(domains)→O(1); review caught missing tailAgent wrap
- [ship-issue rename rationale](ship-issue-rename-rationale.md) — named ship-issue on purpose (fixed `nex` autocomplete collision); don't rename back
- [#390 ship CI-hang dead-end](issue-390-ship-ci-hang-deadend.md) — PR #440 dead-ended at merge on run-all.sh CI hang; resume = rebase after #442

## Golem / orchestration

- [Gate-watch misses standing gates](gate-watch-misses-standing-gates.md) — fires only on transition INTO a gate; arm at dispatch + sweep when armed late; ONE-CLOCK-UTC (#515)
- [Idle-detector false positive (own monitors)](idle-detector-false-positive-own-monitors.md) — false-fires when a golem waits on its OWN monitors; footer "N monitors" = working (#517)
- [Frozen counter = done, not wedged](frozen-counter-is-done-not-wedged.md) — Δ=0 across sweeps usually = done-idle-at-prompt; check `gh pr list` + git log first
- [Dropped gate in notification flood](dropped-gate-in-notification-flood.md) — a checkpoint burst buried a plan-gate → ~8h idle; reconcile gh pr list + capture-pane
- [Stale-BLOCKED false positive](stale-blocked-false-positive.md) — send-keys-resolved gates pinned the full 3600s TTL; trust feed/pane-FOOTER over pane-grep (#422)
- [Phantom prompt-buffer text](phantom-prompt-buffer-text.md) — panes show unsent text at `❯`; verified inert; reap, don't blind-keystroke
- [Test BLOCKED list not feed echo](test-assert-blocked-list-not-feed-echo.md) — assert the render line `golem-N — msg`, not a bare substring of echoed feed JSON
- [Token-scrape transcript dedup](token-scrape-transcript-dedup.md) — MUST dedup by message.id (naive sum ~2.7× high); Mode 2 only (#371)
- [Broker-inbox gate resolution](broker-inbox-gate-resolution.md) — golem-inbox.sh relays escalation/dead-end down; DATA-ONLY, plan-approval excluded (#227)
- [golem-notify feed can't classify forks](golem-notify-feed-cant-classify-forks.md) — in-turn AskUserQuestion goes via canUseTool not Notification (#321)
- [golem-launch version-skew guard](golem-launch-version-skew-guard.md) — refuses dispatch on plugin version skew; "unknown" sentinel + unset $HOME must skip (#230)
- [Mode 3 takeover branch naming](mode3-takeover-branch-naming.md) — Mode 2 feature/issue-{N} tmux-kill vs Mode 3 agent{N} docker-compose; #370 mode-aware
- [repo_root submodule superproject](repo-root-submodule-superproject.md) — repo_root() put worktrees in .git/modules; probe --show-superproject-working-tree first (#324)
- [worktree-new seeds ~/.claude.json](worktree-new-seeds-home-claude-json.md) — transitively writes $HOME/.claude.json; sandbox tests must override HOME
- [worktree-new test coverage matrix](worktree-new-test-coverage-matrix.md) — submodule × taint matrix in validate-golem-scripts.sh; #365 closed the last cell
- [golem-watch trap signal testing](golem-watch-trap-signal-testing.md) — trap INT/TERM needs STRUCTURAL grep; #359 behavioural test; #360 readiness-poll
- [golem-gate-watch host leak](golem-gate-watch-host-leak.md) — liveness test fails locally when host golem sessions leak into its sweep; CI passes
- [CI hang: golem-watch group signal](ci-hang-golem-watch-group-signal.md) — 15min CI timeout = case-4 group-signal escapes on headless x86_64; FIX = remove case 4 (#444)
- [/usr/bin hardcoding in golem scripts](usr-bin-hardcoding-golem-scripts.md) — exit 127 off-/usr/bin; fix = `command <tool>`; #241 fixed only worktree-new.sh
- [#443 portable command paths](issue-443-portable-command-paths.md) — swept ~1,500 hardcoded /usr/bin paths → `command`+`_bin()` + CI lint; 5 must-NOT-sweep classes

### Golem worktree isolation (the #451/#501/#506 chain)

- [#475 worktree-scope guard](issue-475-worktree-guard.md) — PreToolUse guard DENIES a golem edit leaking into main (git-dir != common-dir)
- [#501 worktree-guard topology](issue-501-worktree-guard-topology.md) — the trust anchor must be NON-poisonable; 3 config-poison bypasses fixed via PATH-structure
- [#506 gitlink disarm](issue-506-gitlink-disarm.md) — a golem rewrites $WT/.git to forge a main-session gate; fix = structural walk-up, NOT --show-toplevel

### Golem status/liveness shipped work

- [#446 golem-status BLOCKED reliability](issue-446-golem-status-reliability.md) — PR #464 covers 2 of 4 modes (ghost filter, pane_is_api_error); #446 still open
- [#489 liveness dedup](issue-489-liveness-dedup.md) — PR #509: transition-dedup; review caught a set-u `$(( ))` crash on non-numeric interval
- [#488 checkpoint suppression](issue-488-checkpoint-suppression.md) — PR #499: no-op sweeps collapse to heartbeat; empty-state returns MUST clear cp_prev_sig
- [#487 GOLEM_MODEL launch knob](issue-487-golem-model-knob.md) — PR #496; REUSABLE BUG = raw $VAR in a tmux `sh -c` string → injection; fix = backslash-escape
- [#485 monitor event-driven default](issue-485-monitor-event-driven.md) — PR #504: sweep→event-driven push; the sweep was ALSO the Phase-P pool-refill clock
- [#248 transcript liveness](issue-248-transcript-liveness.md) — PR #473: reads last assistant stop_reason; `working` needs an mtime gate
- [#447 turn-end pane push](issue-447-turn-end-pane-push.md) — PR #455: two-poll debounce; confirm_turn_end in `$(...)` discards state
- [#452 footer-anchor pane matchers](issue-452-footer-anchor-matchers.md) — PR #457: matchers were whole-pane → false push; key off $pane_footer_lines
- [#459 tail-window boundary tests](issue-459-tail-window-boundary.md) — PR #480: +7-filler=8L incl / +8=9L excl (`<<<` off-by-one)
- [#458 footer-lines env test](issue-458-footer-lines-env-test.md) — PR #479: liveness_class returns a string; set env BEFORE sourcing
- [#432 gate-age coverage + jq-abort fix](issue-432-gate-age-coverage.md) — PR #482: one malformed .ts aborts feed_snapshot jq → blanks the WHOLE list; fix = try/catch
- [#392 token-signal coverage](issue-392-token-signal-coverage.md) — PR #413; review caught a HIGH tautology `grep -Evq` (use `! grep -q`)
- [#283 checkpoint table](issue-283-checkpoint-table.md) — PR #414; DURABLE FIX = run-all.sh unsets GIT_DIR at entry (push-hook-leak flake)
- [#411 /golem live-e2e verify](issue-411-golem-verify-scope.md) — PR #453 parked; in-worktree runs prove only AC#3+#5; live ACs need main-checkout → #451
- [#406 multi-sink emitter](issue-406-multi-sink-emitter.md) — PR #468: fans events to feed.jsonl + POST per GOLEM_EVENT_SINKS; SSRF non-goal → #407
- [#407 push receiver](issue-407-push-receiver.md) — PR #476: unvalidated client ts blanked the BLOCKED floor; sandbox KILLS socket binds (exit 144)
- [#462 tracks build-order composition](issue-462-tracks-build-order.md) — PR #483; BUG = display field read from RAW input, not ACTUAL state
- [#428 cache reset on reassignment](issue-428-cache-reassignment.md) — PR #466; reusable = whitelist-identity beats blacklist

## review-audit / scanners

- [#471/#472 agnix config trust](issue-471-472-agnix-config-trust.md) — PR #547: never read the audited repo's .agnix.toml; `--config` is GLOBAL, so that branch was dead since #398
- [#470 agnix dedup hardening](issue-470-agnix-dedup-hardening.md) — PR #546: severity→certainty sent EVERY row down the HIGH auto-include path; live TSV injection
- [#399 agnix SARIF CI gate](issue-399-agnix-sarif-ci.md) — PR #460: separate workflow, security-events:write; validate `jq -e .runs` before upload
- [#402 precedence dedup down-scope](issue-402-precedence-dedup.md) — PR #477: match PER UNDERLYING ISSUE, not line/category
- [#435 check-lifecycle scanner](issue-435-check-lifecycle.md) — PR #456: new check-lifecycle domain; MEDIUM-certainty pre-scan
- [Source-detector gate (#348 slice A)](source-detector-gate.md) — corpus drove 3 review-audit ports to 100%; fixed a missing-api private-detection bug
- [Loop-detector gate (#348 slice B)](loop-detector-gate.md) — #384: drove 6 dev-core loop-*/drift ports to 100% (#348 done)
- [check-docs-staleness IFS=: colon parity](check-docs-staleness-ifs-colon-parity.md) — FIXED #549; 7 patterns.py cloned the bug via a shim, so the parity gate was green on wrong output
- [check-ai-config bloat scan](check-ai-config-bloat-scan.md) — run the ai-file-bloat scanner locally (path-list arg); raw-line thresholds per file type
- [Codebase-audit prescan location](codebase-audit-prescan-location.md) — Step 2.5 prose in orchestration-protocol.md, checker.md owns execution (#107)
- [pre-review-gates needs filelist](pre-review-gates-needs-filelist.md) — takes changed files as positional args; a bare call errors with Usage
- [pre-review-gates project root](pre-review-gates-project-root.md) — resolves _PROJECT_ROOT via git rev-parse; scan-category tests need a GIT_*-scrubbed sandbox
- [coverage two surfaces](coverage-two-surfaces.md) — the patterns.py Codecov number comes from coverage-python.sh's corpus, not behavioral gates (#204)
- [mjs coverage c8 excludes tests](mjs-coverage-c8-excludes-tests.md) — covering tests/*.mjs needs an --exclude override; NODE_V8_COVERAGE merges (#186)
- [#503 large-file decompose](issue-503-large-file-decompose.md) — file-length is a Pass-2 LLM lens, not patterns.sh; workflow.js can't split (#90/#91)

## Pipeline / autonomy

- [autonomy-resolver script](autonomy-resolver-script.md) — autonomy-resolve.{py,sh} is the single source of truth for L1-L4 gate disposition (#190)
- [Deprecated autonomy flags removed](deprecated-autonomy-flags-removed.md) — #215 killed the old flags; `--level N` is the sole dial; resolver EMITS plan_gated/perm_mode
- [Autonomy vs plan-gate flags](autonomy-vs-plangate-flags.md) — autonomy vs plan-gate are orthogonal; 3 unrelated `--auto` spellings never to rename
- [Read issue comments not just body](next-issue-read-issue-comments.md) — `--json body` omits comments; follow-ups fold in requirements; fetch --comments in Phase 2
- [#400 cross-repo coordination](issue-400-cross-repo-coordination.md) — PR #463: real fix owned by containers#769; review caught Closes-vs-unmet-AC premature closure
