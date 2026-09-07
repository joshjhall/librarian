# shellcheck shell=bash
# Golem, worktree, hook and workflow-decision stages (#960).
#
# Carries the second-largest stage: golem/worktree helper scripts, 285s
# (22%). Grouped by area — the golem lifecycle, the PreToolUse hooks, the
# stop/route decision helpers and the release toolchain all exercise the
# same sandbox machinery in tests/lib/golem-sandbox.sh.
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
run_stage "coverage-driver listener start attempt" bash "$SCRIPT_DIR/validate-cov-listener.sh"
# The ORDERING of a status-label transition (#636/#921): add first, remove only
# on success, so a failed add can never strip the existing label and leave an
# issue briefly re-selectable by another golem. Its fixtures point at a label
# that does not exist, which is what keeps them discriminating now that #921 has
# created the two that were missing.
run_stage "status-label transition ordering" bash "$SCRIPT_DIR/validate-label-transition.sh"
