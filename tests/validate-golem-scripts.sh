#!/usr/bin/env bash
# Coverage for the bundled golem/worktree helper scripts in
# plugins/workflow/scripts/ that had ZERO tests (issue #82): golem-launch.sh,
# worktree-new.sh, worktree-rm.sh, golem-attach.sh, and golem-status.sh.
#
# These scripts drive the orchestrate golem flow (worktree create/teardown,
# tmux dispatch, attach, status table). A silent regression in any exit code or
# guard — a botched usage exit, a preflight that stops surfacing missing rules,
# a worktree-rm that stops refusing dirty trees — would ship unnoticed because
# nothing exercised them. This gate pins the deterministic, side-effect-free
# paths: argument validation, exit codes, and the offline preflight/status
# rendering. It deliberately does NOT spin up real tmux sessions or docker
# containers — `launch` is driven only to its missing-worktree exit, and
# `golem-attach` only to its no-session-no-container exit.
#
# Test shape mirrors tests/validate-seed-trust.sh: each case runs the REAL
# script inside a fresh `git init` sandbox under a module-level `mktemp -d`, so
# the script's repo_root resolves the sandbox (never the librarian checkout).
# Every git call and script invocation is wrapped in
# `/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}"` so git's hook-exported environment
# (GIT_DIR / GIT_COMMON_DIR / …) cannot pin repo_root to the OUTER repo when the
# suite runs from a `git push` pre-push hook — the failure mode root-caused in
# golem-gate-watch (PR #62). HOME is repointed at the sandbox for worktree-new
# because it transitively seeds trust into $HOME/.claude.json via
# seed-worktree-trust.sh — without the override a sandbox run would write the
# operator's real config.
#
# Pure bash + coreutils + git (+ jq for the preflight/status cases, which skip
# cleanly when jq is absent), reached via absolute /usr/bin/* paths per project
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/workflow/scripts"
LAUNCH="$SCRIPTS/golem-launch.sh"
WT_NEW="$SCRIPTS/worktree-new.sh"
WT_RM="$SCRIPTS/worktree-rm.sh"
ATTACH="$SCRIPTS/golem-attach.sh"
STATUS="$SCRIPTS/golem-status.sh"

# Resolve the real bash once so child invocations work even when PATH is
# deliberately stripped (the no-jq cases).
REAL_BASH="$(command -v bash)"

# Git's hook-exported environment — scrub per invocation so each sandbox is
# hermetic even under a pre-push hook (see validate-seed-trust.sh).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "golem/worktree helper scripts (#82)"

# --- Sandbox plumbing -------------------------------------------------------

# Module-level scratch dir, cleaned up once when the suite exits.
WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname>
# Creates a fresh git repo sandbox with one seed commit (so HEAD exists and can
# serve as GOLEM_BASE_REF), a `.worktrees/.status/` dir, and an empty `{}` at
# <sandbox>/.claude.json (the seed-trust target HOME is pointed at). Assigns the
# sandbox path to the caller's named variable. `git init` + the seed commit run
# with the git environment scrubbed so the sandbox is hermetic under a hook.
new_sandbox() {
    local __out="$1" dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" config user.name "Test"
    /usr/bin/printf 'seed\n' >"$dir/seed.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" add seed.txt 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    /usr/bin/mkdir -p "$dir/.worktrees/.status"
    # An empty, per-sandbox tmux socket dir. Pointing TMUX_TMPDIR here makes
    # `tmux ls` find no server (so golem-status/attach see ZERO sessions),
    # isolating the tests from REAL golem-* tmux sessions on the host — without
    # it, golem-status.sh's `tmux ls` picks up live golems and the empty-state
    # branch never fires.
    /usr/bin/mkdir -p "$dir/.tmux"
    /usr/bin/printf '{}\n' >"$dir/.claude.json"
    printf -v "$__out" '%s' "$dir"
}

# Captured results of the most recent invocation.
RUN_RC=0
RUN_OUT=""

# run_in <sandbox-dir> <script> [args...]
# Invokes the script from within the sandbox (so repo_root resolves there) with
# the git environment scrubbed, GOLEM_* pinned to the sandbox's worktree/status
# dirs, HOME repointed at the sandbox (so the transitive seed-trust write cannot
# touch the real ~/.claude.json), and the local-file copy disabled. Captures
# combined stdout+stderr in RUN_OUT and the exit code in RUN_RC.
run_in() {
    local dir="$1" script="$2"
    shift 2
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$script" "$@" 2>&1)" || RUN_RC=$?
}

# --- golem-launch.sh --------------------------------------------------------

# No subcommand → usage error, exit 2.
test_launch_no_arg_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH"
    assert_exit 2 "$RUN_RC" "golem-launch with no subcommand exits 2"
    assert_contains "$RUN_OUT" "Usage" "prints a usage message"
}

# Unknown subcommand → usage error, exit 2.
test_launch_bad_subcommand_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" frobnicate
    assert_exit 2 "$RUN_RC" "golem-launch with an unknown subcommand exits 2"
    assert_contains "$RUN_OUT" "Usage" "prints a usage message"
}

