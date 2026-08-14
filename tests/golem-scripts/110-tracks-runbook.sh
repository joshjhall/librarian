# shellcheck shell=bash
# tracks-runbook.sh — golem helper-script tests (issue #673).
#
# Covers the banked-plan renderer: the NO-DISPATCH contract, launch-command
# fidelity against golem-launch.sh print, autonomy-level threading, serial lane
# rendering, rationale/deferred/deps carry-through, staleness reporting (both the
# flagged and the could-not-look arms), partial execution, and arg validation.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / RUNBOOK / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- fragment-local helpers -------------------------------------------------
#
# These three are used by this area only, so they stay here rather than in
# tests/lib/golem-sandbox.sh (which must not accrete single-use code).

# plant_tracks <sandbox> — write a three-lane banked composition:
#   lane 0 (L3) dispatched, 3 issues, one deps_honored edge
#   lane 1 (L2) pending, 2 issues
#   lane 2 (L4) pending, 1 issue
# Exercises partial execution (one lane in flight, two pending), level threading
# across three distinct levels, and every carry-through field in one fixture.
#
# The pending lanes carry an EXPLICIT `"dispatched": false`, matching what the
# `--runbook` setup flow writes when it banks a plan. Absence means something
# different (see plant_tracks_legacy) and is pinned separately.
plant_tracks() {
    local sb="$1"
    command mkdir -p "$sb/.worktrees/.status"
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{
  "tracks": [
    { "lane": 0, "autonomy_level": 3, "issues": [42, 43, 44],
      "dispatched": true, "deps_honored": ["#42->#44"] },
    { "lane": 1, "autonomy_level": 2, "issues": [77, 78], "dispatched": false },
    { "lane": 2, "autonomy_level": 4, "issues": [91], "dispatched": false }
  ],
  "deferred": [101, 102],
  "cross_track_overlap": 1,
  "dispatched": false,
  "rationale": ["composed 3 track(s) from 8 backlog issue(s)"]
}
EOF
}

# plant_tracks_legacy <sandbox> — a PRE-#673 composition: no `dispatched` key at
# all, at either level, because the key did not exist before this change. Every
# such file came from a setup flow that dispatched, which is what the schema's
# "absent means dispatched" back-compat clause encodes.
plant_tracks_legacy() {
    local sb="$1"
    command mkdir -p "$sb/.worktrees/.status"
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{
  "tracks": [
    { "lane": 0, "autonomy_level": 3, "issues": [42, 43] }
  ],
  "cross_track_overlap": 0
}
EOF
}

# plant_gh_stub <sandbox> <state> [labels] [body]
# Write $sb/bin/gh answering `gh issue view --json ...` with a fixed document, so
# the staleness path is driven offline and deterministically. Defaults describe a
# healthy open issue (no flags expected).
plant_gh_stub() {
    local sb="$1" state="${2:-OPEN}" labels="${3:-}" body="${4:-}"
    command mkdir -p "$sb/bin"
    {
        command echo '#!/usr/bin/env bash'
        command echo '# Test stub: answer `gh issue view` from fixed fixture data.'
        command echo "STATE='$state'"
        command echo "LABELS='$labels'"
        command echo "BODY='$body'"
        command cat <<'EOF'
labels_json=""
for l in $LABELS; do
    labels_json="$labels_json{\"name\":\"$l\"},"
done
labels_json="[${labels_json%,}]"
printf '{"state":"%s","labels":%s,"body":"%s"}\n' "$STATE" "$labels_json" "$BODY"
EOF
    } >"$sb/bin/gh"
    command chmod +x "$sb/bin/gh"
}

# run_runbook <sandbox> [--path-dir DIR] [runbook args...]
# Invoke tracks-runbook.sh inside the sandbox. `--path-dir DIR` PREPENDS DIR to
# PATH (for the tmux/gh stubs); omitting it runs against the ambient PATH.
#
# --unset=BASH_ENV for the same reason run_launch_auth needs it: in the
# devcontainer BASH_ENV points at /etc/bash_env, whose /etc/bashrc.d/ scripts
# hard-RESET $PATH — which would shadow the stubs these cases depend on.
run_runbook() {
    local sb="$1" pathdir=""
    shift
    if [ "${1:-}" = "--path-dir" ]; then
        pathdir="$2"
        shift 2
    fi
    local use_path="$PATH"
    [ -n "$pathdir" ] && use_path="$pathdir:$PATH"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$use_path" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$sb/tmux-args.log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$RUNBOOK" "$@" 2>&1)" || RUN_RC=$?
}

