# shellcheck shell=bash
# Golem, worktree, hook and workflow-decision stages (#960, re-balanced #964).
#
# Carries the second-largest stage: golem/worktree helper scripts, 234s after
# #961 fixed the unbounded capture that had it reading as 1175s. Grouped by
# area — the golem lifecycle, the PreToolUse hooks, the stop/route decision
# helpers and the release toolchain all exercise the same sandbox machinery in
# tests/lib/golem-sandbox.sh.
#
# `Lint-gate integrity` (54-62s) STAYS HERE, and is not golem-specific. #964
# named it as movable and measured the move: shifting it to 30-scanners would
# have made that shard the critical path and given back most of the win. It is
# parked here for BALANCE. If the shards are ever re-cut, this is the first stage
# to reconsider — but re-measure all three sums before moving it, rather than
# moving it because it reads as out of place here. It is.
#
# NOTE: after #964's move this shard is the narrow critical path (350s against
# 337s and 260s, run 34187725583) — the three are within ~90s, so which one leads
# varies with runner speed. That is the intended end state, not a defect: the
# floor is `Shell portability` in 10-portability, and no partition beats it by
# more than the slack between these sums.
#
# DO NOT MOVE A STAGE OUT OF HERE IF ITS SUITE SOURCES golem-sandbox.sh.
# That sandbox creates and removes git worktrees in the repo under test, and two
# suites doing that against the SAME checkout contend on shared worktree state.
# The symptom is not a failure but a STALL at an arbitrary point — measured on
# pristine main with 13 GB free and healthy load, so it is contention rather
# than resource starvation, and it cost ~1h of wall clock across two lanes.
#
# It presents exactly like the symptom that motivated this whole issue: a job
# cancelled at `timeout-minutes` with nothing having failed. On GitHub Actions
# each matrix leg gets its own runner and checkout so the hazard does not apply,
# but `run-all.sh --shard N` run twice LOCALLY shares one checkout — that is the
# live case. Keeping these stages together makes them sequential, which is what
# makes them safe. tests/validate-shards.sh enforces it. See #961 for the
# unbounded capture that turns the contention into an unrecoverable hang.
#
# SOURCED by tests/run-all.sh (and by tests/validate-shards.sh with a stub
# run_stage), never executed — hence no shebang. Sourcing with a stub run_stage
# is what lets the partition be checked WITHOUT running the suite: the stub
# records each label instead of dispatching it. There is deliberately no
# second spelling of the label to keep in sync — one call site per stage.
#
# Add a stage HERE, not in run-all.sh — and add it to exactly one shard.

run_stage "golem-gate-watch feed snapshot" bash "$SCRIPT_DIR/golem-gate-watch.sh"
run_stage "Lint-gate integrity (resolution + skip reporting)" bash "$SCRIPT_DIR/validate-lint-gates.sh"
run_stage "Skip visibility (step summary + agnix install branches)" bash "$SCRIPT_DIR/validate-skip-visibility.sh"
run_stage "run-all verdict reporting (pipe-safe failure)" bash "$SCRIPT_DIR/validate-run-all-reporting.sh"
run_stage "Release toolchain coverage" bash "$SCRIPT_DIR/validate-release.sh"
run_stage "seed-worktree-trust path validation" bash "$SCRIPT_DIR/validate-seed-worktree-trust.sh"
run_stage "golem/worktree helper scripts" bash "$SCRIPT_DIR/validate-golem-scripts.sh"
run_stage "journal partial-recovery helper" bash "$SCRIPT_DIR/validate-recover-journal-partials.sh"
run_stage "workflow wall-time stop decision" bash "$SCRIPT_DIR/validate-workflow-wall-timeout.sh"
run_stage "CI-wait stop decision" bash "$SCRIPT_DIR/validate-ci-wait-timeout.sh"
run_stage "shared threshold-check library units" bash "$SCRIPT_DIR/validate-threshold-check.sh"
run_stage "review convergence stop decision" bash "$SCRIPT_DIR/validate-review-convergence.sh"
run_stage "review routing decision" bash "$SCRIPT_DIR/validate-review-route.sh"
run_stage "autonomy-resolver decision table + parity" bash "$SCRIPT_DIR/validate-autonomy-resolve.sh"
run_stage "measure-spawn-prefix accounting" bash "$SCRIPT_DIR/validate-measure-spawn-prefix.sh"
run_stage "golem-notify Notification hook" bash "$SCRIPT_DIR/validate-golem-notify.sh"
run_stage "golem-event-listener receiver" bash "$SCRIPT_DIR/validate-golem-event-listener.sh"
run_stage "bash-guard PreToolUse hook" bash "$SCRIPT_DIR/validate-bash-guard.sh"
run_stage "bash-guard main-session worktree rule" bash "$SCRIPT_DIR/validate-bash-guard-worktree.sh"
run_stage "worktree-scope PreToolUse hook" bash "$SCRIPT_DIR/validate-worktree-guard.sh"
run_stage "read-scope PreToolUse hook" bash "$SCRIPT_DIR/validate-read-scope-guard.sh"
run_stage "golem-resolve clearing-signal helper" bash "$SCRIPT_DIR/validate-golem-resolve.sh"
run_stage "golem-inbox brokered gate reverse channel" bash "$SCRIPT_DIR/validate-golem-inbox.sh"
run_stage "golem-watch streaming dispatcher" bash "$SCRIPT_DIR/validate-golem-watch.sh"
run_stage "token-cost reconciliation harness" bash "$SCRIPT_DIR/validate-token-report.sh"
run_stage "context-budget session-length signal" bash "$SCRIPT_DIR/validate-context-budget.sh"
run_stage "ephemeral-port allocation + retry" bash "$SCRIPT_DIR/validate-free-port.sh"
# The ORDERING of a status-label transition (#636/#921): add first, remove only
# on success, so a failed add can never strip the existing label and leave an
# issue briefly re-selectable by another golem. Its fixtures point at a label
# that does not exist, which is what keeps them discriminating now that #921 has
# created the two that were missing.
run_stage "status-label transition ordering" bash "$SCRIPT_DIR/validate-label-transition.sh"