# `print <N>` with a valid number → emits a single bare `tmux new-session` line
# (matching the Bash(tmux new-session:*) allow rule) naming golem-N, exit 0.
test_launch_print_emits_new_session() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5
    assert_exit 0 "$RUN_RC" "print <N> exits 0"
    assert_contains "$RUN_OUT" "tmux new-session" "print emits a tmux new-session line"
    assert_contains "$RUN_OUT" "golem-5" "the line targets golem-5"
    assert_contains "$RUN_OUT" "/next-issue 5" "the line resumes the issue's next-issue run"
}

# `print` with a non-numeric argument → exit 2.
test_launch_print_non_numeric_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print abc
    assert_exit 2 "$RUN_RC" "print with a non-numeric issue exits 2"
    assert_contains "$RUN_OUT" "issue number" "explains an issue number is required"
}

# `launch <N>` when the worktree is absent → exit 2 with a remediation pointing
# at worktree-new.sh. Stops BEFORE any real `tmux new-session` (no worktree, so
# the dir guard fires first). Stub both settings scopes at in-sandbox paths so
# preflight reads no real ~/.claude/settings.json.
test_launch_missing_worktree_exits_2() {
    local sb
    new_sandbox sb
    /usr/bin/printf '{}\n' >"$sb/proj-settings.json"
    /usr/bin/printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "launch with a missing worktree exits 2"
    assert_contains "$RUN_OUT" "worktree" "names the missing worktree"
    assert_contains "$RUN_OUT" "worktree-new.sh" "points at worktree-new.sh for remediation"
}

# preflight with a project settings file containing ALL required rules → exit 0
# and reports the permissions are present. jq-gated.
test_launch_preflight_rules_present_exits_0() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (settings_has_rules no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    /usr/bin/cat >"$sb/proj-settings.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(tmux new-session:*)",
      "Bash(tmux ls:*)",
      "Bash(tmux kill-session:*)"
    ]
  }
}
EOF
    /usr/bin/printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" preflight 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "preflight with all rules present exits 0"
    assert_contains "$RUN_OUT" "present" "reports the launch permissions are present"
}

# preflight with rules MISSING in both scopes → exit 3 with an actionable
# remediation listing the rules to add. jq-gated.
test_launch_preflight_rules_missing_exits_3() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (settings_has_rules no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # Project file present but with only TWO of the three required rules.
    /usr/bin/cat >"$sb/proj-settings.json" <<'EOF'
{ "permissions": { "allow": ["Bash(tmux new-session:*)", "Bash(tmux ls:*)"] } }
EOF
    /usr/bin/printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" preflight 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "preflight with a missing rule exits 3"
    assert_contains "$RUN_OUT" "NOT authorized" "surfaces the unauthorized state"
    assert_contains "$RUN_OUT" "Bash(tmux kill-session:*)" "lists the rules to add"
}

# --- worktree-new.sh --------------------------------------------------------

# Non-integer argument → exit 2 before touching git.
test_worktree_new_non_integer_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" notanumber
    assert_exit 2 "$RUN_RC" "worktree-new with a non-integer arg exits 2"
    assert_contains "$RUN_OUT" "issue number" "explains an issue number is required"
}

# Happy path: creates .worktrees/issue-N on branch feature/issue-N from HEAD.
test_worktree_new_creates_worktree() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 31
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 on a fresh issue"
    assert_contains "$RUN_OUT" "Worktree ready" "reports the worktree is ready"
    assert_file_exists "$sb/.worktrees/issue-31/seed.txt" \
        "the worktree checkout contains the repo's files"
    local branches
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" branch --list "feature/issue-31")"
    assert_not_empty "$branches" "the feature/issue-31 branch was created"
}

# Idempotency guard: a second worktree-new for the SAME issue → exit 1 (worktree
# already exists), distinct from the bad-arg exit 2.
test_worktree_new_duplicate_exits_1() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 32
    assert_exit 0 "$RUN_RC" "first worktree-new succeeds"
    run_in "$sb" "$WT_NEW" 32
    assert_exit 1 "$RUN_RC" "second worktree-new for the same issue exits 1"
    assert_contains "$RUN_OUT" "already exists" "explains the worktree already exists"
}

# Distinct exit-1 arm: the worktree is gone but the branch still exists → exit 1
# naming the branch. Remove just the worktree (keep the branch) so the branch
# guard fires rather than the worktree guard.
test_worktree_new_existing_branch_exits_1() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 33
    assert_exit 0 "$RUN_RC" "first worktree-new succeeds"
    # Drop the worktree only (the branch lingers).
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" worktree remove .worktrees/issue-33 2>/dev/null
    run_in "$sb" "$WT_NEW" 33
    assert_exit 1 "$RUN_RC" "worktree-new with a lingering branch exits 1"
    assert_contains "$RUN_OUT" "branch" "explains the branch already exists"
}

# --- worktree-rm.sh ---------------------------------------------------------

# Non-integer argument → exit 2.
test_worktree_rm_non_integer_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_RM" notanumber
    assert_exit 2 "$RUN_RC" "worktree-rm with a non-integer arg exits 2"
    assert_contains "$RUN_OUT" "issue number" "explains an issue number is required"
}