# --- tracks-runbook.sh ------------------------------------------------------

# No subcommand → usage error, exit 2.
test_runbook_no_arg_exits_2() {
    local sb
    new_sandbox sb
    run_runbook "$sb"
    assert_exit 2 "$RUN_RC" "tracks-runbook with no subcommand exits 2"
    assert_contains "$RUN_OUT" "Usage" "prints a usage message"
}

# Unknown subcommand → usage error, exit 2.
test_runbook_bad_subcommand_exits_2() {
    local sb
    new_sandbox sb
    run_runbook "$sb" frobnicate
    assert_exit 2 "$RUN_RC" "tracks-runbook with an unknown subcommand exits 2"
    assert_contains "$RUN_OUT" "Usage" "prints a usage message"
}

# Unknown flag → exit 2 rather than being silently ignored. A tolerated typo on a
# flag like --no-staleness would flip a documented behavior with no signal.
test_runbook_bad_flag_exits_2() {
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    run_runbook "$sb" render --frobnicate
    assert_exit 2 "$RUN_RC" "an unknown flag exits 2"
    assert_contains "$RUN_OUT" "unknown flag" "names the offending flag"
}

# No banked composition → exit 3 with an ACTIONABLE message (which path was
# checked, and the command that would create one), not a bare failure.
test_runbook_missing_tracks_exits_3() {
    local sb
    new_sandbox sb
    run_runbook "$sb" render
    assert_exit 3 "$RUN_RC" "a missing tracks.json exits 3"
    assert_contains "$RUN_OUT" "no banked composition" "says what was missing"
    assert_contains "$RUN_OUT" "/workflow:orchestrate tracks --runbook" \
        "points at the namespaced command that creates one"
}

# THE CORE CONTRACT: rendering dispatches NOTHING.
#
# Asserted with an instrumented stub rather than by inspecting output: the stub
# tmux appends its argv to a log file, so the assertion is that the log does not
# exist. Checking output for the absence of a dispatch message would pass even if
# a real dispatch had occurred — the failure this test exists to catch is
# precisely a silent one.
#
# THE FIXTURE MUST MAKE DISPATCH POSSIBLE, or the assertion is vacuous. This is
# the trap the first draft fell into: `golem-launch.sh launch` exits 2 at a
# missing worktree BEFORE it ever reaches tmux, so on a sandbox with no worktree
# dirs the sentinel stays unwritten whether the script dispatches or not — the
# test passed with `print` AND with `launch`. Planting the two pending lane
# heads' worktrees is what arms it: with them present, a `launch` reaches the
# stub and the log appears. (Preflight is not a second gate — golem-launch runs
# `preflight || true`.)
test_runbook_render_dispatches_nothing() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    plant_tmux_stub "$sb"
    # Arm the fixture: the pending lane heads (#77, #91) get real worktree dirs,
    # so nothing upstream of tmux would stop a dispatch.
    command mkdir -p "$sb/.worktrees/issue-77" "$sb/.worktrees/issue-91"
    run_runbook "$sb" --path-dir "$sb/bin" render --no-staleness
    assert_exit 0 "$RUN_RC" "render exits 0"
    assert_true "[ ! -e '$sb/tmux-args.log' ]" \
        "render never invokes tmux (no stub log written)"
    assert_not_contains "$RUN_OUT" "Created worktree" "no worktree was created"
}

# LAUNCH-COMMAND FIDELITY: the rendered head command must be byte-identical to
# what `golem-launch.sh print` emits for the same issue+level.
#
# This is the drift AC. The runbook is only trustworthy if pasting its line runs
# exactly what a real dispatch would; a hand-assembled line would diverge the
# first time launch_line changes, silently, and the operator would paste a
# command that no longer matches the pipeline.
test_runbook_head_command_matches_golem_launch_print() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb expected
    new_sandbox sb
    plant_tracks "$sb"
    # Lane 1's head is #77 at L2 — a pending lane, so it renders a command.
    run_in "$sb" "$LAUNCH" print 77 --level 2
    expected="$RUN_OUT"
    assert_not_empty "$expected" "golem-launch print produced a reference line"

    run_runbook "$sb" render --no-staleness
    assert_exit 0 "$RUN_RC" "render exits 0"
    assert_contains "$RUN_OUT" "$expected" \
        "the runbook's head command is byte-identical to golem-launch.sh print"
}

