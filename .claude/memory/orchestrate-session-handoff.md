---
name: orchestrate-session-handoff
description: "Live state of the /orchestrate backlog-burndown session — what shipped, what's queued, and the auth-token stopgap needed to launch golems"
metadata:
  node_type: memory
  type: project
  originSessionId: f13f8a40-6882-4f2d-9d60-af45cc085fd6
---

<!-- Dense session-state log; long single-line facts are intentional. -->
<!-- rumdl-disable MD013 -->

Active `/orchestrate tracks` backlog-burndown, running since 2026-07-04. Golems dispatched as worktree processes at **L3** (plan-gated, auto-merge); orchestrator brokers each plan gate in-session (present plan from `~/.claude/plans/*.md`, human decides, send option 1 via `tmux send-keys` — see [[orchestrate-broker-then-send]]).

**CRITICAL — auth-token stopgap.** Golems launched via bare `tmux new-session` do NOT inherit `ANTHROPIC_AUTH_TOKEN` (container's `/dev/shm/op-secrets-cache` isn't sourced by tmux login shells), so a golem dies at its first network call. Root cause is env propagation, NOT token expiry (Bifrost op cred is non-expiring). #244 fixed this in-repo (`resolve_auth_token` in `golem-launch.sh`, merged `ad34933`) BUT the fix is not live until the **installed** `/opt/librarian/plugins/workflow/scripts/golem-launch.sh` is updated to a release carrying #244. So for every dispatch until then, hand-inject:

```sh
TOK="$(op read "$OP_ANTHROPIC_AUTH_TOKEN_REF" 2>/dev/null)"
tmux new-session -d -s golem-N -c <worktree> -e GOLEM_ID=golem-N -e ANTHROPIC_AUTH_TOKEN="$TOK" "claude --permission-mode auto '/workflow:next-issue N --level 3' ; claude --permission-mode auto '/workflow:ship-issue --autonomous'"
```

Never echo the token (a `${x:+}` probe leaked it once). Once the installed copy has `resolve_auth_token`, drop the `-e` and use `golem-launch.sh launch N`. **Cutting a release with #244 in it makes this stopgap obsolete once golems `plugin update`.**

**Also at dispatch:** librarian plugins must be enabled at USER scope (`claude plugin enable workflow@librarian --scope user` + review-audit, dev-core) or golems in a worktree cwd get `Unknown command: /workflow:next-issue` (DOA).

**Merge invariant:** golems can't self-merge (two-party guard, [[auto-mode-blocks-self-merge]]); orchestrator merges each green+CLEAN PR with `gh pr merge N --squash --delete-branch`. The local-branch-delete WARNING is expected — the worktree holds the branch; reap with `worktree-rm.sh N` AFTER merge ([[ship-worktree-merge-cleanup]]). Merging self-authored PRs needs explicit human authorization (auto-mode classifier blocks it otherwise).

**2026-07-05 `tracks` composition (4 lanes, L3, cross_track_overlap=6):**