# Absent issue → clean no-op (exit 0) with a "nothing to remove" message.
test_worktree_rm_absent_is_noop() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_RM" 404
    assert_exit 0 "$RUN_RC" "worktree-rm for an absent issue is a clean no-op (exit 0)"
    assert_contains "$RUN_OUT" "nothing to remove" "reports nothing to remove"
}

# Round-trip: worktree-new then worktree-rm removes the worktree AND the branch.
test_worktree_rm_round_trip() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 34
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    run_in "$sb" "$WT_RM" 34
    assert_exit 0 "$RUN_RC" "worktree-rm succeeds"
    assert_contains "$RUN_OUT" "removed worktree" "reports the worktree removal"
    assert_contains "$RUN_OUT" "deleted branch" "reports the branch deletion"
    local branches
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" branch --list "feature/issue-34")"
    assert_equals "" "$branches" "the feature/issue-34 branch is gone after rm"
}

# --- golem-attach.sh --------------------------------------------------------

# Non-integer argument → exit 2.
test_attach_non_integer_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$ATTACH" notanumber
    assert_exit 2 "$RUN_RC" "golem-attach with a non-integer arg exits 2"
    assert_contains "$RUN_OUT" "issue number" "explains an issue number is required"
}

# Valid issue number but no tmux session and no container status file → exit 1
# with a "no golem-N session" message. Uses a high issue number so no real
# golem-N session can exist on the host.
test_attach_no_session_exits_1() {
    local sb
    new_sandbox sb
    run_in "$sb" "$ATTACH" 987654
    assert_exit 1 "$RUN_RC" "attach with no session and no container exits 1"
    assert_contains "$RUN_OUT" "no golem-987654" "reports the missing session"
}

# --- golem-status.sh --------------------------------------------------------

# Empty status dir + no sessions + no pool → "No active golems", exit 0. Uses a
# status dir guaranteed empty (the fresh sandbox's). jq-gated only because the
# script uses jq for the table; the empty-state branch exits before jq, but keep
# the guard for the planted-row sibling below.
test_status_empty_reports_no_golems() {
    local sb
    new_sandbox sb
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status with no golems exits 0"
    assert_contains "$RUN_OUT" "No active golems" "reports no active golems"
}

# A planted golem-N.json cache renders a status row (smoke test of the jq table).
test_status_renders_planted_row() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    /usr/bin/cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a planted cache row"
    assert_contains "$RUN_OUT" "golem-42" "renders the planted golem row"
    assert_contains "$RUN_OUT" "GOLEM" "prints the table header"
}

# --- Run all tests ----------------------------------------------------------

# Every sandbox is built with `git init` + a commit, so the whole suite needs
# git. Gate it from inside a run_test-dispatched body so the counters stay
# consistent (skip_test is designed for within-test use).
git_unavailable() { ! command -v git >/dev/null 2>&1; }

test_git_available() {
    if git_unavailable; then
        skip_test "git not available — cannot build sandbox repos"
        return
    fi
    assert_true "command -v git" "git is available for sandbox construction"
}

run_test test_git_available "git is available (suite prerequisite)"

if git_unavailable; then
    generate_report
    exit $?
fi

run_test test_launch_no_arg_exits_2 "golem-launch: no subcommand exits 2"
run_test test_launch_bad_subcommand_exits_2 "golem-launch: unknown subcommand exits 2"
run_test test_launch_print_emits_new_session "golem-launch: print <N> emits a tmux new-session line"
run_test test_launch_print_non_numeric_exits_2 "golem-launch: print with a non-numeric issue exits 2"
run_test test_launch_missing_worktree_exits_2 "golem-launch: launch with a missing worktree exits 2"
run_test test_launch_preflight_rules_present_exits_0 "golem-launch: preflight with all rules present exits 0"
run_test test_launch_preflight_rules_missing_exits_3 "golem-launch: preflight with a missing rule exits 3"
run_test test_worktree_new_non_integer_exits_2 "worktree-new: non-integer arg exits 2"
run_test test_worktree_new_creates_worktree "worktree-new: creates the issue worktree + branch"
run_test test_worktree_new_duplicate_exits_1 "worktree-new: duplicate worktree exits 1"
run_test test_worktree_new_existing_branch_exits_1 "worktree-new: lingering branch exits 1"
run_test test_worktree_rm_non_integer_exits_2 "worktree-rm: non-integer arg exits 2"
run_test test_worktree_rm_absent_is_noop "worktree-rm: absent issue is a clean no-op (exit 0)"
run_test test_worktree_rm_round_trip "worktree-rm: round-trip removes worktree + branch"
run_test test_attach_non_integer_exits_2 "golem-attach: non-integer arg exits 2"
run_test test_attach_no_session_exits_1 "golem-attach: no session/container exits 1"
run_test test_status_empty_reports_no_golems "golem-status: empty state reports no active golems"
run_test test_status_renders_planted_row "golem-status: planted cache row renders in the table"

generate_report
