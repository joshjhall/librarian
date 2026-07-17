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
CONFIG="$SCRIPTS/config.sh"

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
    assert_contains "$RUN_OUT" "/workflow:next-issue 5" "the line resumes the issue's namespaced next-issue run"
    # Pin the namespaced form: the pre-#230 regression emitted a bare
    # "'/next-issue" (the exact string the active plugin rejects as Unknown
    # command). Assert it never reappears — the ' before it disambiguates from
    # the "workflow:next-issue" substring, which also contains "next-issue".
    assert_not_contains "$RUN_OUT" "'/next-issue" "never emits the bare (un-namespaced) /next-issue"
    assert_not_contains "$RUN_OUT" "'/ship-issue" "never emits the bare (un-namespaced) /ship-issue"
}

# `print` with a non-numeric argument → exit 2.
test_launch_print_non_numeric_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print abc
    assert_exit 2 "$RUN_RC" "print with a non-numeric issue exits 2"
    assert_contains "$RUN_OUT" "issue number" "explains an issue number is required"
}

# --- golem-launch.sh autonomy-level threading (#301) ------------------------
# golem-launch.sh must carry the operator's CHOSEN level into the launch line's
# `/workflow:next-issue <N> --level M`, not a hardcoded 4. Exercised on the pure
# `print` path (no real tmux). The default (no flag, no env) stays 4 so a bare
# call is byte-identical to the pre-#301 behavior.

# `print <N> --level 3` emits `--level 3` and NEVER the old hardcoded `--level 4`.
test_launch_print_level_flag_substituted() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5 --level 3
    assert_exit 0 "$RUN_RC" "print <N> --level 3 exits 0"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5 --level 3" \
        "the launch line carries the chosen level 3"
    assert_not_contains "$RUN_OUT" "--level 4" \
        "the hardcoded --level 4 no longer appears when a level is passed"
}

# `print <N>` with no flag and no env → the documented default `--level 4`.
test_launch_print_level_defaults_to_4() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5
    assert_exit 0 "$RUN_RC" "print <N> with no level exits 0"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5 --level 4" \
        "an omitted level defaults to 4 (unchanged pre-#301 shape)"
}

# `GOLEM_LEVEL=2 print <N>` (no flag) → the env fallback wins → `--level 2`.
test_launch_print_level_env_fallback() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_LEVEL=2 \
            "$REAL_BASH" "$LAUNCH" print 5 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "GOLEM_LEVEL=2 print <N> exits 0"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5 --level 2" \
        "GOLEM_LEVEL is the env fallback when no --level flag is given"
}

# An explicit `--level` flag beats the `GOLEM_LEVEL` env fallback.
test_launch_print_level_flag_beats_env() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_LEVEL=2 \
            "$REAL_BASH" "$LAUNCH" print 5 --level 1 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "print <N> --level 1 with GOLEM_LEVEL=2 exits 0"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5 --level 1" \
        "the --level flag overrides the GOLEM_LEVEL env"
}

# `print <N> --level 9` (out of range) → exit 2 with an actionable message.
test_launch_print_level_out_of_range_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5 --level 9
    assert_exit 2 "$RUN_RC" "print <N> --level 9 exits 2"
    assert_contains "$RUN_OUT" "--level must be" "explains the valid level range"
}

# `print <N> --level` with no value → exit 2 (fail loud, no silent default).
test_launch_print_level_missing_value_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5 --level
    assert_exit 2 "$RUN_RC" "print <N> --level with no value exits 2"
    assert_contains "$RUN_OUT" "--level needs a value" "explains a value is required"
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

# --- golem-launch.sh version-skew guard (#230) ------------------------------
# The running helper's plugin version is read from the repo's real
# plugins/workflow/.claude-plugin/plugin.json; tests fabricate the ACTIVE-install
# version via CLAUDE_INSTALLED_PLUGINS to force the equal / differ branches
# without touching the operator's real ~/.claude install.

# The name+version this running golem-launch.sh belongs to (its sibling
# manifest). jq-gated at the call site; here it seeds the fabricated registry.
PLUGIN_MANIFEST="$REPO_ROOT/plugins/workflow/.claude-plugin/plugin.json"

# write_installed_plugins <path> <version> — fabricate an installed_plugins.json
# whose workflow@librarian record carries <version>.
write_installed_plugins() {
    /usr/bin/cat >"$1" <<EOF
{ "plugins": { "workflow@librarian": [ { "version": "$2" } ] } }
EOF
}

# launch with the active install version EQUAL to the running version → the skew
# guard passes silently; the run falls through to its normal missing-worktree
# exit 2 (no worktree in the sandbox). Proves a matched version never blocks.
test_launch_version_match_passes() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (version guard no-ops without jq)"
        return 0
    fi
    local sb ver
    new_sandbox sb
    ver="$(jq -r '.version' "$PLUGIN_MANIFEST")"
    write_installed_plugins "$sb/installed.json" "$ver"
    /usr/bin/printf '{}\n' >"$sb/proj-settings.json"
    /usr/bin/printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_INSTALLED_PLUGINS="$sb/installed.json" \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "matched version passes the guard, reaches missing-worktree exit 2"
    assert_not_contains "$RUN_OUT" "version skew" "no skew message when versions agree"
}

# launch with the active install version DIFFERING from the running version →
# the guard REFUSES with exit 3 and an actionable message naming both versions,
# BEFORE any tmux side effect (worktree absence never reached).
test_launch_version_skew_refuses_exit_3() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (version guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_installed_plugins "$sb/installed.json" "0.0.1-stale"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_INSTALLED_PLUGINS="$sb/installed.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "version skew refuses dispatch with exit 3"
    assert_contains "$RUN_OUT" "version skew" "surfaces the skew"
    assert_contains "$RUN_OUT" "0.0.1-stale" "names the active install version"
    assert_contains "$RUN_OUT" "REFUSING" "refuses rather than dispatching a wedged golem"
}

# GOLEM_SKIP_VERSION_CHECK=1 with a differing version → the refusal downgrades to
# a warning and the run PROCEEDS past the guard (reaching missing-worktree exit
# 2). Proves the escape hatch for legitimate mid-release / worktree dispatch.
test_launch_version_skew_escape_hatch() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (version guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_installed_plugins "$sb/installed.json" "0.0.1-stale"
    /usr/bin/printf '{}\n' >"$sb/proj-settings.json"
    /usr/bin/printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_SKIP_VERSION_CHECK=1 \
            CLAUDE_INSTALLED_PLUGINS="$sb/installed.json" \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "escape hatch proceeds past the guard to missing-worktree exit 2"
    assert_contains "$RUN_OUT" "proceeding anyway" "warns but continues under the escape hatch"
}

# The registry's active record carries the in-band sentinel "version": "unknown"
# (Claude Code writes this for plugins it can't version-pin — most of a real
# installed_plugins.json). It must be treated as undeterminable, NOT as a real
# value that mismatches the running semver → the guard skips, launch reaches its
# normal missing-worktree exit 2. Guards against a false-positive refusal.
test_launch_version_unknown_sentinel_skips() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (version guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_installed_plugins "$sb/installed.json" "unknown"
    /usr/bin/printf '{}\n' >"$sb/proj-settings.json"
    /usr/bin/printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_INSTALLED_PLUGINS="$sb/installed.json" \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "unknown-sentinel version skips the guard, reaches missing-worktree exit 2"
    assert_not_contains "$RUN_OUT" "version skew" "the 'unknown' sentinel is not treated as a real mismatch"
}