# LEVEL THREADING: each lane's own autonomy_level reaches its command.
#
# Mutation-checked by construction: the fixture's three lanes are L3/L2/L4 and
# the two PENDING ones are L2 and L4, so a renderer hardcoding any single level
# (including golem-launch's own default of 4) fails at least one assertion.
test_runbook_threads_per_lane_level() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    run_runbook "$sb" render --no-staleness
    assert_contains "$RUN_OUT" "/workflow:next-issue 77 --level 2" \
        "lane 1's head carries its own L2, not a default"
    assert_contains "$RUN_OUT" "/workflow:next-issue 91 --level 4" \
        "lane 2's head carries L4"
    assert_not_contains "$RUN_OUT" "/workflow:next-issue 77 --level 4" \
        "lane 1's command is not emitted at the default level"
}

# SERIAL RENDERING: only the lane HEAD gets a runnable command; the remainder is
# marked as queued behind the previous PR.
#
# A lane is serial by construction, so emitting every issue as a runnable command
# would invite the operator to launch a lane in parallel — colliding work the
# composition exists to prevent.
test_runbook_renders_lane_serially() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    run_runbook "$sb" render --no-staleness
    assert_contains "$RUN_OUT" "#78 — after #77's PR merges" \
        "the non-head issue is marked as waiting on the previous PR"
    assert_not_contains "$RUN_OUT" "next-issue 78" \
        "the non-head issue gets NO runnable launch command"
    assert_contains "$RUN_OUT" "serial" "the lane is labelled serial"
}

# CARRY-THROUGH: rationale, deferred, cross_track_overlap, and the build-order
# edges all reach the runbook — the context the operator needs to choose WHICH
# lane to spend on, rather than just starting at lane 0.
test_runbook_carries_composition_context() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    run_runbook "$sb" render --no-staleness
    assert_contains "$RUN_OUT" "composed 3 track(s)" "rationale reaches the runbook"
    assert_contains "$RUN_OUT" "101 102" "deferred issues reach the runbook"
    assert_contains "$RUN_OUT" "cross-track overlap 1" "the overlap count is shown"
    assert_contains "$RUN_OUT" "#42->#44" "deps_honored build-order edges are shown"
}

# PARTIAL EXECUTION: a plan with lane 0 launched and lanes 1-2 pending renders
# correctly — the in-flight lane shows as such and re-offers NO command, while
# untouched lanes still show theirs. This is what makes a drip-fed plan stable
# across sessions.
test_runbook_partial_execution_stable() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    run_runbook "$sb" render --no-staleness
    assert_contains "$RUN_OUT" "#42 — IN FLIGHT" "the dispatched lane head shows as in flight"
    assert_not_contains "$RUN_OUT" "next-issue 42" \
        "the in-flight lane does not re-offer its launch command"
    assert_contains "$RUN_OUT" "next-issue 77" "a pending lane still offers its command"
    assert_contains "$RUN_OUT" "BANKED" "the plan is labelled planned-not-dispatched"
}

# BACK-COMPAT: an ABSENT `dispatched` reads as DISPATCHED, at BOTH levels.
#
# The schema promises this for pre-#673 files, which have no `dispatched` key at
# all. Getting the per-lane polarity backwards (testing `= "true"` rather than
# `!= "false"`) produces output that CONTRADICTS ITSELF: the header says "already
# in flight" while the next line offers a launch command for the same golem — and
# an operator following it double-launches a running golem. Asserting both halves
# together is what pins the two checks to the same polarity; the header alone was
# already correct while the lane was not.
test_runbook_absent_dispatched_reads_as_dispatched() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks_legacy "$sb"
    run_runbook "$sb" render --no-staleness
    assert_exit 0 "$RUN_RC" "a pre-#673 tracks.json still renders"
    assert_contains "$RUN_OUT" "already in flight" \
        "an absent top-level dispatched reads as dispatched"
    assert_contains "$RUN_OUT" "#42 — IN FLIGHT" \
        "an absent PER-LANE dispatched also reads as dispatched"
    assert_not_contains "$RUN_OUT" "next-issue 42" \
        "no launch command is offered for an already-running golem"
    assert_not_contains "$RUN_OUT" "BANKED" "a legacy plan is not labelled banked"
}

# The already-dispatched header branch, pinned on its own. Without this the
# alternate branch of render_header's conditional has no assertion, so a flipped
# condition or a typo'd string would ship unnoticed.
test_runbook_dispatched_plan_header() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command mkdir -p "$sb/.worktrees/.status"
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "autonomy_level": 3, "issues": [42], "dispatched": true } ],
  "cross_track_overlap": 0, "dispatched": true }