- T0 [260,246,247,258] (batch-1 head #270 shipped; #260 shipped)
- T1 [259,261,262,269] (batch-1 head #244 shipped; #259 shipped)
- T2 [271,272,224,266] (batch-1 head #273 shipped; #271 shipped)
- T3 [267,268,227,256] (batch-1 head #242 shipped; #267 shipped)
- Deferred: #250 #251 #252 #257 #217 #263 #264 #265 #240 #248 #238 #243 #253 #254 #278 #279 (+ #280-284 filed since)

**BATCH 1 COMPLETE (2026-07-06):** #270→PR#275, #244→PR#277, #273→PR#274, #242→PR#276 — all merged + reaped.

**BATCH 2 COMPLETE (impl 2026-07-06; integration train finished 2026-07-15 after an ISP outage stranded the two trailing PRs):**

- #259 → PR#286 → merged `e09a0a1` (disjoint, landed first)
- #260 → PR#287 → merged `f961b13`
- #267 → PR#285 → merged `d69d046` (2026-07-15; overlap trio, landed after rebase)
- #271 → PR#288 → merged `f1aba3b` (2026-07-15; rebased onto #285, clean, all worktrees reaped)
- main now at `f1aba3b`, CI green, no open PRs, no stray worktrees/branches.

**Collision lesson (batch 2):** #260/#267/#271 all edited `ship-issue/workflow.js` + `code-reviewer/workflow.js` in *different regions* — the rebases were clean (no conflicts) despite the file overlap. Train order that worked: merge #285 → rebase #288 onto it → merge. Don't predict collisions from `git diff origin/main <branch>` (shows intervening merges as phantom edits); `gh pr view N --json files` is authoritative.

**0.6.0 RELEASED (2026-07-15).** `just release-minor` → PR#289 → merged `e8b9864` → tag `v0.6.0` pushed → `release.yml` published the cosign-signed `librarian-0.6.0.tar.gz` + `.sigstore.json`; `releases/latest` = v0.6.0 (what containers' LIBRARIAN_REF pins). CAVEAT: the **installed** `/opt/librarian` is a static non-writable copy still at 0.5.0 (NOT a git repo — can't be refreshed from this session; needs a privileged rebuild). So golems' in-worktree Claude still loads 0.5.0 skills AND the auth-token stopgap is STILL required until the install dir is rebuilt to 0.6.0.

**BATCH 3 DISPATCHED (2026-07-15, L3):** T0→#246 (golem-246), T1→#261 (golem-261), T2→#272 (golem-272), T3→#268 (golem-268). All 4 as worktree golems via manual stopgap (`tmux new-session … -e ANTHROPIC_AUTH_TOKEN="$TOK" "claude --permission-mode auto '/workflow:next-issue N --level 3' ; …ship-issue --autonomous"`) — used manual injection NOT `golem-launch.sh` because the 0.6.0 local launcher hardcodes `--level 4` (no level flag) and its skew guard refuses against the 0.5.0 install. All 4 labeled `status/in-progress`, authenticated + working. **L3 = plan-gated: each blocks at ExitPlanMode for human plan approval — attach via `golem-attach.sh N`, press option-1 (human keystroke, not agent-drivable per #29), detach.** Collision note: #246/#272/#268 all component/workflow (likely orchestrate workflow.js overlap); #261 is ship-issue (disjoint). Serialize the workflow trio in the train.

**BATCH 3 PLAN GATES ALL APPROVED + RELEASED (2026-07-15).** All 4 plans reviewed (tight scope, repo-idiom-consistent). Operator explicitly authorized approving all gates → `tmux send-keys -t golem-N 1` accepted by the classifier (the explicit user "approve all plan gates" directive cleared the wall that had denied the un-directed send earlier — [[orchestrate-broker-then-send]]). All 4 now implementing autonomously toward PRs. NOTE the plans: #261=sameCommentId str-normalize + dedup fold; #272=buildTrainOrder pure helper + fail-closed `train.unresolved`; #268=safeWorktreePath validator + `<worktree>` field (deliberately NOT reusing safeRef); #246=footer-anchor slice (GOLEM_PANE_FOOTER_LINES=8) + glyph anchor. **COLLISION for B3 train:** #268 adds safeWorktreePath to orchestrate/workflow.js; #272 adds buildTrainOrder to the SAME file → serialize #268+#272 in the train. #269 (Batch 4) also touches safeRef in that file. #261 (ship-issue) + #246 (golem-gate-watch.sh) are disjoint.

**BATCH 3 COMPLETE (2026-07-15).** All 4 merged via orchestrator integration train under a standing "auto-merge green+clean" directive from the operator (the explicit standing directive clears the auto-mode classifier per-merge; the allow-list rule `Bash(gh pr merge:*)` was already present but does NOT preempt the classifier — different layer). Order: #290(#261)→#291(#246)→#292(#272) disjoint/free; #293(#268) rebased onto main (clean union — buildTrainOrder + safeWorktreePath in different regions of orchestrate/workflow.js, 291 helper assertions), then merged. main→f732b93, CI green, all worktrees reaped, all 4 issues closed.

**LESSON — golem-gate-watch liveness flake blocks pre-push during active orchestration ([[golem-gate-watch-host-leak]]):** the `golem-gate-watch feed snapshot` stage FAILS in `tests/run-all.sh` (pre-push hook) when live `golem-*` tmux sessions leak into its liveness sweep ("fresh-activity golem reports alive, not advancing"). REMEDY THAT WORKED: don't `--no-verify` blindly — kill the finished golem sessions first (`tmux kill-session -t golem-N`, or `worktree-rm.sh N` which does it) so the leak source is gone, then the suite passes HONESTLY. Only the merged golems' sessions are safe to reap; keep the pushing worktree's dir but its session can be killed independently.

**BATCH 4 DISPATCH (next):** #262 (review-audit codebase-audit budget-skip), #278 (scripts/config.sh /usr/bin/git — [[usr-bin-hardcoding-golem-scripts]]), #266 (dev-core code-review rescore), #269 (workflow safeRef path traversal) — four different components, minimal collision. NOTE #269 fixes safeRef in orchestrate/workflow.js which #268 (just merged) touched — but #268 added a SEPARATE safeWorktreePath validator, so #269's safeRef edit should be disjoint from #268's now-merged region; still verify at train time. Dispatch pattern identical to Batch 3: worktree-new.sh N → manual `tmux new-session -e ANTHROPIC_AUTH_TOKEN` at --level 3 (installed launcher still 0.5.0) → label in-progress → broker plan gates (operator authorizes → send-keys 1) → train.

**BATCH 4 DISPATCHED + ALL 4 PLAN GATES RELEASED (2026-07-15, L3).** Operator gave STANDING plan-gate approval for this batch (review+summarize+release without per-plan wait, pause only on scope drift). Plans (all sound, no drift): #262=coverageSection() helper + skipped_domains envelope, surfaces budget-skipped audit domains on all 3 report paths (review-audit/codebase-audit/workflow.js); #278=config.sh repo_root() `command git`+pure-bash dirname (sibling of #228/#241, [[usr-bin-hardcoding-golem-scripts]]); #266=code-reviewer merge goes ref-based (kept/merged/acknowledged, harness reassembles, model never authors certainty/file/category) + loud dropped-ref accounting (dev-core/code-reviewer/workflow.js + code-reviewer.md); #269=safeRef rejects `..`/`.` segments + absolute + leading-dash in BOTH orchestrate & rebase-agent harnesses, segment-based (keeps .github/* dotfiles), inverts stale test foil, AND fixes the safeWorktreePath comment #268 left stale. **TRAIN COLLISION:** #269 edits safeRef in orchestrate/workflow.js (the file #268 touched) — should be disjoint from #268's now-merged safeWorktreePath region but VERIFY; #262/#266/#278 are review-audit / dev-core / scripts — all disjoint. Standing "auto-merge green+clean" directive in effect for the resulting PRs.

**BATCH 4 COMPLETE (2026-07-15) — all 4 landed: #262(#294), #269(#296), #278(#295), #266(#297).** Main at `661e755`, CI green, all worktrees/sessions reaped. Filed 2 review-surfaced follow-ups: #298 (id/related_ids validation) + #299 (≥2-ref severity floor) from golem-266's adversarial review.

**MAJOR LESSON — golem-266 review-cycle non-convergence + orchestrator ship-takeover.** golem-266 (#266, heaviest change, ref-based code-review merge) ran ~90min and got STUCK: its 0.5.0 ship-issue harness cap-drifted (`MAX_CYCLES` enforcement lives in SKILL prose, not hard code, in 0.5.0), so it looped 4+ adversarial review cycles WITHOUT ever committing (HEAD stayed at stale base, all work uncommitted in working tree). The review DID work — caught 3 real blocking bugs (incl. single-ref severity-rewrite hole → fixed via `merged.refs >= 2`) + 2 deferrables. ORCHESTRATOR TAKEOVER (operator-approved): (1) `tmux kill-session golem-266`; (2) its worktree was on STALE base (branched before #294/#295/#296 merged) with 0 commits — `git stash -u` → `git reset --hard origin/main` → `git stash pop` (clean, dev-core files disjoint from intervening merges) restored a clean 3-file diff; (3) verified (368 helper assertions, full run-all green), committed, pushed, PR #297, merged (self-authored → needed explicit operator approval, NOT covered by the golem green+clean standing directive). FUTURE: 0.6.0 has #275/#288 review-cycle fixes — updating the install prevents this.

**PLUGIN UPDATE 0.5.0→0.6.0 (BLOCKED on sudo).** `/opt/librarian` is a root-owned static copy at 0.5.0; `sudo` needs a password + TTY that this non-interactive shell lacks, so ONLY the operator can run it. Command: `sudo rsync -a --delete --exclude='.git' --exclude='.worktrees' --exclude='node_modules' /workspace/librarian/plugins/ /opt/librarian/plugins/` + `sudo cp` VERSION/marketplace.json/CHANGELOG.md, then `claude plugin marketplace add /opt/librarian` + `claude plugin update {workflow,review-audit,dev-core}@librarian`. Once done: installed golem-launch.sh gains `resolve_auth_token` → DROP the manual `-e ANTHROPIC_AUTH_TOKEN` stopgap, use `golem-launch.sh launch N`; and future golems get the review-cycle convergence fixes. STILL PENDING as of session end.

**BATCH 4 PROGRESS (2026-07-15):** #262→PR#294→MERGED `c5f1436` (disjoint review-audit, adversarial review passed, golem reaped, issue closed). #278→PR#295: golem's OWN new `repo_root resolves via PATH` test FAILED in CI (passed locally); golem-278 SELF-HEALED via ci-fixer — re-pushed `bf32b73` "use a git symlink not a bash wrapper in the PATH-shim test" → now CLEAN, awaiting golem's post-PR review + denied self-merge, then orchestrator merges. #266 (ref-based merge, heaviest — 33min/71k tok, next-issue-review harness 2/6 agents @ 379k workflow tokens) + #269 (safeRef, writing test cases) still implementing, no PR yet. **Merge #295 once golem-278 settles (disjoint scripts/config.sh). Watch #269↔#268 safeRef region at its merge.** Lesson reinforced: L3 ci-fixer self-heals CI failures without orchestrator intervention — don't jump in, let the pipeline work; only merge once the golem parks at its denied self-merge.
