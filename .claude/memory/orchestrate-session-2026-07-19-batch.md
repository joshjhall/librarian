---
name: orchestrate-session-2026-07-19-batch
description: "Live /orchestrate burndown 2026-07-19: 8 PRs landed (417/405/409/415/412/422/436/419); found+fixed 3 infra bugs (426 harness rm-rf HELD, marketplace-reaped-worktree, 436 liveness leak); #397 agnix CI-timeout OPEN; installed /opt now 0.7.0 so launcher has --level flag + auth stopgap retired"
metadata: 
  node_type: memory
  type: project
  originSessionId: de55e24b-986b-4be4-9eac-43fc9c6a1593
  modified: 2026-07-20T05:47:59.420Z
---

<!-- rumdl-disable MD013 -->

**Live `/orchestrate tracks` burndown, 2026-07-19 (v0.7.0 base).** 4 lanes L3,
worktree golems via `golem-launch.sh launch N --level 3` (installed /opt now
**0.7.0** == repo: launcher has the `--level` flag, auth-token `-e` stopgap +
0.5.0 review-cycle bugs all RETIRED). Operator standing auth: auto-merge
green+review-clean+scope-verified PRs; broker plan gates in-session; auto-approve
routine ship review-run gates; #426 HELD for interactive.

**LANDED (8 PRs):** #417→#421 (pool.json accepting→queue), #405→#423
(golem-notify GOLEM_STATUS_DIR), #409→#425 (next-issue Phase-2 plan-mode
deferral), #420 (closed by verify-golem — subsumed by #409, no PR), #415→#427
(#283 checkpoint tests + Mode-3 started stamp), #412→#430 (/golem L1-L2
worktree-aware resume), #422→#431 (stale-BLOCKED fix — my own filed bug),

# 436→#438 (liveness-leak fix), #419→#437 (docs refresh). Main at cc708a8

**3 INFRA BUGS found+handled this session:**

1. **#426 (CRITICAL, HELD interactive)** — read-only reviewers can `rm -rf` the
   live tree. See [[issue-426-harness-rm-rf]]. NOT dispatched.
2. **marketplace-source-reaped-worktree** — golem-424 came up DOA (Unknown
   command: /workflow:next-issue) because the librarian marketplace was
   registered against `.worktrees/issue-422` which I'd reaped. FIX =
   `claude plugin marketplace add /workspace/librarian`. See
   [[marketplace-source-reaped-worktree]].
3. **#436 liveness-leak (FIXED, PR #438)** — `_run_liveness_snapshot` never got
   the tmux stub its `_tmux` sibling has, so live host golems leaked into the
   sweep and failed the pre-push `quality-gates` hook during orchestration.
   Fixed the guard HONESTLY (no --no-verify — operator insisted): stub tmux +
   symlink bash/git/jq. Verified full suite green WITH 4 live golems. Retires the
   --no-verify remedy in [[golem-gate-watch-host-leak]].

**RESOLVED — #397 + #390 CI hang was validate-golem-watch case 4 (see
[[ci-hang-golem-watch-group-signal]]).** Fix = remove case 4 (#444/PR#445, merged
c033d19) + markers diagnostic (#441/PR#442, merged ba27d94). After #445 landed,
rebased #397+#390 onto main → BOTH went green ~2.5min → merged (#433→756b525,

## 440→5f983cd). 13 PRs total this session. Fleet fully wound down: no golems, no

worktrees, no open non-dependabot PRs. Historic investigation notes below.

**~~OPEN~~ (now resolved) — #397 (agnix→TSV normalizer, PR #433): CI TIMES OUT 15min, 3× confirmed,

## 397-tree-SPECIFIC.** Code runs fine LOCALLY (full suite 1m45s even agnix-absent

every #397 stage timed individually — agnix test 1.2s, lint-skills-agents 1s,
checker-detectors 1.5s, coverage isn't in this job). But GitHub `Skill/agent
quality gates` "Run test suite" hangs to the 15min job kill — ONLY on #397's
branch (main + #436/#419/#422/#424 all pass ~2.5min; operator's insight: "other
PRs pass, so it's a dep/missing-thing in CI specific to this branch"). GitHub
PURGES timed-out-job logs so the culprit stage is invisible post-hoc, and the
running-job log isn't exposed via CLI/API. #397's 8-file diff (3-dot authoritative
via `gh pr view --json files`): agnix-normalize.py/.sh, validate-agnix-normalize.sh,
coverage-python.sh, run-all.sh(+1 stage), SKILL/contract/metadata. NONE hang
locally. **DIAGNOSTIC IN FLIGHT:** PR #442 (branch fix/run-all-stage-timeout,
Closes #441) instruments run_stage with `[>>] <stage> :: entering at HH:MM:SS`
markers + per-stage `timeout` (default 300s, RUN_ALL_STAGE_TIMEOUT, -k10, skip-if-
absent) + `[ok] (Ns)` elapsed — so a hung stage NAMES ITSELF instead of a blind
15min kill. Plan: merge #442 → rebase #397 onto it → next #397 CI log's LAST
`[>>]` line = the culprit. #442's own CI is the CONTROL (instrumented run-all on
clean main — if it passes fast, instrumentation is sound + hang is #397-specific).

**TRACKS (tracks.json):** T0 [409,420,412,419] DONE. T1 [405,422,424(impl),
406,407]. T2 [397(PR#433),398,399,401,402,400]. T3 [417,415,390(review),428,
429,248]. Deferred: 426(held) 411(live-verify held) 238(agnix arch held)
343(epic — closes when 406/407 land) 284(on-hold). Serial lanes: dispatch the
successor only after the head merges (esp T2 #398 needs #397's agnix-normalize.py
on main first).

**RE-CONFIRMED LESSONS:** long-but-ADVANCING review ≠ wedge (token counter must
be FROZEN; measure a 40s delta before any takeover — golem-390/397/415 all ran
5/6-agents 15-20min with advancing tokens, all healthy). API-error-to-idle-prompt
= nudge not kill (golem-397 hit a 400 error post-ship, PR already existed).
`git diff origin/main` 2-dot on a stale branch shows phantom deletions — use
`gh pr view --json files`.