# With HOME unset and no CLAUDE_INSTALLED_PLUGINS override, the registry path
# default must degrade to an unreadable path (→ skip), NOT abort the whole script
# with `HOME: unbound variable` under `set -u`. `print` still exits 0.
test_launch_unset_home_does_not_crash() {
    local sb
    new_sandbox sb
    RUN_RC=0
    # Deliberately DO NOT pass HOME or CLAUDE_INSTALLED_PLUGINS.
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=HOME \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$LAUNCH" print 5 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "unset HOME does not crash the guard (print exits 0)"
    assert_contains "$RUN_OUT" "tmux new-session" "print still emits its line with HOME unset"
    assert_not_contains "$RUN_OUT" "unbound variable" "no nounset abort on the HOME default"
}

# No installed-plugins registry (the common host / bare-linux case) → the active
# version is undeterminable, so the guard SKIPS silently. `print` emits its line
# with no skew warning.
test_launch_version_undeterminable_skips() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_INSTALLED_PLUGINS="$sb/no-such-registry.json" \
            "$REAL_BASH" "$LAUNCH" print 5 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "undeterminable version skips the guard, print exits 0"
    assert_contains "$RUN_OUT" "tmux new-session" "print still emits its line"
    assert_not_contains "$RUN_OUT" "version skew" "no skew warning when undeterminable"
}

# --- golem-launch.sh auth-token injection (#244) ----------------------------
# `launch` resolves ANTHROPIC_AUTH_TOKEN and passes it via `tmux -e`. To exercise
# the real dispatch (past the missing-worktree guard) without a real tmux server,
# each case prepends a `$sb/bin` stub `tmux` that logs its argv to
# $sb/tmux-args.log and exits 0, and creates the .worktrees/issue-N dir so the
# `[ -d ]` guard passes. Settings carry all rules so preflight is a silent no-op.
# ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL are explicitly --unset so the suite's
# own environment can never taint the resolution under test.

# plant_tmux_stub <sandbox> — write $sb/bin/tmux that appends its args to
# $sb/tmux-args.log then exits 0 (never spawns a session). Returns the dir to
# prepend to PATH via stdout is unnecessary; callers use "$sb/bin".
plant_tmux_stub() {
    local sb="$1"
    /usr/bin/mkdir -p "$sb/bin"
    /usr/bin/cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv, never start a real session.
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
exit 0
EOF
    /usr/bin/chmod +x "$sb/bin/tmux"
}

# run_launch_auth <sandbox> [extra env KEY=VAL ...] — invoke `launch 7` with the
# tmux stub on PATH, rules-present settings, a real worktree dir, and both
# ANTHROPIC_* vars scrubbed. Extra positional args are prepended as env
# assignments. Captures RUN_RC / RUN_OUT; the tmux argv lands in $sb/tmux-args.log.
run_launch_auth() {
    local sb="$1"
    shift
    plant_tmux_stub "$sb"
    /usr/bin/mkdir -p "$sb/.worktrees/issue-7"
    /usr/bin/printf '{ "permissions": { "allow": ["Bash(tmux new-session:*)", "Bash(tmux ls:*)", "Bash(tmux kill-session:*)"] } }\n' >"$sb/proj-settings.json"
    /usr/bin/printf '{}\n' >"$sb/global-settings.json"
    # --unset=BASH_ENV is load-bearing: in the devcontainer BASH_ENV points at
    # /etc/bash_env, which every non-interactive bash sources — and its
    # /etc/bashrc.d/ scripts (a) hard-RESET $PATH (shadowing the $sb/bin stub
    # tmux with the real one) and (b) re-source the real op-secrets cache
    # (leaking a real ANTHROPIC_AUTH_TOKEN into the child, defeating the token
    # scrub). Both would corrupt these PATH/env-sensitive cases; unsetting it
    # makes the sandbox hermetic (see the devcontainer-bash-env-path-reset note).
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=ANTHROPIC_AUTH_TOKEN --unset=ANTHROPIC_BASE_URL \
            --unset=OP_ANTHROPIC_AUTH_TOKEN_REF \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$sb/tmux-args.log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$@" \
            "$REAL_BASH" "$LAUNCH" launch 7 2>&1)" || RUN_RC=$?
}

# A readable op-secrets cache with a token + base URL → both are injected into
# the tmux `-e` args, and the token is NEVER echoed to stdout/stderr.
test_launch_auth_cache_injects_token() {
    local sb log
    new_sandbox sb
    /usr/bin/printf 'export ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244\nexport ANTHROPIC_BASE_URL=https://bifrost.example\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache"
    assert_exit 0 "$RUN_RC" "launch with a cache token dispatches (exit 0)"
    log="$(/usr/bin/cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244" "the resolved token is injected via tmux -e"
    assert_contains "$log" "ANTHROPIC_BASE_URL=https://bifrost.example" "the cache base URL rides along"
    assert_not_contains "$RUN_OUT" "sk-secret-tok-244" "the token is NEVER echoed to stdout/stderr"
}

# No cache, no op, no ref → no injection, no warning, exit 0. The dispatch is
# byte-identical to pre-#244 (only GOLEM_ID in the env args).
test_launch_auth_no_source_no_injection() {
    local sb log
    new_sandbox sb
    # Point the cache default at a nonexistent path so /dev/shm is never read.
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache"
    assert_exit 0 "$RUN_RC" "launch with no token source dispatches (exit 0)"
    log="$(/usr/bin/cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_not_contains "$log" "ANTHROPIC_AUTH_TOKEN" "no token is injected when none resolves"
    assert_not_contains "$RUN_OUT" "WARNING" "no warning when there is no cache marker"
}

# `op read` hangs → the time-bounded wrapper kills it and dispatch still
# completes. A fake `op` that sleeps 60s stands in; OP_ANTHROPIC_AUTH_TOKEN_REF is
# set with no cache/env token, so resolution reaches the bounded op arm. Skipped
# where neither timeout nor gtimeout exists (the arm no-ops there by design).
test_launch_auth_op_hang_is_bounded() {
    if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
        skip_test "neither timeout nor gtimeout available (bounded-op arm is a no-op)"
        return 0
    fi
    local sb log
    new_sandbox sb
    /usr/bin/cat >"$sb/bin-op" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
    # op must be on the same PATH dir as the tmux stub; plant it there after
    # run_launch_auth creates bin/ — so pre-create bin/ and the op stub, then run.
    /usr/bin/mkdir -p "$sb/bin"
    /usr/bin/cp "$sb/bin-op" "$sb/bin/op"
    /usr/bin/chmod +x "$sb/bin/op"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        OP_ANTHROPIC_AUTH_TOKEN_REF="op://vault/anthropic/token"
    assert_exit 0 "$RUN_RC" "a hanging op read is bounded — dispatch still completes (exit 0)"
    log="$(/usr/bin/cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_not_contains "$log" "ANTHROPIC_AUTH_TOKEN" "a timed-out op read injects no token"
}