EOF
    run_runbook "$sb" render --no-staleness
    assert_exit 0 "$RUN_RC" "a dispatched plan renders"
    assert_contains "$RUN_OUT" "already in flight" "the dispatched header branch fires"
    assert_not_contains "$RUN_OUT" "BANKED" "and the banked message does not"
}

# STALENESS FLAGGED, NEVER ACTED ON: a closed issue is annotated AND still
# rendered. Auto-dropping it would silently rewrite a plan the operator may be
# midway through — and they may have closed it deliberately.
test_runbook_flags_stale_without_dropping() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    plant_gh_stub "$sb" CLOSED "" ""
    run_runbook "$sb" --path-dir "$sb/bin" render
    assert_exit 0 "$RUN_RC" "render exits 0 with staleness checking on"
    assert_contains "$RUN_OUT" "CLOSED since composition" "a closed issue is flagged"
    assert_contains "$RUN_OUT" "next-issue 77" \
        "the flagged entry is STILL rendered with its command (never auto-dropped)"
}

# A status label acquired after composition is flagged too — someone else may
# already own the issue, which is the drift most likely to waste a launch.
test_runbook_flags_status_label_drift() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    plant_gh_stub "$sb" OPEN "status/in-progress severity/medium" ""
    run_runbook "$sb" --path-dir "$sb/bin" render
    assert_contains "$RUN_OUT" "now status/in-progress" "a newly in-progress issue is flagged"
}

# The OTHER THREE status labels are flagged too.
#
# stale_flags_for matches four space-padded labels; only status/in-progress was
# covered above. Each arm is its own glob, so a typo or a broken padding boundary
# in one would ship silently — and the padding is exactly what the code comment
# warns about. Driven one label per sandbox because the stub answers with a fixed
# document for every issue.
test_runbook_flags_remaining_status_labels() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb label
    for label in status/pr-pending status/blocked status/on-hold; do
        new_sandbox sb
        plant_tracks "$sb"
        plant_gh_stub "$sb" OPEN "$label" ""
        run_runbook "$sb" --path-dir "$sb/bin" render
        assert_contains "$RUN_OUT" "now $label" "$label is flagged"
    done
}

# The space-padding boundary itself: a label that CONTAINS a watched label as a
# prefix must not trip it. `status/blocked-by-design` is not `status/blocked`,
# and matching it would flag a healthy issue on every render.
test_runbook_status_label_match_is_exact() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    plant_gh_stub "$sb" OPEN "status/blocked-by-design" ""
    run_runbook "$sb" --path-dir "$sb/bin" render
    assert_not_contains "$RUN_OUT" "now status/blocked" \
        "a longer label sharing a watched prefix does not trip the match"
}

# An empty lane renders its placeholder and does not fall through to the head
# lookup (which would read issues[0] of an empty array).
test_runbook_empty_lane() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command mkdir -p "$sb/.worktrees/.status"
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "autonomy_level": 3, "issues": [], "dispatched": false } ],
  "cross_track_overlap": 0, "dispatched": false }
EOF
    run_runbook "$sb" render --no-staleness
    assert_exit 0 "$RUN_RC" "an empty lane renders without error"
    assert_contains "$RUN_OUT" "(empty lane)" "the empty-lane placeholder is shown"
    assert_not_contains "$RUN_OUT" "launch this" "no launch command is invented"
}

# `--status-dir` with no value is a usage error, distinct from an unknown flag.
# Silently treating it as absent would fall back to repo_root and render a
# DIFFERENT plan than the operator asked for.
test_runbook_status_dir_without_value_exits_2() {
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    run_runbook "$sb" render --status-dir
    assert_exit 2 "$RUN_RC" "--status-dir with no value exits 2"
    assert_contains "$RUN_OUT" "needs a directory" "the message names what is missing"
}

# A dependency declared after composition is flagged — the one drift that can
# make a lane's ORDER wrong rather than just its membership.
#
# The fixture body uses the same `Depends on #N` spelling next-issue parses. The
# detection regex is POSIX-class-only on purpose: a GNU-only `\s`/`\w` spelling
# matches nothing under BSD grep, so on macOS every plan would silently report as
# dependency-free.
test_runbook_flags_new_dependency() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    plant_gh_stub "$sb" OPEN "" "Depends on #500 for the schema"
    run_runbook "$sb" --path-dir "$sb/bin" render
    assert_contains "$RUN_OUT" "declares a dependency" "a newly-declared dependency is flagged"
}

