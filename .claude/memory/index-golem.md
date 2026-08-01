# Index: golem dispatch, orchestration & liveness

<!-- Sub-index of MEMORY.md. Not a memory — no frontmatter, one line per entry. -->
<!-- rumdl-disable MD013 MD033 -->

Operator directives that govern dispatch (plan-gate brokering, never timing out a
human gate) live in the root [MEMORY.md](MEMORY.md).

## Reading golem state — is it stuck or working?

- [Frozen counter = done, not wedged](frozen-counter-is-done-not-wedged.md) — Δ=0 usually = done-idle-at-prompt; check `gh pr list` first
- [Idle-detector false positive](idle-detector-false-positive-own-monitors.md) — false-fires when a golem waits on its OWN monitors (#517)
- [Stale-BLOCKED false positive](stale-blocked-false-positive.md) — trust the feed/pane FOOTER over a pane grep (#422)
- [Phantom prompt-buffer text](phantom-prompt-buffer-text.md) — panes show unsent text at `❯`; inert — reap, don't blind-keystroke
- [Review-wedge root cause](review-wedge-root-cause.md) — golems wedge in unbounded reviews; #307 wall-bound is PROSE not code
- [Wall-timeout decision helper](wall-timeout-decision-helper.md) — TaskStop is model-only; mechanize via workflow-wall-timeout.sh (#327)

## Gate watching & notifications

- [Gate-watch misses standing gates](gate-watch-misses-standing-gates.md) — fires only on transition INTO a gate; sweep when armed late (#515)
- [Dropped gate in notification flood](dropped-gate-in-notification-flood.md) — a checkpoint burst buried a plan-gate → ~8h idle
- [Footer-anchored pane matchers](footer-anchored-pane-matchers.md) — all 5 anchor on the footer tail; +7 filler incl / +8 excl
- [Feed can't classify forks](golem-notify-feed-cant-classify-forks.md) — in-turn AskUserQuestion goes via canUseTool, not Notification (#321)
- [Broker-inbox gate resolution](broker-inbox-gate-resolution.md) — relays escalation/dead-end down; DATA-ONLY, plan-approval excluded (#227)
- [Dedup cache clear on early return](dedup-cache-clear-on-early-return.md) — an uncleared signature suppresses a vanish→reappear (#488)
- [Test BLOCKED list not feed echo](test-assert-blocked-list-not-feed-echo.md) — assert the render line, not a substring of echoed JSON
- [#485 monitor event-driven](issue-485-monitor-event-driven.md) — sweep→push; the sweep was ALSO the pool-refill clock
- [#432 gate-age + jq-abort](issue-432-gate-age-coverage.md) — one malformed .ts blanks the WHOLE list; fix = try/catch

## Dispatch & scripts

- [golem-launch version-skew guard](golem-launch-version-skew-guard.md) — "unknown" sentinel + unset $HOME must skip the check (#230)
- [Mode 3 takeover branch naming](mode3-takeover-branch-naming.md) — Mode 2 tmux-kill vs Mode 3 docker-compose; #370 mode-aware
- [repo_root submodule superproject](repo-root-submodule-superproject.md) — probe --show-superproject-working-tree first (#324)
- [worktree-new seeds ~/.claude.json](worktree-new-seeds-home-claude-json.md) — writes $HOME/.claude.json; sandbox tests must override HOME
- [worktree-new coverage matrix](worktree-new-test-coverage-matrix.md) — submodule × taint matrix; #365 closed the last cell
- [/usr/bin hardcoding](usr-bin-hardcoding-golem-scripts.md) — exit 127 off-/usr/bin; fix = `command <tool>` (#241 fixed only one script)
- [#443 portable command paths](issue-443-portable-command-paths.md) — swept ~1,500 paths → `command`/`_bin()`; 5 must-NOT-sweep classes
- [golem-watch trap signal testing](golem-watch-trap-signal-testing.md) — trap INT/TERM needs a STRUCTURAL grep (#359/#360)
- [golem-gate-watch host leak](golem-gate-watch-host-leak.md) — fails locally when host golem sessions leak into the sweep; CI passes
- [CI hang: group signal](ci-hang-golem-watch-group-signal.md) — case-4 group-signal escapes on headless x86_64; FIX = remove case 4 (#444)

## Worktree isolation (the #451/#501/#506 chain)

- [#475 worktree-scope guard](issue-475-worktree-guard.md) — PreToolUse guard DENIES a golem edit leaking into main
- [#501 worktree-guard topology](issue-501-worktree-guard-topology.md) — the trust anchor must be NON-poisonable; 3 config-poison bypasses
- [#506 gitlink disarm](issue-506-gitlink-disarm.md) — a golem rewrites $WT/.git to forge a gate; fix = structural walk-up

## Status/liveness — shipped work (all issues CLOSED; reference only)

- [#446 BLOCKED reliability](issue-446-golem-status-reliability.md) — 2 of 4 modes covered; #446 still open
- [#248 transcript liveness](issue-248-transcript-liveness.md) — reads last assistant stop_reason; `working` needs an mtime gate
- [#447 turn-end pane push](issue-447-turn-end-pane-push.md) — two-poll debounce; state in `$(...)` is discarded
- [#283 checkpoint table](issue-283-checkpoint-table.md) — DURABLE FIX = run-all.sh unsets GIT_DIR at entry
- [#392 token-signal coverage](issue-392-token-signal-coverage.md) — review caught a HIGH tautology `grep -Evq` (use `! grep -q`)
- [Token-scrape transcript dedup](token-scrape-transcript-dedup.md) — dedup by message.id (naive sum ~2.7× high); Mode 2 only (#371)
- [#406 multi-sink emitter](issue-406-multi-sink-emitter.md) — fans to feed.jsonl + POST per GOLEM_EVENT_SINKS; SSRF → #407
- [#407 push receiver](issue-407-push-receiver.md) — unvalidated client ts blanked the floor; sandbox KILLS socket binds
- [#462 tracks build-order](issue-462-tracks-build-order.md) — BUG = display field read from RAW input, not ACTUAL state
- [#428 cache reset on reassignment](issue-428-cache-reassignment.md) — whitelist-identity beats blacklist
- [#515 ELAPSED mtime fallback](issue-515-elapsed-mtime-fallback.md) — anchor on the `.git` GITLINK, not the dir (mtime re-bumps)
- [#411 /golem live-e2e verify](issue-411-golem-verify-scope.md) — in-worktree runs prove only AC#3+#5; live ACs → #451