# A cache marker exists but yields no token → warn (don't fail), still dispatch,
# inject nothing. Exercises the elif warning arm.
test_launch_auth_cache_marker_no_token_warns() {
    local sb log
    new_sandbox sb
    # Cache is readable but exports something OTHER than the token.
    /usr/bin/printf 'export SOME_OTHER_SECRET=1\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache"
    assert_exit 0 "$RUN_RC" "an empty cache still dispatches (exit 0)"
    assert_contains "$RUN_OUT" "WARNING" "warns when a cache marker is present but no token resolves"
    log="$(/usr/bin/cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_not_contains "$log" "ANTHROPIC_AUTH_TOKEN" "no empty token is injected"
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

# Regression (#228): the script must invoke coreutils/git via the `command`
# builtin (PATH-resolved, alias-proof), NOT hardcoded /usr/bin/* paths — those
# die with exit 127 on hosts where the tools live elsewhere (Nix/Homebrew,
# external-volume checkouts, non-standard macOS), AFTER the worktree already
# exists. Static guard: no /usr/bin/<tool> beyond the #!/usr/bin/env shebang.
test_worktree_new_no_hardcoded_usr_bin() {
    local hits
    hits="$(command grep -nE '/usr/bin/(mkdir|cp|dirname|git|grep)' "$WT_NEW" || true)"
    assert_output_empty "$hits" \
        "worktree-new.sh invokes tools via \`command\`, not hardcoded /usr/bin/*"
}

# Regression (#228): the local-file copy step (the arm that failed at exit 127)
# actually copies GOLEM_WORKTREE_LOCAL_FILES into the fresh worktree. The shared
# run_in helper pins GOLEM_WORKTREE_LOCAL_FILES="" so it never exercises this;
# override it here with a direct env invocation mirroring run_in's scrub/pin.
test_worktree_new_copies_local_files() {
    local sb
    new_sandbox sb
    /usr/bin/printf 'SECRET=1\n' >"$sb/.env"
    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES=".env" \
            "$REAL_BASH" "$WT_NEW" 35 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-new exits 0 when copying a local file"
    assert_file_exists "$sb/.worktrees/issue-35/.env" \
        "the machine-local .env was copied into the worktree"
    assert_contains "$out" "copied .env" "reports the .env copy"
}

# Regression (#325): `git worktree add` does NOT populate submodules, so in a
# consuming repo where a submodule ships the pre-commit fixer scripts the root
# lefthook hook calls, the fresh worktree can't commit with the hook enabled.
# worktree-new.sh must run `git submodule update --init --recursive` after the
# add so those scripts resolve inside the worktree. Build a super+submodule
# fixture (shared _make_super_with_submodule) whose submodule carries a marker
# bin/fix.sh, run worktree-new from the superproject, and assert the marker is
# present in the worktree's submodule checkout. Skips cleanly if `git submodule
# add` is unavailable (old git / file protocol disallowed).
test_worktree_new_inits_submodules() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1
    run_in "$super" "$WT_NEW" 36
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a submodule present"
    assert_file_exists "$super/.worktrees/issue-36/mod/bin/fix.sh" \
        "the submodule's hook script is populated in the fresh worktree"
}

# Regression (#338, closing the loop on #324/PR #335): the end-to-end worktree
# PLACEMENT when worktree-new.sh is invoked from INSIDE a submodule working tree.
# The #324 bug: inside a submodule, `git rev-parse --git-common-dir` resolves to
# <super>/.git/modules/<name>, so a repo_root() that trusted the common dir
# returned that git-internal path, and worktree-new.sh — which cd's into
# repo_root() before `git worktree add` — landed the worktree at
# <super>/.git/modules/<name>/.worktrees/issue-N instead of
# <super>/.worktrees/issue-N. #324's --show-superproject-working-tree probe fixed
# repo_root(), and test_config_repo_root_submodule_superproject covers that at
# the repo_root() UNIT level — but no test drove the WHOLE script from inside a
# submodule to demonstrate the reported placement symptom is actually gone. This
# is that test: distinct from test_worktree_new_inits_submodules (#325), which
# runs from the SUPERPROJECT root and asserts submodule POPULATION, not placement.
# Run worktree-new from <super>/mod and assert the worktree lands at the
# superproject's .worktrees/ (carrying the superproject's tracked app.txt, so it
# forked <super> and not the submodule) and that NOTHING landed under
# .git/modules (the exact #324 bug path). Not via run_in — that cd's to the
# superproject root; this must invoke from the submodule subdir, so it mirrors
# run_in's scrub/pins directly (like test_worktree_new_copies_local_files) with
# `cd "$super/mod"`. Skips cleanly if `git submodule add` is unavailable.
test_worktree_new_from_submodule_placement() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1

    # Invoke worktree-new from INSIDE the submodule working tree (<super>/mod),
    # not the superproject root — the #324 reproduction path. Mirror run_in's
    # scrub/pins; HOME="$super" so $super/.gitconfig's protocol.file.allow is
    # honored and the seed-trust write stays sandboxed. Use a fully-local
    # out/rc pair (not the shared RUN_OUT/RUN_RC globals) since the invocation
    # bypasses run_in — matching the other hand-rolled tests in this file
    # (test_worktree_new_copies_local_files, ..._scrubs_tainted_git_env_for_mutations).
    local out rc=0
    out="$(cd "$super/mod" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$super" \
            TMUX= TMUX_TMPDIR="$super/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 44 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-new exits 0 when run from inside a submodule"
    assert_file_exists "$super/.worktrees/issue-44/app.txt" \
        "the worktree lands at <super>/.worktrees/issue-44 with the superproject's files"
    assert_true '[ ! -e "'"$super"'/.git/modules/mod/.worktrees" ]' \
        "nothing landed under <super>/.git/modules (the #324 bug path)"
}

# Regression (#328): worktree-new.sh runs its OWN git mutations (worktree add
# -b …) after repo_root(). #279 scrubbed only repo_root()'s rev-parse subshell,
# so a tainted GIT_DIR/GIT_COMMON_DIR forwarded from a git hook still redirected
# the caller's `git worktree add`: the worktree dir landed in the right repo but
# the new BRANCH REF landed in the OUTER/tainted repo — a split-brain (verified
# dynamically). The process-wide scrub added after `. config.sh` re-anchors all
# subsequent git calls to cwd. Invoke worktree-new UNDER taint (not via run_in,
# which the harness already scrubs) with GIT_DIR/GIT_COMMON_DIR pointed at a
# separate outer repo, and assert the branch lands in the SANDBOX and is ABSENT
# from outer. Mirrors test_config_repo_root_scrubs_tainted_git_env's taint setup.
test_worktree_new_scrubs_tainted_git_env_for_mutations() {
    local sb outer
    new_sandbox sb
    outer="$(/usr/bin/mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1

    # Run worktree-new from the sandbox with the git env TAINTED toward outer.
    # No GIT_SCRUB on this invocation — the taint is the whole point; the script's
    # own #328 scrub must clear it. Pin GOLEM_* / HOME like run_in does otherwise.
    local out rc=0
    out="$(cd "$sb" &&
        GIT_DIR="$outer/.git" GIT_COMMON_DIR="$outer/.git" \
            HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 78 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-new exits 0 despite a tainted git environment"

    local sb_branch outer_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" branch --list "feature/issue-78")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" branch --list "feature/issue-78")"
    assert_not_empty "$sb_branch" \
        "the branch ref lands in the SANDBOX repo, not the tainted GIT_DIR target"
    assert_output_empty "$outer_branch" \
        "no branch ref leaked into the outer/tainted repo (no split-brain)"
}