# A FAILED `golem-launch.sh print` IS REPORTED, not rendered as a blank line.
#
# Under `set -uo pipefail` a failed print yields empty stdout, so inlining it in
# the echo would print "launch this:" followed by nothing and still exit 0 — the
# runbook's single most important line silently missing, reported as success.
#
# Driven against a COPY of the scripts dir whose golem-launch.sh is replaced by a
# failing stub: the real one is hard to fail on demand, and the point is the
# renderer's handling of a non-zero exit, whatever its cause (version-skew
# refusal, bad config, missing file).
test_runbook_reports_failed_launch_print() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_tracks "$sb"
    command cp -r "$SCRIPTS" "$sb/scripts"
    command cat >"$sb/scripts/golem-launch.sh" <<'EOF'
#!/usr/bin/env bash
# Test stub: fail the way a version-skew refusal would.
command echo "golem-launch: simulated failure" >&2
exit 3
EOF
    command chmod +x "$sb/scripts/golem-launch.sh"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$sb/scripts/tracks-runbook.sh" render --no-staleness 2>&1)" || RUN_RC=$?
    assert_contains "$RUN_OUT" "LAUNCH COMMAND UNAVAILABLE" \
        "a failed print is reported, not rendered as a blank line"
    assert_contains "$RUN_OUT" "exit 3" "the failure carries the launcher's exit status"
    assert_not_contains "$RUN_OUT" "#77 — launch this:" \
        "the lane does not claim to offer a command it could not build"
}

# The default STATUS_DIR resolution's failure branch: outside a git repo, with no
# --status-dir, there is nothing to resolve against. Exit 3 with a message that
# names the missing input, rather than rendering against a guessed path.
test_runbook_outside_git_repo_exits_3() {
    local outside
    outside="$(command mktemp -d "$WORKDIR/nogit.XXXXXX")"
    RUN_RC=0
    RUN_OUT="$(cd "$outside" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$outside" \
            "$REAL_BASH" "$RUNBOOK" render 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "running outside a git repo with no --status-dir exits 3"
    assert_contains "$RUN_OUT" "not inside a git repository" "the message names the problem"
}

# tr_int's fallback: a malformed numeric field degrades to the default instead of
# propagating an empty string into `-lt`/`-eq` arithmetic. Here `autonomy_level`
# is a string and `cross_track_overlap` is absent; the render must still produce
# a usable runbook rather than erroring out of the loop bounds.
test_runbook_malformed_numeric_fields_fall_back() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command mkdir -p "$sb/.worktrees/.status"
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "autonomy_level": "three", "issues": [42], "dispatched": false } ],
  "dispatched": false }
EOF
    run_runbook "$sb" render --no-staleness
    assert_exit 0 "$RUN_RC" "a malformed numeric field still renders"
    assert_contains "$RUN_OUT" "#42" "the lane's issue is still listed"
    assert_contains "$RUN_OUT" "--level 4" "a non-numeric autonomy_level falls back to the default"
}

# COULD-NOT-LOOK IS NOT CLEAN: with gh unavailable the render says the staleness
# check did not run.
#
# Reporting "nothing stale" because it could not look is indistinguishable from a
# working check — the exact fail-loud rule this repo applies to every scanner. The
# stub dir here holds ONLY jq (and the shell), so gh genuinely is not resolvable.
test_runbook_reports_unknowable_staleness() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (tracks-runbook reads tracks.json with jq)"
        return 0
    fi
    local sb stub jqbin
    new_sandbox sb
    plant_tracks "$sb"
    # A minimal PATH carrying jq but NOT gh. Symlink rather than copy so this
    # works regardless of how jq was installed.
    stub="$sb/nogh-bin"
    command mkdir -p "$stub"
    jqbin="$(command -v jq)"
    command ln -s "$jqbin" "$stub/jq"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$stub" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$RUNBOOK" render --status-dir "$sb/.worktrees/.status" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "render still exits 0 without gh"
    assert_contains "$RUN_OUT" "staleness: NOT CHECKED" \
        "an unavailable gh is reported, not passed off as a clean check"
    assert_contains "$RUN_OUT" "gh unavailable" "the render names WHY the check did not run"
}

# jq is REQUIRED, and its absence fails loudly (exit 3) rather than rendering an
# empty runbook. Every field is read through jq, so a silent no-jq path would
# print a plan that looks like it has no lanes at all.
test_runbook_without_jq_fails_loudly() {
    local sb stub
    new_sandbox sb
    plant_tracks "$sb"
    stub="$sb/empty-bin"
    command mkdir -p "$stub"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$stub" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$RUNBOOK" render --status-dir "$sb/.worktrees/.status" 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "a missing jq exits 3 rather than rendering nothing"
    assert_contains "$RUN_OUT" "jq is required" "says which tool is missing"
}