# --- config.sh repo_root() ----------------------------------------------------

# Regression (#278): repo_root() must resolve its tools via PATH, not hardcoded
# /usr/bin/*. Off the standard layout (git elsewhere) /usr/bin/git exits 127,
# gets swallowed by `|| true`, and repo_root silently returns empty — tripping
# every caller's "not a repo" branch inside a valid repo. Static guard mirroring
# test_worktree_new_no_hardcoded_usr_bin (#228).
test_config_repo_root_no_hardcoded_usr_bin() {
    local body hits
    # Scope to repo_root()'s body (the header comment legitimately shows a
    # /usr/bin/dirname sourcing example) and drop comment lines, so only real
    # tool invocations are checked.
    body="$(/usr/bin/awk '/^repo_root\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$CONFIG")"
    hits="$(command printf '%s\n' "$body" |
        command grep -vE '^[[:space:]]*#' |
        command grep -nE '/usr/bin/(git|pwd|dirname)' || true)"
    assert_output_empty "$hits" \
        "config.sh repo_root invokes git/pwd/dirname via \`command\`/bash, not hardcoded /usr/bin/*"
}

# Functional regression (#278): with git resolvable via PATH but ABSENT at
# /usr/bin/git, repo_root() still resolves the repo root. A shim dir is prepended
# to PATH holding a `git` wrapper; PATH is then stripped to ONLY that shim, so a
# hardcoded /usr/bin/git would exit 127 and repo_root would return empty. Proves
# the fix honors PATH. Skips cleanly if the real git can't be located to wrap.
test_config_repo_root_honors_path() {
    local sb real_git
    new_sandbox sb
    real_git="$(command -v git || true)"
    if [ -z "$real_git" ]; then
        skip_test "git not on PATH — cannot build the shim wrapper"
        return 0
    fi
    # A `git` symlink to the real binary in a dir that is the ONLY entry on PATH
    # (no /usr/bin). A symlink — not a `#!/usr/bin/env bash` wrapper — because
    # PATH is stripped to just this dir, so a wrapper's interpreter (`bash`)
    # would be unresolvable; the symlink needs no interpreter. repo_root's other
    # tools (pwd/echo) are bash builtins, so git is the only PATH dependency.
    local shim="$sb/shim"
    /usr/bin/mkdir -p "$shim"
    /usr/bin/ln -s "$real_git" "$shim/git"

    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            PATH="$shim" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 with git resolved via PATH only"
    # repo_root prints the sandbox root (the git common dir's parent). git
    # canonicalizes symlinks in that path (e.g. a symlinked /tmp on the CI
    # runner), so compare realpaths, not the raw mktemp path.
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root resolves the repo root via PATH, not /usr/bin/git"
}

# Edge case (#278): repo_root()'s pure-bash dirname must match GNU `dirname` for
# a single-slash git-common-dir (a bare repo rooted at "/" resolves to "/.git").
# Stripping "/.git" via ${common_dir%/*} yields "" — the fix falls back to "/",
# as `dirname /.git` does; without the ${parent:-/} guard repo_root would print
# an empty root at exit 0. A shim `git` (bin dir first on PATH) forces the
# --git-common-dir output to /.git; bash stays on PATH so the script shim runs.
test_config_repo_root_dirname_root_edge() {
    local sb bin
    new_sandbox sb
    bin="$sb/bin"
    /usr/bin/mkdir -p "$bin"
    {
        /usr/bin/printf '#!/usr/bin/env bash\n'
        # Only intercept the common-dir probe; anything else is unexpected here.
        /usr/bin/printf 'case "$*" in\n'
        /usr/bin/printf '  *--git-common-dir*) command echo "/.git" ;;\n'
        /usr/bin/printf '  *) exit 1 ;;\n'
        /usr/bin/printf 'esac\n'
    } >"$bin/git"
    /usr/bin/chmod +x "$bin/git"

    # Unset BASH_ENV too: /etc/bash_env re-adds the real PATH on the devcontainer
    # for non-interactive bash, which would let the real git outrank the shim.
    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            PATH="$bin:$PATH" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 for a filesystem-root repo"
    assert_equals "/" "$out" \
        "repo_root returns '/' for a /.git common dir, matching GNU dirname"
}

# Edge case (#278): when git reports a RELATIVE --git-common-dir, repo_root()
# prepends `command pwd` to absolutize it before taking the dirname. A shim git
# emits the relative ".git"; repo_root should return the sandbox dir (pwd + /.git
# → parent = pwd). Exercises the `*) common_dir="$(command pwd)/$common_dir"` arm
# that this diff changed from /usr/bin/pwd.
test_config_repo_root_relative_common_dir() {
    local sb bin
    new_sandbox sb
    bin="$sb/bin"
    /usr/bin/mkdir -p "$bin"
    {
        /usr/bin/printf '#!/usr/bin/env bash\n'
        /usr/bin/printf 'case "$*" in\n'
        /usr/bin/printf '  *--git-common-dir*) command echo ".git" ;;\n'
        /usr/bin/printf '  *) exit 1 ;;\n'
        /usr/bin/printf 'esac\n'
    } >"$bin/git"
    /usr/bin/chmod +x "$bin/git"

    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            PATH="$bin:$PATH" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 for a relative common dir"
    # pwd/.git → dirname → pwd. Compare realpaths (symlinked /tmp on CI).
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root absolutizes a relative --git-common-dir via command pwd"
}

# Edge case (#336): when git reports a RELATIVE
# --show-superproject-working-tree, repo_root() prepends `command pwd` to
# absolutize it before returning (the submodule super_root arm added in #324).
# --path-format=absolute makes real git always print an absolute path, so the
# #324 happy-path test never executes this fallback; a shim git emitting a
# relative "sup" forces it. repo_root should return pwd/sup (super_root is
# non-empty, so it returns early and never reaches the common-dir probe — one
# shim branch suffices). Mirrors test_config_repo_root_relative_common_dir.
test_config_repo_root_relative_super_root() {
    local sb bin
    new_sandbox sb
    bin="$sb/bin"
    /usr/bin/mkdir -p "$bin"
    # A real relative target so the realpath compare proves pwd was prepended.
    /usr/bin/mkdir -p "$sb/sup"
    {
        /usr/bin/printf '#!/usr/bin/env bash\n'
        /usr/bin/printf 'case "$*" in\n'
        /usr/bin/printf '  *--show-superproject-working-tree*) command echo "sup" ;;\n'
        /usr/bin/printf '  *) exit 1 ;;\n'
        /usr/bin/printf 'esac\n'
    } >"$bin/git"
    /usr/bin/chmod +x "$bin/git"

    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            PATH="$bin:$PATH" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 for a relative super_root"
    # pwd/sup absolutized. Compare realpaths (symlinked /tmp on CI).
    local sup_real out_real
    sup_real="$(cd "$sb/sup" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sup_real" "$out_real" \
        "repo_root absolutizes a relative --show-superproject-working-tree via command pwd"
}

# Security regression (#279): repo_root() scrubs git's hook-exported environment
# for its own rev-parse, so a tainted GIT_DIR/GIT_COMMON_DIR (as leaks in from a
# git hook or a wrapper forwarding the environment) cannot pin the resolved root
# to an OUTER repo. Direct unit test of repo_root() itself — decoupled from any
# caller — mirroring the #278 cases above: source config.sh in the sandbox with
# GIT_DIR/GIT_COMMON_DIR pointed at a SECOND real repo and assert repo_root()
# still prints the sandbox root, not the tainted one. Deliberately does NOT put
# GIT_DIR in GIT_SCRUB's unset list for this invocation — the taint must reach
# repo_root() for the test to mean anything.
test_config_repo_root_scrubs_tainted_git_env() {
    local sb outer
    new_sandbox sb
    outer="$(/usr/bin/mktemp -d "$WORKDIR/outer.XXXXXX")"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" init -q 2>/dev/null || return 1

    local out rc=0
    out="$(cd "$sb" &&
        GIT_DIR="$outer/.git" GIT_COMMON_DIR="$outer/.git" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 despite a tainted git environment"
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root resolves the sandbox root, not the tainted GIT_DIR/GIT_COMMON_DIR target"
}

# Regression (#328): the #279 scrub used a bare `unset`, which SILENTLY NO-OPS on
# a READONLY GIT_* var (`declare -rx GIT_DIR=…`) — the unset fails to stderr but
# the command-substitution subshell continues (no inherit_errexit), so
# `git rev-parse` still reads the tainted value and repo_root() returns the OUTER
# repo. _repo_root_git (config.sh) closes this: plain unset first (dependency-
# free common path), falling back to `env -u` (unexports regardless of the
# readonly attribute) when unset fails. Direct repo_root() unit test with a
# readonly-exported taint, asserting the sandbox root still resolves. Mirrors
# test_config_repo_root_scrubs_tainted_git_env but with `declare -rx`.
test_config_repo_root_scrubs_readonly_tainted_git_env() {
    local sb outer
    new_sandbox sb
    outer="$(/usr/bin/mktemp -d "$WORKDIR/outer.XXXXXX")"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" init -q 2>/dev/null || return 1

    # declare -rx makes GIT_DIR/GIT_COMMON_DIR readonly AND exported inside the
    # child bash before sourcing config.sh, so a bare `unset` in repo_root's
    # subshell cannot clear them — the env -u fallback must.
    local out rc=0
    out="$(cd "$sb" &&
        "$REAL_BASH" -c 'declare -rx GIT_DIR="$2/.git"; declare -rx GIT_COMMON_DIR="$2/.git"; . "$1"; repo_root' \
            _ "$CONFIG" "$outer" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 despite a readonly tainted git environment"
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root resolves the sandbox root despite a readonly GIT_DIR/GIT_COMMON_DIR taint"
}

# Regression (#324): inside a git SUBMODULE working tree, --git-common-dir
# resolves to <super>/.git/modules/<name>, so the common-dir logic alone would
# return <super>/.git/modules — a git-internal path — and worktree-new.sh would
# land worktrees under .git/modules/.worktrees/issue-N. repo_root() must instead
# return the SUPERPROJECT working-tree root. Build a real super+submodule fixture
# and assert repo_root, invoked from inside the submodule tree, returns <super>
# (not <super>/.git/modules). Skips cleanly if `submodule add` is unavailable
# (old git / file protocol disallowed).
test_config_repo_root_submodule_superproject() {
    local sub super name rc=0
    sub="$(/usr/bin/mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(/usr/bin/mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule. `protocol.file.allow=always`
    # is required for a local-path submodule add on modern git.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1

    # Invoke repo_root from INSIDE the submodule working tree.
    local out
    out="$(cd "$super/$name" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 inside a submodule working tree"
    # Compare realpaths (symlinked /tmp on CI runners).
    local super_real out_real
    super_real="$(cd "$super" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$super_real" "$out_real" \
        "repo_root returns the superproject root, not <super>/.git/modules"
}

# Security regression (#337, closing a coverage gap flagged in the #335 pre-PR
# review): the super_root probe (#324) runs its
# `rev-parse --show-superproject-working-tree` through _repo_root_git, so a
# tainted GIT_DIR/GIT_COMMON_DIR (from a git hook or an env-forwarding wrapper)
# cannot pin the resolved root to an OUTER repo — the same #279 hook-safety
# guarantee already proven for the common-dir probe. But
# test_config_repo_root_scrubs_tainted_git_env exercises only a PLAIN
# (non-submodule) sandbox, where --show-superproject-working-tree is always
# empty, so the super_root arm's scrub path is never taken under taint. This test
# closes that hole: build the same real super+submodule fixture as the #324 test,
# then invoke repo_root from INSIDE the submodule working tree under taint. On an
# unscrubbed probe the tainted GIT_WORK_TREE makes git treat the OUTER repo as
# the work tree, so --show-superproject-working-tree returns EMPTY and repo_root
# falls through to the common-dir arm — which the same taint pins to
# <super>/.git/modules, the exact #324 bug value. With the scrub intact repo_root
# returns the true superproject root instead. The taint must include
# GIT_WORK_TREE, not just GIT_DIR/GIT_COMMON_DIR: from a submodule working tree
# git still detects the superproject from cwd under a GIT_DIR/GIT_COMMON_DIR-only
# taint, so GIT_WORK_TREE is what actually diverges the scrubbed and unscrubbed
# probes (both are on the #279 scrub list, as a real git hook exports them
# together). Deliberately does NOT wrap the invocation in
# `env "${GIT_SCRUB[@]/#/--unset=}"` (unlike the #324 test) — the taint must
# reach repo_root() for the assertion to mean anything (same rationale as
# test_config_repo_root_scrubs_tainted_git_env). Skips cleanly if
# `git submodule add` is unavailable (old git / file protocol disallowed).
test_config_repo_root_submodule_superproject_scrubs_tainted_git_env() {
    local sub super outer name rc=0
    sub="$(/usr/bin/mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(/usr/bin/mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    outer="$(/usr/bin/mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1
    # Third, unrelated outer repo whose .git the taint points at.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" init -q 2>/dev/null || return 1

    # Invoke repo_root from INSIDE the submodule working tree UNDER TAINT: the
    # invocation is NOT scrubbed (no `env --unset`), and GIT_DIR/GIT_WORK_TREE/
    # GIT_COMMON_DIR point at the outer repo, so the taint reaches repo_root().
    # GIT_WORK_TREE is essential — it is what makes an unscrubbed super_root probe
    # miss the submodule and fall through to the tainted common-dir arm.
    local out
    out="$(cd "$super/$name" &&
        GIT_DIR="$outer/.git" GIT_WORK_TREE="$outer" GIT_COMMON_DIR="$outer/.git" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 inside a tainted submodule working tree"
    # Compare realpaths (symlinked /tmp on CI runners).
    local super_real out_real
    super_real="$(cd "$super" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$super_real" "$out_real" \
        "repo_root returns the superproject root, not the tainted outer repo"
}

# Regression (#363, closing the last cell of the readonly-taint × probe-arm 2×2
# matrix). Two independent hardening dimensions cross here: the taint KIND —
# plain exported (a bare `unset` clears it) vs READONLY exported
# (`declare -rx GIT_DIR=…`, which a bare `unset` SILENTLY no-ops, #328) — and the
# probe ARM — the common-dir arm (plain sandbox) vs the super_root arm
# (`--show-superproject-working-tree`, only taken inside a submodule, #324/#337).
# Three cells are already covered:
#   test_config_repo_root_scrubs_tainted_git_env                 (plain × common-dir, #279)
#   test_config_repo_root_scrubs_readonly_tainted_git_env        (readonly × common-dir, #328)
#   test_config_repo_root_submodule_superproject_scrubs_tainted_git_env
#                                                                 (plain × super_root, #337)
# This closes the fourth: readonly × super_root. Both probes route through the
# same _repo_root_git (config.sh), whose `env -u` fallback unexports a readonly
# GIT_* regardless of the attribute, so this is NOT a functional blind spot
# today — but there is no direct regression proving that fallback also protects
# the super_root probe. If a future change ever forked _repo_root_git per-probe
# or added probe-specific scrub logic, a readonly taint against the submodule
# fixture would go unverified; this test is the guard.
#
# Builds the same real super+submodule+outer fixture as the #337 test, then
# invokes repo_root from INSIDE the submodule working tree under a taint passed as
# `declare -rx` (readonly+exported) inside the child bash — so the bare `unset` in
# _repo_root_git FAILS and the `env -u` fallback is what must clear the taint for
# the super_root probe. GIT_WORK_TREE is load-bearing (same rationale as the #337
# test): from a submodule working tree git still detects the superproject from cwd
# under a GIT_DIR/GIT_COMMON_DIR-only taint, so GIT_WORK_TREE is what makes an
# unscrubbed super_root probe miss the submodule and fall through to the tainted
# common-dir arm (which the same taint pins to <super>/.git/modules, the #324
# bug). The invocation is deliberately NOT wrapped in `env --unset` — the taint
# must reach repo_root() for the assertion to mean anything. Skips cleanly if
# `git submodule add` is unavailable (old git / file protocol disallowed).
test_config_repo_root_submodule_superproject_scrubs_readonly_tainted_git_env() {
    local sub super outer name rc=0
    sub="$(/usr/bin/mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(/usr/bin/mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    outer="$(/usr/bin/mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1
    # Third, unrelated outer repo whose .git the taint points at.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" init -q 2>/dev/null || return 1

    # Invoke repo_root from INSIDE the submodule working tree UNDER a READONLY
    # taint: GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR are `declare -rx` (readonly +
    # exported) inside the child bash before sourcing config.sh, so repo_root's
    # bare `unset` cannot clear them — the `env -u` fallback in _repo_root_git
    # must, on the super_root probe. The invocation is NOT scrubbed (no
    # `env --unset`), so the taint reaches repo_root(). GIT_WORK_TREE is what
    # diverges the scrubbed and unscrubbed super_root probes.
    local out
    out="$(cd "$super/$name" &&
        "$REAL_BASH" -c 'declare -rx GIT_DIR="$2/.git"; declare -rx GIT_WORK_TREE="$2"; declare -rx GIT_COMMON_DIR="$2/.git"; . "$1"; repo_root' \
            _ "$CONFIG" "$outer" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 inside a readonly-tainted submodule working tree"
    # Compare realpaths (symlinked /tmp on CI runners).
    local super_real out_real
    super_real="$(cd "$super" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$super_real" "$out_real" \
        "repo_root returns the superproject root despite a readonly super_root taint"
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

# Regression (#328): worktree-rm.sh runs its OWN destructive git mutations
# (worktree remove / branch -D / config --unset core.worktree / worktree prune)
# after repo_root(). Like worktree-new, a tainted GIT_DIR/GIT_COMMON_DIR
# forwarded from a git hook would redirect those to an OUTER repo — force-
# deleting the wrong repo's branch or corrupting its core.worktree. The
# process-wide scrub added after `. config.sh` re-anchors them to cwd. Seed the
# sandbox with a worktree+branch via WT_NEW under run_in (safe — scrubbed), then
# invoke WT_RM directly UNDER taint (bypassing run_in's scrub) with
# GIT_DIR/GIT_COMMON_DIR pointed at a separate outer repo that carries an
# identically-named branch, and assert the SANDBOX's worktree+branch are removed
# while the outer repo's same-named branch is untouched (no cross-repo deletion).
test_worktree_rm_scrubs_tainted_git_env_for_mutations() {
    local sb outer
    new_sandbox sb
    # Create the sandbox worktree+branch to remove (scrubbed path — safe).
    run_in "$sb" "$WT_NEW" 79
    assert_exit 0 "$RUN_RC" "worktree-new seeds the sandbox worktree+branch"

    # A separate outer repo carrying an identically-named branch. If worktree-rm
    # ran its `git branch -D` in the tainted env, it would delete THIS branch.
    outer="$(/usr/bin/mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" branch "feature/issue-79" 2>/dev/null || return 1

    # Run worktree-rm from the sandbox with the git env TAINTED toward outer.
    # No GIT_SCRUB on this invocation — the taint is the point; the script's own
    # #328 scrub must clear it. Pin GOLEM_* / HOME like run_in does otherwise.
    local out rc=0
    out="$(cd "$sb" &&
        GIT_DIR="$outer/.git" GIT_COMMON_DIR="$outer/.git" \
            HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 79 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-rm exits 0 despite a tainted git environment"

    local sb_branch outer_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" branch --list "feature/issue-79")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$outer" branch --list "feature/issue-79")"
    assert_output_empty "$sb_branch" \
        "the SANDBOX branch was deleted (the mutation targeted the right repo)"
    assert_not_empty "$outer_branch" \
        "the outer/tainted repo's same-named branch is untouched (no cross-repo delete)"
}

# _make_super_with_submodule <out-super-var>
# Builds a superproject sandbox (git repo + one commit + .worktrees/.status +
# .tmux + {} .claude.json + a $super/.gitconfig enabling file:// submodules) that
# embeds an inner submodule "mod" carrying a marker bin/fix.sh, and assigns the
# superproject path to the caller's named variable. Returns 1 on any git failure
# and, distinctly, prints a SKIP sentinel + returns 2 when `git submodule add` is
# unavailable (old git / file protocol disallowed) so the caller can skip_test.
# Shared by the worktree-new populate test and the worktree-rm teardown tests.
_make_super_with_submodule() {
    # Internal locals are `inner`/`sup`, deliberately NOT the caller's out-var
    # name (`super`): `printf -v "$__out"` at the end resolves against the current
    # scope, so an internal `super` would shadow and overwrite the caller's local
    # instead of exporting the path back (the pitfall new_sandbox sidesteps with
    # its `dir`).
    local __out="$1" inner sup
    inner="$(/usr/bin/mktemp -d "$WORKDIR/smsub.XXXXXX")" || return 1
    sup="$(/usr/bin/mktemp -d "$WORKDIR/smsuper.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$inner" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$inner" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$inner" config user.name "Test"
    /usr/bin/mkdir -p "$inner/bin"
    /usr/bin/printf '#!/bin/sh\n' >"$inner/bin/fix.sh"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$inner" add bin/fix.sh 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$inner" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sup" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sup" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sup" config user.name "Test"
    /usr/bin/printf 'main\n' >"$sup/app.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sup" add app.txt 2>/dev/null
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sup" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$inner" mod 2>/dev/null; then
        return 2
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sup" -c commit.gpgsign=false commit -qm "add mod" 2>/dev/null || return 1
    /usr/bin/mkdir -p "$sup/.worktrees/.status" "$sup/.tmux"
    /usr/bin/printf '{}\n' >"$sup/.claude.json"
    # A submodule clone reads the invoking user's GLOBAL config (not the
    # superproject's repo-local config), and run_in pins HOME=$dir, so put
    # protocol.file.allow here to let the file:// submodule clone succeed.
    /usr/bin/printf '[protocol "file"]\n\tallow = always\n' >"$sup/.gitconfig"
    printf -v "$__out" '%s' "$sup"
    return 0
}

# Regression (#325): worktree-new.sh now populates submodules, and
# `git worktree remove` (without --force) REFUSES any worktree containing a
# populated submodule ("working trees containing submodules cannot be moved or
# removed", exit 128) even when the submodule is clean. worktree-rm.sh must
# detect that the worktree is otherwise-clean and force past it, so ordinary
# teardown still succeeds. Round-trip a submodule-bearing worktree and assert rm
# removes it (exit 0) and reports forcing past clean submodules.
test_worktree_rm_forces_past_clean_submodule() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1
    run_in "$super" "$WT_NEW" 40
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a submodule present"
    assert_file_exists "$super/.worktrees/issue-40/mod/bin/fix.sh" \
        "the submodule is populated in the fresh worktree"
    run_in "$super" "$WT_RM" 40
    assert_exit 0 "$RUN_RC" "worktree-rm removes a clean submodule-bearing worktree"
    assert_contains "$RUN_OUT" "removed worktree" "reports the worktree removal"
    assert_true "[ ! -e '$super/.worktrees/issue-40' ]" \
        "the worktree directory is gone after rm"
}

# Regression (#325): the force-past-submodule path must NOT clobber real
# uncommitted work. When a worktree has BOTH a populated submodule AND a dirty
# REGULAR file, git still prints the submodule message, so a naive `--force`
# would silently discard the user's changes. worktree-rm.sh gates the force on
# `status --ignore-submodules=all` being empty, so a dirty regular file makes it
# REFUSE (exit 1) instead of forcing. Dirty a tracked file in the worktree and
# assert rm refuses and preserves the file.
test_worktree_rm_refuses_dirty_regular_file_with_submodule() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1
    run_in "$super" "$WT_NEW" 41
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a submodule present"
    # Dirty a tracked, non-submodule file in the worktree.
    /usr/bin/printf 'UNCOMMITTED USER WORK\n' >>"$super/.worktrees/issue-41/app.txt"
    run_in "$super" "$WT_RM" 41
    assert_exit 1 "$RUN_RC" "worktree-rm refuses a worktree with dirty regular files"
    assert_contains "$RUN_OUT" "uncommitted changes" "explains there are uncommitted changes"
    assert_file_contains "$super/.worktrees/issue-41/app.txt" "UNCOMMITTED USER WORK" \
        "the uncommitted work is preserved, not force-discarded"
}

# A stale core.worktree in the MAIN config pointing at a non-existent path is
# repaired: unset + rev-parse --is-inside-work-tree true again (#258).
test_worktree_rm_repairs_stale_core_worktree() {
    local sb
    new_sandbox sb
    # Simulate the corruption an interrupted `git worktree remove --force`
    # leaves behind: core.worktree pointing at a now-deleted worktree path.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" config core.worktree "$sb/.worktrees/issue-99"
    run_in "$sb" "$WT_RM" 99
    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 while repairing a stale core.worktree"
    assert_contains "$RUN_OUT" "repaired stale core.worktree" "reports the repair"
    local val inside
    val="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" config --get core.worktree || true)"
    assert_equals "" "$val" "the stale core.worktree is unset after repair"
    inside="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" rev-parse --is-inside-work-tree 2>/dev/null || true)"
    assert_equals "true" "$inside" "the main checkout is a work tree again after repair"
}

# A core.worktree pointing at an EXISTING path is left untouched — no
# false-positive repair (#258).
test_worktree_rm_preserves_valid_core_worktree() {
    local sb
    new_sandbox sb
    # Point core.worktree at a path that exists on disk (the sandbox itself).
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" config core.worktree "$sb"
    run_in "$sb" "$WT_RM" 99
    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 with a valid core.worktree"
    local val
    val="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$sb" config --get core.worktree || true)"
    assert_equals "$sb" "$val" "a valid, existing core.worktree is left untouched"
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

# --- golem-status.sh --watch (level-scaled status sweep, #304) ---------------

# run_in_watch <sandbox> <timeout-secs> [env KEY=VAL ...] -- <args...>
# Like run_in but for the never-terminating --watch loop: runs golem-status.sh
# under `timeout` (SIGTERM after N s) so the poll loop is bounded, with optional
# extra env (e.g. GOLEM_SWEEP_INTERVAL) prepended. `timeout` exit 124 (killed)
# is normalized to 0 — a bounded watch that had to be killed is the SUCCESS case
# here. Captures combined output in RUN_OUT, the (normalized) code in RUN_RC.
run_in_watch() {
    local dir="$1" secs="$2"
    shift 2
    local extra_env=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        extra_env+=("$1")
        shift
    done
    shift # drop the `--`
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "${extra_env[@]}" \
            /usr/bin/timeout "$secs" "$REAL_BASH" "$STATUS" "$@" 2>&1)" || RUN_RC=$?
    [ "$RUN_RC" = "124" ] && RUN_RC=0
}

# An unknown argument is a fail-loud usage error (exit 2), not a silent no-op.
test_status_unknown_arg_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$STATUS" --bogus
    assert_exit 2 "$RUN_RC" "golem-status --bogus exits 2"
    assert_contains "$RUN_OUT" "unknown argument" "names the bad argument"
}

# --level out of 1-4 range is rejected before any loop starts.
test_status_watch_bad_level_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$STATUS" --watch --level 9
    assert_exit 2 "$RUN_RC" "golem-status --watch --level 9 exits 2"
    assert_contains "$RUN_OUT" "level must be 1-4" "reports the out-of-range level"
}

# A non-integer --interval is rejected up front.
test_status_watch_bad_interval_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$STATUS" --watch --interval abc
    assert_exit 2 "$RUN_RC" "golem-status --watch --interval abc exits 2"
    assert_contains "$RUN_OUT" "positive integer" "reports the bad interval"
}

# --watch re-renders on the interval: a planted row appears more than once within
# the bounded window. GOLEM_SWEEP_INTERVAL=1 keeps the test fast and proves the
# env override beats the level default (L3 would otherwise wait 480s).
test_status_watch_loops_with_env_override() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        skip_test "timeout not available (cannot bound the --watch loop)"
        return 0
    fi
    local sb
    new_sandbox sb
    /usr/bin/cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    run_in_watch "$sb" 3 GOLEM_SWEEP_INTERVAL=1 -- --watch --level 3
    assert_exit 0 "$RUN_RC" "bounded --watch loop exits cleanly (killed by timeout)"
    assert_contains "$RUN_OUT" "Status sweep every 1s (level 3)" \
        "header shows the env-override interval, not the L3 default"
    # The planted header line should render at least twice across ~3 one-second
    # sweeps — proof the loop re-polls rather than rendering once.
    local count
    count="$(/usr/bin/printf '%s\n' "$RUN_OUT" | /usr/bin/grep -c '^GOLEM ')"
    assert_true "[ '$count' -ge 2 ]" "renders repeatedly (>=2 sweeps in 3s, got $count)"
}

# With no --interval and no env override, the cadence comes from the resolver's
# level-scaled default (L4 -> 900s). We can't wait 900s, so assert only that the
# header reports the resolved default and the first render happened.
test_status_watch_uses_resolver_default() {
    if ! command -v timeout >/dev/null 2>&1; then
        skip_test "timeout not available (cannot bound the --watch loop)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_in_watch "$sb" 2 -- --watch --level 4
    assert_exit 0 "$RUN_RC" "bounded --watch loop exits cleanly"
    assert_contains "$RUN_OUT" "Status sweep every 900s (level 4)" \
        "header shows the L4 resolver default (900s)"
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
run_test test_launch_print_level_flag_substituted "golem-launch: print <N> --level 3 substitutes the level, not hardcoded 4 (#301)"
run_test test_launch_print_level_defaults_to_4 "golem-launch: print <N> with no level defaults to 4 (#301)"
run_test test_launch_print_level_env_fallback "golem-launch: GOLEM_LEVEL is the env fallback for the level (#301)"
run_test test_launch_print_level_flag_beats_env "golem-launch: --level flag overrides GOLEM_LEVEL env (#301)"
run_test test_launch_print_level_out_of_range_exits_2 "golem-launch: --level out of range exits 2 (#301)"
run_test test_launch_print_level_missing_value_exits_2 "golem-launch: bare --level with no value exits 2 (#301)"
run_test test_launch_missing_worktree_exits_2 "golem-launch: launch with a missing worktree exits 2"
run_test test_launch_preflight_rules_present_exits_0 "golem-launch: preflight with all rules present exits 0"
run_test test_launch_preflight_rules_missing_exits_3 "golem-launch: preflight with a missing rule exits 3"
run_test test_launch_version_match_passes "golem-launch: matched plugin version passes the skew guard"
run_test test_launch_version_skew_refuses_exit_3 "golem-launch: version skew refuses dispatch (exit 3)"
run_test test_launch_version_skew_escape_hatch "golem-launch: GOLEM_SKIP_VERSION_CHECK downgrades skew to a warning"
run_test test_launch_version_unknown_sentinel_skips "golem-launch: 'unknown' sentinel version skips the guard (no false positive)"
run_test test_launch_unset_home_does_not_crash "golem-launch: unset HOME does not crash the version guard"
run_test test_launch_version_undeterminable_skips "golem-launch: undeterminable version skips the guard"
run_test test_launch_auth_cache_injects_token "golem-launch: cache token is injected via tmux -e, never echoed (#244)"
run_test test_launch_auth_no_source_no_injection "golem-launch: no token source → no injection, no warning (#244)"
run_test test_launch_auth_op_hang_is_bounded "golem-launch: a hanging op read is time-bounded, dispatch completes (#244)"
run_test test_launch_auth_cache_marker_no_token_warns "golem-launch: cache marker but no token warns, still dispatches (#244)"
run_test test_worktree_new_non_integer_exits_2 "worktree-new: non-integer arg exits 2"
run_test test_worktree_new_creates_worktree "worktree-new: creates the issue worktree + branch"
run_test test_worktree_new_duplicate_exits_1 "worktree-new: duplicate worktree exits 1"
run_test test_worktree_new_existing_branch_exits_1 "worktree-new: lingering branch exits 1"
run_test test_worktree_new_no_hardcoded_usr_bin "worktree-new: no hardcoded /usr/bin/* tool paths (#228)"
run_test test_worktree_new_copies_local_files "worktree-new: copies GOLEM_WORKTREE_LOCAL_FILES into the worktree (#228)"
run_test test_worktree_new_inits_submodules "worktree-new: populates submodules in the fresh worktree (#325)"
run_test test_worktree_new_from_submodule_placement "worktree-new: from inside a submodule lands the worktree at <super>/.worktrees (#338, #324)"
run_test test_worktree_new_scrubs_tainted_git_env_for_mutations "worktree-new: scrubs a tainted GIT_DIR so the branch ref lands in the right repo (#328)"
run_test test_config_repo_root_no_hardcoded_usr_bin "config.sh: repo_root has no hardcoded /usr/bin/* tool paths (#278)"
run_test test_config_repo_root_honors_path "config.sh: repo_root resolves via PATH, not /usr/bin/git (#278)"
run_test test_config_repo_root_dirname_root_edge "config.sh: repo_root returns '/' for a /.git common dir (#278)"
run_test test_config_repo_root_relative_common_dir "config.sh: repo_root absolutizes a relative common dir via command pwd (#278)"
run_test test_config_repo_root_scrubs_tainted_git_env "config.sh: repo_root scrubs a tainted GIT_DIR/GIT_COMMON_DIR (#279)"
run_test test_config_repo_root_scrubs_readonly_tainted_git_env "config.sh: repo_root scrubs a READONLY tainted GIT_DIR via env -u fallback (#328)"
run_test test_config_repo_root_submodule_superproject "config.sh: repo_root returns the superproject root inside a submodule (#324)"
run_test test_config_repo_root_submodule_superproject_scrubs_tainted_git_env "config.sh: repo_root scrubs a tainted GIT_DIR in the super_root probe inside a submodule (#337, #279)"
run_test test_config_repo_root_submodule_superproject_scrubs_readonly_tainted_git_env "config.sh: repo_root scrubs a READONLY tainted GIT_DIR in the super_root probe inside a submodule (#363, #337, #328)"
run_test test_config_repo_root_relative_super_root "config.sh: repo_root absolutizes a relative --show-superproject-working-tree via command pwd (#336)"
run_test test_worktree_rm_non_integer_exits_2 "worktree-rm: non-integer arg exits 2"
run_test test_worktree_rm_absent_is_noop "worktree-rm: absent issue is a clean no-op (exit 0)"
run_test test_worktree_rm_round_trip "worktree-rm: round-trip removes worktree + branch"
run_test test_worktree_rm_scrubs_tainted_git_env_for_mutations "worktree-rm: scrubs a tainted GIT_DIR so deletions target the right repo (#328)"
run_test test_worktree_rm_forces_past_clean_submodule "worktree-rm: forces past a clean populated submodule (#325)"
run_test test_worktree_rm_refuses_dirty_regular_file_with_submodule "worktree-rm: refuses dirty regular file even with a submodule (#325)"
run_test test_worktree_rm_repairs_stale_core_worktree "worktree-rm: repairs a stale main-repo core.worktree (#258)"
run_test test_worktree_rm_preserves_valid_core_worktree "worktree-rm: preserves a valid core.worktree (#258)"
run_test test_attach_non_integer_exits_2 "golem-attach: non-integer arg exits 2"
run_test test_attach_no_session_exits_1 "golem-attach: no session/container exits 1"
run_test test_status_empty_reports_no_golems "golem-status: empty state reports no active golems"
run_test test_status_renders_planted_row "golem-status: planted cache row renders in the table"
run_test test_status_unknown_arg_exits_2 "golem-status: unknown argument exits 2 (#304)"
run_test test_status_watch_bad_level_exits_2 "golem-status: --watch --level out of range exits 2 (#304)"
run_test test_status_watch_bad_interval_exits_2 "golem-status: --watch --interval non-integer exits 2 (#304)"
run_test test_status_watch_loops_with_env_override "golem-status: --watch re-renders; GOLEM_SWEEP_INTERVAL overrides the level default (#304)"
run_test test_status_watch_uses_resolver_default "golem-status: --watch uses the resolver's level-scaled default cadence (#304)"

generate_report
