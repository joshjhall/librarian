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
SCRAPE="$SCRIPTS/golem-token-scrape.sh"
TRANSCRIPT_LIVENESS="$SCRIPTS/golem-transcript-liveness.sh"
INBOX="$SCRIPTS/golem-inbox.sh"
CONFIG="$SCRIPTS/config.sh"
# The Mode-3 container entrypoint lives as a bash code block inside this skill
# doc (not a bundled script), so its write_status() is tested by extraction
# (#415, mirrors validate-template-sync.sh's inline-template extraction).
PROVISION_PROTOCOL="$REPO_ROOT/plugins/workflow/skills/provision-agent/provision-protocol.md"

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
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname>
# Creates a fresh git repo sandbox with one seed commit (so HEAD exists and can
# serve as GOLEM_BASE_REF), a `.worktrees/.status/` dir, and an empty `{}` at
# <sandbox>/.claude.json (the seed-trust target HOME is pointed at). Assigns the
# sandbox path to the caller's named variable. `git init` + the seed commit run
# with the git environment scrubbed so the sandbox is hermetic under a hook.
new_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.name "Test"
    command printf 'seed\n' >"$dir/seed.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" add seed.txt 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    command mkdir -p "$dir/.worktrees/.status"
    # An empty, per-sandbox tmux socket dir. Pointing TMUX_TMPDIR here makes
    # `tmux ls` find no server (so golem-status/attach see ZERO sessions),
    # isolating the tests from REAL golem-* tmux sessions on the host — without
    # it, golem-status.sh's `tmux ls` picks up live golems and the empty-state
    # branch never fires.
    command mkdir -p "$dir/.tmux"
    command printf '{}\n' >"$dir/.claude.json"
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

# inbox_in <sandbox> <inbox-args...>
# Run golem-inbox.sh from INSIDE the sandbox with the same GIT_SCRUB + status-dir
# env as run_in, so its inbox write/read resolves the sandbox repo (not the outer
# checkout). Used to seed inbox state for the golem-status annotation tests.
# GOLEM_INBOX_WAIT=0 so a `consume` with an answer present returns immediately.
inbox_in() {
    local dir="$1"
    shift
    (cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_INBOX_WAIT=0 GOLEM_INBOX_POLL=1 \
            "$REAL_BASH" "$INBOX" "$@" >/dev/null 2>&1) || true
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

# GOLEM_MODEL unset → NO `--model` in the emitted line (byte-identical to the
# pre-knob launch shape — the #487 no-regression invariant).
test_launch_print_model_unset_omits_flag() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5
    assert_exit 0 "$RUN_RC" "print <N> with GOLEM_MODEL unset exits 0"
    assert_not_contains "$RUN_OUT" "--model" \
        "an unset GOLEM_MODEL emits no --model (byte-identical launch line)"
}

# `GOLEM_MODEL=sonnet print <N>` → ` --model "sonnet"` spliced after BOTH the
# next-issue and ship-issue `claude` calls (#487).
test_launch_print_model_set_both_claude_calls() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_MODEL=sonnet \
            "$REAL_BASH" "$LAUNCH" print 5 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "GOLEM_MODEL=sonnet print <N> exits 0"
    # Both claude invocations must carry the model — guard against injecting only
    # one. next-issue call:
    assert_contains "$RUN_OUT" "claude --model \"sonnet\" --permission-mode auto '/workflow:next-issue 5" \
        "GOLEM_MODEL splices --model into the next-issue claude call"
    # ship-issue call:
    assert_contains "$RUN_OUT" "claude --model \"sonnet\" --permission-mode auto '/workflow:ship-issue'" \
        "GOLEM_MODEL splices --model into the ship-issue claude call"
}

# GOLEM_MODEL reaches the REAL `launch` tmux dispatch path (not just `print`).
# `launch_line()` (print) and the `launch` case splice golem_model_flag()
# independently, so cover the dispatch argv the tmux stub captures too (#487).
test_launch_dispatch_model_both_claude_calls() {
    local sb log
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_MODEL=sonnet
    assert_exit 0 "$RUN_RC" "launch with GOLEM_MODEL=sonnet dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "claude --model \"sonnet\" --permission-mode auto '/workflow:next-issue 7" \
        "GOLEM_MODEL reaches the real dispatch next-issue claude call"
    assert_contains "$log" "claude --model \"sonnet\" --permission-mode auto '/workflow:ship-issue'" \
        "GOLEM_MODEL reaches the real dispatch ship-issue claude call"
}

# INJECTION SAFETY (#487): a GOLEM_MODEL carrying shell-metacharacters must be
# neutralized — golem_model_flag() backslash-escapes `"`/backtick/`$`/`\` so the
# value cannot break out of the double-quoted `--model "…"` word that tmux runs
# via `sh -c`. A malicious value like `x"; touch pwned; echo "` must appear
# ESCAPED in the dispatch argv, and its injected `; touch pwned` must NOT run as
# a standalone statement (the `\"` keeps it inside the quoted model token).
test_launch_dispatch_model_shell_metachars_escaped() {
    local sb log
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        'GOLEM_MODEL=x"; touch pwned; echo "'
    assert_exit 0 "$RUN_RC" "launch with a metachar GOLEM_MODEL still dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    # The embedded double quotes are backslash-escaped in the emitted argv, so the
    # value stays one --model token rather than breaking out into new statements.
    assert_contains "$log" 'claude --model "x\"; touch pwned; echo \""' \
        "embedded quotes in GOLEM_MODEL are escaped, not left to break the quoting"
    # And the stub never let the injected command run: no 'pwned' file is created.
    if [ -e "$sb/pwned" ] || [ -e "$sb/.worktrees/issue-7/pwned" ]; then
        assert_contains "MARKER-CREATED" "MARKER-ABSENT" \
            "GOLEM_MODEL injection created a file — escaping failed"
    else
        assert_contains "ok" "ok" "no injected file created (escaping holds)"
    fi
}

# `launch <N>` when the worktree is absent → exit 2 with a remediation pointing
# at worktree-new.sh. Stops BEFORE any real `tmux new-session` (no worktree, so
# the dir guard fires first). Stub both settings scopes at in-sandbox paths so
# preflight reads no real ~/.claude/settings.json.
test_launch_missing_worktree_exits_2() {
    local sb
    new_sandbox sb
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
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
    command cat >"$sb/proj-settings.json" <<'EOF'
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
    command printf '{}\n' >"$sb/global-settings.json"
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
    command cat >"$sb/proj-settings.json" <<'EOF'
{ "permissions": { "allow": ["Bash(tmux new-session:*)", "Bash(tmux ls:*)"] } }
EOF
    command printf '{}\n' >"$sb/global-settings.json"
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
    command cat >"$1" <<EOF
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
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
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
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
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
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
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
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv, never start a real session.
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
}

# run_launch_auth <sandbox> [extra env KEY=VAL ...] — invoke `launch 7` with the
# tmux stub on PATH, rules-present settings, a real worktree dir, and both
# ANTHROPIC_* vars scrubbed. Extra positional args are prepended as env
# assignments. Captures RUN_RC / RUN_OUT; the tmux argv lands in $sb/tmux-args.log.
run_launch_auth() {
    local sb="$1"
    shift
    plant_tmux_stub "$sb"
    command mkdir -p "$sb/.worktrees/issue-7"
    command printf '{ "permissions": { "allow": ["Bash(tmux new-session:*)", "Bash(tmux ls:*)", "Bash(tmux kill-session:*)"] } }\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
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
    command printf 'export ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244\nexport ANTHROPIC_BASE_URL=https://bifrost.example\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache"
    assert_exit 0 "$RUN_RC" "launch with a cache token dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
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
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
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
    command cat >"$sb/bin-op" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
    # op must be on the same PATH dir as the tmux stub; plant it there after
    # run_launch_auth creates bin/ — so pre-create bin/ and the op stub, then run.
    command mkdir -p "$sb/bin"
    command cp "$sb/bin-op" "$sb/bin/op"
    command chmod +x "$sb/bin/op"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        OP_ANTHROPIC_AUTH_TOKEN_REF="op://vault/anthropic/token"
    assert_exit 0 "$RUN_RC" "a hanging op read is bounded — dispatch still completes (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_not_contains "$log" "ANTHROPIC_AUTH_TOKEN" "a timed-out op read injects no token"
}

# A cache marker exists but yields no token → warn (don't fail), still dispatch,
# inject nothing. Exercises the elif warning arm.
test_launch_auth_cache_marker_no_token_warns() {
    local sb log
    new_sandbox sb
    # Cache is readable but exports something OTHER than the token.
    command printf 'export SOME_OTHER_SECRET=1\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache"
    assert_exit 0 "$RUN_RC" "an empty cache still dispatches (exit 0)"
    assert_contains "$RUN_OUT" "WARNING" "warns when a cache marker is present but no token resolves"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
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
        git -C "$sb" branch --list "feature/issue-31")"
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
        git -C "$sb" worktree remove .worktrees/issue-33 2>/dev/null
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
    command printf 'SECRET=1\n' >"$sb/.env"
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
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1

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
        git -C "$sb" branch --list "feature/issue-78")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-78")"
    assert_not_empty "$sb_branch" \
        "the branch ref lands in the SANDBOX repo, not the tainted GIT_DIR target"
    assert_output_empty "$outer_branch" \
        "no branch ref leaked into the outer/tainted repo (no split-brain)"
}

# _seed_failing_ref_hook <sandbox> <out-hooksdir-var>
# Writes a hooks dir containing a `reference-transaction` hook that ALWAYS fails,
# and returns its path via the named out-var. Injected as core.hooksPath, this
# hook aborts ANY git ref mutation (worktree add -b, branch -D) with
# "update aborted by the reference-transaction hook" (verified rc≠0) — so it is a
# DISCRIMINATING taint for the mutation-level scrub tests below: unscrubbed, the
# script's own `git worktree add`/`branch -D` fires the hook and fails; scrubbed,
# the injection is gone and the mutation runs clean. A nonexistent hooksPath would
# NOT discriminate (git silently finds no hook and proceeds), so the hook must
# exist and actively fail.
# Internal local is `hdir`, deliberately NOT the caller's out-var name (`hooks`):
# `printf -v "$__out"` resolves against the current scope, so an internal `hooks`
# would shadow and overwrite the caller's local instead of exporting the path back
# (the same pitfall _make_super_with_submodule sidesteps with its `sup`).
_seed_failing_ref_hook() {
    local __out="$2" hdir="$1/evil-hooks"
    command mkdir -p "$hdir"
    command printf '#!/bin/sh\nexit 1\n' >"$hdir/reference-transaction" # lint-allow-path: shebang in generated fixture-script data
    command chmod +x "$hdir/reference-transaction"
    printf -v "$__out" '%s' "$hdir"
}

# Security regression (#376, deferred from the #355/PR #375 pre-PR review): the
# mutation-level companion to test_worktree_new_scrubs_tainted_git_env_for_mutations
# (#328), swapping the GIT_DIR taint for a GIT_CONFIG_COUNT/KEY_0/VALUE_0 config
# injection. #328 proved worktree-new.sh's process-wide scrub re-anchors its `git
# worktree add -b` after a GIT_DIR redirect; this proves the SAME scrub clears the
# dynamic GIT_CONFIG_* injection family end-to-end through the script's own
# mutation — not just at the repo_root() unit level. The injected core.hooksPath
# points at a hooks dir whose reference-transaction hook ALWAYS fails: if the scrub
# is dropped, `git worktree add -b` fires the hook and aborts the ref creation
# (script exits non-zero, no branch); with the scrub the injection is gone, the
# mutation runs clean, and the branch lands in the SANDBOX. No GIT_SCRUB on the
# invocation — the taint is the whole point; the script's own #328 scrub must
# clear it. Pin GOLEM_* / HOME like run_in does otherwise.
test_worktree_new_scrubs_git_config_injection_for_mutations() {
    local sb hooks
    new_sandbox sb
    _seed_failing_ref_hook "$sb" hooks

    local out rc=0
    out="$(cd "$sb" &&
        GIT_CONFIG_COUNT=1 \
            GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
            HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 76 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-new exits 0 despite a GIT_CONFIG_* injection taint"

    assert_file_exists "$sb/.worktrees/issue-76/seed.txt" \
        "the worktree is created in the sandbox despite the config injection"
    local sb_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-76")"
    assert_not_empty "$sb_branch" \
        "the branch ref lands in the sandbox despite the GIT_CONFIG_* injection (scrub clears the dynamic pairs)"
}

# Regression (#365, closing the last open cell of the worktree-new.sh × submodule
# × tainted-git-env coverage matrix — deferred from PR #364's pre-PR review). The
# two hardening dimensions are already tested only SEPARATELY: #338
# (test_worktree_new_from_submodule_placement) drives the whole script from
# inside a submodule but with a CLEAN env (placement only), and #328
# (test_worktree_new_scrubs_tainted_git_env_for_mutations) drives the whole
# script UNDER taint but from a PLAIN non-submodule sandbox (repo_root's
# common-dir arm). The exact fusion — the full worktree-new.sh from INSIDE a
# submodule AND under a tainted GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR — was
# untested end-to-end; #337 covers submodule+taint only at the repo_root() UNIT
# level, not the script's OWN post-repo_root() `git worktree add` mutation. This
# is that cell: worktree-new.sh's process-wide scrub (before repo_root and every
# mutation) must both keep the #324 super_root placement (worktree lands at
# <super>/.worktrees, nothing under .git/modules) AND keep the #328 branch ref in
# the superproject, not the tainted outer repo. Not via run_in (it cd's to the
# sandbox root); this must invoke from the submodule subdir, so it hand-rolls the
# env invocation mirroring run_in's pins with `cd "$super/mod"` (like
# test_worktree_new_from_submodule_placement) but WITHOUT the GIT_SCRUB unset —
# the taint is the whole point; the script's own scrub must clear it.
# GIT_WORK_TREE is included in the taint (load-bearing per #337/#363: it forces
# an unscrubbed super_root probe to miss the submodule). Skips cleanly if
# `git submodule add` is unavailable (old git / file protocol disallowed).
test_worktree_new_from_submodule_placement_under_taint() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1

    # Third, unrelated outer repo whose .git the taint points at (the split-brain
    # target). Scrubbed setup so its own creation is not itself tainted.
    local outer
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1

    # Invoke worktree-new from INSIDE the submodule working tree (<super>/mod) with
    # the git env TAINTED toward outer. No GIT_SCRUB on this invocation — the
    # script's own #328 scrub must clear it; GIT_WORK_TREE is included so an
    # unscrubbed super_root probe would miss the submodule (#337/#363). Fully-local
    # out/rc pair (not the shared RUN_OUT/RUN_RC), since this bypasses run_in.
    local out rc=0
    out="$(cd "$super/mod" &&
        GIT_DIR="$outer/.git" GIT_WORK_TREE="$outer" GIT_COMMON_DIR="$outer/.git" \
            HOME="$super" \
            TMUX='' TMUX_TMPDIR="$super/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 45 2>&1)" || rc=$?
    assert_exit 0 "$rc" \
        "worktree-new exits 0 from inside a submodule despite a tainted git environment"
    assert_file_exists "$super/.worktrees/issue-45/app.txt" \
        "the worktree lands at <super>/.worktrees/issue-45 with the superproject's files"
    assert_true '[ ! -e "'"$super"'/.git/modules/mod/.worktrees" ]' \
        "nothing landed under <super>/.git/modules (the #324 bug path)"

    # The branch ref must land in the superproject, not the tainted outer repo
    # (#328 no-split-brain). Query through a scrubbed env so the check is not
    # itself tainted.
    local super_branch outer_branch
    super_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" branch --list "feature/issue-45")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-45")"
    assert_not_empty "$super_branch" \
        "the branch ref lands in the superproject, not the tainted GIT_DIR target"
    assert_output_empty "$outer_branch" \
        "no branch ref leaked into the outer/tainted repo (no split-brain)"
}

# Regression (#368, deferred from PR #367's pre-PR review): worktree-new.sh's
# top-level `unset $(_git_env_scrub_names)` documents a deliberate FAIL-LOUD
# contract — "NO `|| true`: a readonly GIT_DIR makes `unset` fail, which under
# `set -e` aborts LOUDLY before any mutation." config.sh's repo_root has the
# analogous guarantee covered (test_config_repo_root_scrubs_readonly_tainted_git_env,
# #328), but the script itself had no test invoking it under a `declare -rx`
# taint, so a future edit adding `|| true` or restructuring the unset would
# silently regress the guarantee. This pins it: a readonly-exported
# GIT_DIR/GIT_COMMON_DIR must make worktree-new EXIT NON-ZERO and mutate NOTHING.
#
# The taint MUST be applied by SOURCING the script (not the plain `bash script`
# form run_in uses): the `declare -rx` READONLY attribute is dropped across
# `exec`, so a child bash launched to run the script would inherit only the
# exported VALUE, not the readonly-ness — its `unset` would succeed and the
# fail-loud path would never be exercised. Sourcing inside a bash that first
# declared the readonly vars keeps them readonly when the script's `unset` runs.
# Mirrors test_config_repo_root_scrubs_readonly_tainted_git_env's `declare -rx`
# setup, applied to the whole script. No GIT_SCRUB on the invocation — the taint
# is the whole point; the script's own guard must abort on it.
test_worktree_new_readonly_tainted_git_env_fails_loud() {
    local sb outer
    new_sandbox sb
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1

    # Source worktree-new inside a child bash that makes GIT_DIR/GIT_COMMON_DIR
    # `declare -rx` (readonly + exported) BEFORE the script's `unset` runs, so the
    # unset fails and `set -e` aborts. Pin GOLEM_* / HOME like run_in does.
    local out rc=0
    out="$(cd "$sb" &&
        HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" -c \
            'declare -rx GIT_DIR="$2/.git"; declare -rx GIT_COMMON_DIR="$2/.git"; . "$1" 78' \
            _ "$WT_NEW" "$outer" 2>&1)" || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" \
        "worktree-new aborts NON-ZERO under a readonly-tainted git environment (fail-loud)"

    # No mutation: no branch in the sandbox OR the outer repo, and no worktree dir.
    local sb_branch outer_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-78")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-78")"
    assert_output_empty "$sb_branch" \
        "no branch ref created in the sandbox (aborted before the mutation)"
    assert_output_empty "$outer_branch" \
        "no branch ref leaked into the outer/tainted repo"
    assert_true "[ ! -e \"$sb/.worktrees/issue-78\" ]" \
        "no worktree dir created (aborted before git worktree add)"
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
    body="$(command awk '/^repo_root\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$CONFIG")"
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
    command mkdir -p "$shim"
    command ln -s "$real_git" "$shim/git"

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
        "repo_root resolves the repo root via PATH, not command git"
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
    command mkdir -p "$bin"
    {
        command printf '#!/usr/bin/env bash\n'
        # Only intercept the common-dir probe; anything else is unexpected here.
        command printf 'case "$*" in\n'
        command printf '  *--git-common-dir*) command echo "/.git" ;;\n'
        command printf '  *) exit 1 ;;\n'
        command printf 'esac\n'
    } >"$bin/git"
    command chmod +x "$bin/git"

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
    command mkdir -p "$bin"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'case "$*" in\n'
        command printf '  *--git-common-dir*) command echo ".git" ;;\n'
        command printf '  *) exit 1 ;;\n'
        command printf 'esac\n'
    } >"$bin/git"
    command chmod +x "$bin/git"

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
    command mkdir -p "$bin"
    # A real relative target so the realpath compare proves pwd was prepended.
    command mkdir -p "$sb/sup"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'case "$*" in\n'
        command printf '  *--show-superproject-working-tree*) command echo "sup" ;;\n'
        command printf '  *) exit 1 ;;\n'
        command printf 'esac\n'
    } >"$bin/git"
    command chmod +x "$bin/git"

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
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1

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

# Security regression (#355): git honors GIT_CONFIG_COUNT + GIT_CONFIG_KEY_<n> /
# GIT_CONFIG_VALUE_<n> (and the single-var GIT_CONFIG_PARAMETERS form) to inject
# arbitrary config, changing what a later git call reads WITHOUT touching GIT_DIR
# (e.g. url.<base>.insteadOf redirecting a fetch). config.sh's _git_env_scrub_names
# scrubs the whole family — the static names plus the dynamic KEY_<n>/VALUE_<n>
# pairs — inside _repo_root_git, which is the shared arm every caller's git runs
# through.
#
# The test must DISCRIMINATE scrubbed from unscrubbed. `repo_root()` alone does
# NOT: its only git subcommand is `rev-parse --git-common-dir`, which is inert to
# core.worktree/config injection (the pre-PR review verified an injected
# core.worktree leaves --git-common-dir unchanged, so a repo_root()-level
# assertion passes even with ZERO scrubbing — a false-positive security test).
# Instead drive `_repo_root_git config --get <key>`: `git config` DOES honor the
# injected value, so the assertion actually fails when the scrub is dropped. The
# test proves both directions: (a) a BARE `git config --get` under the taint reads
# the INJECTED value (the vector is real and reaches this repo), and (b)
# `_repo_root_git config --get` reads the repo's REAL value (the scrub neutralizes
# it). Taint deliberately not in GIT_SCRUB — it must reach the child.
#
# Helper: run one injection encoding and assert the scrub wins while a bare git
# loses. $1 = label, remaining args = the env assignment(s) carrying the taint.
_assert_config_injection_scrubbed() {
    local label="$1"
    shift
    local sb
    new_sandbox sb
    # Seed a known real value the injection tries to override.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config user.name "REALNAME"

    # (a) Bare git under the taint reads the INJECTED value — proves the vector is
    # live and reaches this repo (guards against a test that passes vacuously). The
    # bare git's own exit code is irrelevant here; only the value it reads matters.
    local bare
    bare="$(cd "$sb" &&
        /usr/bin/env "$@" "$REAL_BASH" -c 'git config --get user.name' 2>&1)" || true
    assert_equals "INJECTED" "$bare" \
        "$label: bare git honors the injected user.name (the taint is real)"

    # (b) _repo_root_git config --get reads the REAL value — the scrub neutralized
    # the injection. This FAILS (reads INJECTED) if the scrub is dropped.
    local scrubbed rc_b=0
    scrubbed="$(cd "$sb" &&
        /usr/bin/env "$@" "$REAL_BASH" -c '. "$1"; _repo_root_git config --get user.name' \
            _ "$CONFIG" 2>&1)" || rc_b=$?
    assert_exit 0 "$rc_b" "$label: _repo_root_git config exits 0 despite the taint"
    assert_equals "REALNAME" "$scrubbed" \
        "$label: _repo_root_git reads the REAL user.name, not the injected one (scrub works)"
}

# Indexed GIT_CONFIG_COUNT/KEY_<n>/VALUE_<n> encoding — the dynamic pairs
# _git_env_scrub_names enumerates.
test_config_repo_root_scrubs_git_config_injection() {
    _assert_config_injection_scrubbed "GIT_CONFIG_COUNT" \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=INJECTED
}

# Single-var GIT_CONFIG_PARAMETERS encoding — a shell-quoted `'key=value'` list
# git honors identically. A FIXED name (unlike the dynamic pairs), so it lives in
# the static GIT_ENV_SCRUB_VARS. Its omission left the injection class
# half-closed (surfaced by the pre-PR review); this guards the fix.
test_config_repo_root_scrubs_git_config_parameters() {
    _assert_config_injection_scrubbed "GIT_CONFIG_PARAMETERS" \
        GIT_CONFIG_PARAMETERS="'user.name=INJECTED'"
}

# Availability regression (#355): GIT_CEILING_DIRECTORIES makes git STOP repo
# discovery at the named ceiling — set to the sandbox root, discovery from a
# subdir fails `fatal: not a git repository` (verified rc=128 unscrubbed). A golem
# host whose hook exports it would break every repo_root() caller inside a valid
# repo. config.sh scrubs it (now on GIT_ENV_SCRUB_VARS), so repo_root() resolves
# regardless. Run from a SUBDIR so the ceiling actually bites (from the root
# itself git is already at the boundary). Taint deliberately not in GIT_SCRUB.
test_config_repo_root_scrubs_git_ceiling_directories() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/sub"

    local out rc=0
    out="$(cd "$sb/sub" &&
        GIT_CEILING_DIRECTORIES="$sb" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 despite a GIT_CEILING_DIRECTORIES discovery block"
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root resolves the sandbox root despite a GIT_CEILING_DIRECTORIES taint"
}

# Security regression (#376, deferred from the #355/PR #375 pre-PR review): four
# static scrub names — GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM / GIT_CONFIG_NOSYSTEM
# / GIT_DISCOVERY_ACROSS_FILESYSTEM — were on GIT_ENV_SCRUB_VARS but covered ONLY
# by the static list-equality assertion in
# test_config_git_env_scrub_vars_single_source, never by a live-taint behavioral
# test proving the scrub actually neutralizes them. A partial-scrub refactor
# per-name could drop one silently. These tests close that gap, each
# DISCRIMINATING (fails when the scrub is dropped, per the #355 vector tests'
# rationale above): a BARE git under the taint honors it, while the same call
# through _repo_root_git is unaffected.
#
# Two distinct vector shapes need two helpers:
#
# GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM point git at an arbitrary config FILE
# (unlike the indexed GIT_CONFIG_COUNT pairs), injecting values without touching
# GIT_DIR — e.g. a url.<base>.insteadOf redirect or a hostile core.hooksPath.
# NOTE these inject at GLOBAL/SYSTEM precedence, which repo-LOCAL config OUTRANKS,
# so (unlike the command-scope GIT_CONFIG_COUNT pairs) the sandbox must NOT seed a
# competing repo-local inject.marker — the injected key must be one the repo does
# not set, so the bare read actually surfaces the injected value. Helper: seed a
# config file setting inject.marker=INJECTED, then assert (a) a bare
# `git config --get inject.marker` under the taint reads INJECTED (the vector is
# live and reaches this repo — guards against a vacuous pass), and (b)
# `_repo_root_git config --get inject.marker` reads NOTHING and exits non-zero (the
# scrub removed the file redirect, so the key is simply absent). $1 = the env var
# name carrying the file path.
_assert_config_file_injection_scrubbed() {
    local var="$1"
    local sb
    new_sandbox sb
    # The injected config file (points $var at it below). A FILE, not indexed pairs.
    # inject.marker is deliberately NOT set in the sandbox's repo-local config:
    # GLOBAL/SYSTEM scope loses to repo-local, so a local seed would shadow the
    # injection and the bare read would never surface INJECTED (a vacuous test).
    local injfile="$sb/inject.cfg"
    command printf '[inject]\n\tmarker = INJECTED\n' >"$injfile"

    # (a) Bare git under the taint reads the INJECTED value — the file redirect is
    # live. HOME is pinned at the sandbox so a stray real ~/.gitconfig can't shadow
    # GIT_CONFIG_GLOBAL. The bare git's own exit code is irrelevant; only the value.
    local bare
    bare="$(cd "$sb" &&
        /usr/bin/env "$var=$injfile" HOME="$sb" \
            "$REAL_BASH" -c 'command git config --get inject.marker' 2>&1)" || true
    assert_equals "INJECTED" "$bare" \
        "$var: bare git honors the injected config file (the taint is real)"

    # (b) _repo_root_git config --get finds NOTHING — the scrub removed the file
    # redirect, so inject.marker is unset (config --get exits 1 with empty output).
    # READS INJECTED (exit 0) if the scrub drops this name.
    local scrubbed rc_b=0
    scrubbed="$(cd "$sb" &&
        /usr/bin/env "$var=$injfile" HOME="$sb" \
            "$REAL_BASH" -c '. "$1"; _repo_root_git config --get inject.marker' \
            _ "$CONFIG" 2>&1)" || rc_b=$?
    assert_output_empty "$scrubbed" \
        "$var: _repo_root_git reads no inject.marker — the injected file was scrubbed away (scrub works)"
    assert_true "[ '$rc_b' -ne 0 ]" \
        "$var: _repo_root_git config exits non-zero (the injected key is gone, not read)"
}

# GIT_CONFIG_NOSYSTEM / GIT_DISCOVERY_ACROSS_FILESYSTEM are BOOLEAN control vars,
# not value injectors: NOSYSTEM suppresses system config, DISCOVERY controls
# crossing a filesystem boundary. A value-injection discriminator doesn't fit
# (suppression is indistinguishable from absence; a cross-FS fixture isn't
# portable), but git VALIDATES both as booleans on every invocation, so an INVALID
# bool (`notabool`) makes any git call fatal (rc 128) — a clean, portable
# discriminator that still proves the var reaches the child and the scrub removes
# it. We assert on the rc DELTA across three runs of the same fixture, not on
# git's internal fatal-error wording (which carries no version floor and could be
# reworded upstream): seed a REAL inject.marker=REALNAME, then triangulate
# (a0) a bare `git config --get` with NO taint exits 0 (the fixture is sound, so
# the fatal in (a) is caused by the taint — not a broken sandbox),
# (a) the same bare call under the invalid-bool taint fatals (rc 128, the var is
# live and git honors it), and
# (b) `_repo_root_git config --get` under the same taint exits 0 reading REALNAME
# (the scrub removed the bad var so git runs clean). The 0 → 128 → 0 sequence
# proves the taint specifically causes the fatal and the scrub specifically
# removes it. $1 = the env var name.
_assert_bool_var_scrubbed() {
    local var="$1"
    local sb
    new_sandbox sb
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config inject.marker "REALNAME"

    # (a0) Baseline: the SAME bare call with NO taint exits 0. Proves the fixture
    # is sound, so the fatal in (a) is attributable to the taint — not a broken
    # sandbox. This is the version-independent replacement for asserting on git's
    # fatal-error wording. GIT_SCRUB is applied so an INHERITED GIT_DIR (which the
    # git pre-push hook exports into this harness's environment) cannot pin git at
    # the outer repo and make the sandbox's inject.marker unreadable — the leak
    # that made these two tests fail under `git push` but pass on a bare run.
    local rc_a0=0
    (cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" HOME="$sb" \
            "$REAL_BASH" -c 'command git config --get inject.marker' >/dev/null 2>&1) || rc_a0=$?
    assert_exit 0 "$rc_a0" \
        "$var: baseline bare git succeeds without the taint (fixture is sound)"

    # (a) Bare git under an invalid-bool taint fatals (rc 128) — the var reaches the
    # child and git honors it. Guards against a vacuous pass. Same GIT_SCRUB as (a0)
    # so ONLY the deliberate `$var=notabool` taint (not a leaked GIT_DIR) drives the
    # fatal.
    local rc_a=0
    (cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$var=notabool" HOME="$sb" \
            "$REAL_BASH" -c 'command git config --get inject.marker' >/dev/null 2>&1) || rc_a=$?
    assert_exit 128 "$rc_a" \
        "$var: bare git fatals on the invalid-bool taint (the taint is real)"

    # (b) _repo_root_git scrubs the name, so git runs clean and reads the REAL
    # value. FAILS (fatals, rc 128) if the scrub drops this name.
    local scrubbed rc_b=0
    scrubbed="$(cd "$sb" &&
        /usr/bin/env "$var=notabool" HOME="$sb" \
            "$REAL_BASH" -c '. "$1"; _repo_root_git config --get inject.marker' \
            _ "$CONFIG" 2>&1)" || rc_b=$?
    assert_exit 0 "$rc_b" \
        "$var: _repo_root_git config exits 0 despite the invalid-bool taint"
    assert_equals "REALNAME" "$scrubbed" \
        "$var: _repo_root_git reads the REAL inject.marker (scrub works)"
}

# GIT_CONFIG_GLOBAL file-injection — the ~/.gitconfig-slot redirect.
test_config_repo_root_scrubs_git_config_global() {
    _assert_config_file_injection_scrubbed GIT_CONFIG_GLOBAL
}

# GIT_CONFIG_SYSTEM file-injection — the /etc/gitconfig-slot redirect.
test_config_repo_root_scrubs_git_config_system() {
    _assert_config_file_injection_scrubbed GIT_CONFIG_SYSTEM
}

# GIT_CONFIG_NOSYSTEM — the system-config suppression bool.
test_config_repo_root_scrubs_git_config_nosystem() {
    _assert_bool_var_scrubbed GIT_CONFIG_NOSYSTEM
}

# GIT_DISCOVERY_ACROSS_FILESYSTEM — the cross-filesystem-boundary discovery bool.
test_config_repo_root_scrubs_git_discovery_across_filesystem() {
    _assert_bool_var_scrubbed GIT_DISCOVERY_ACROSS_FILESYSTEM
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
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1

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
    sub="$(command mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(command mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule. `protocol.file.allow=always`
    # is required for a local-path submodule add on modern git.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1

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
    sub="$(command mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(command mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1
    # Third, unrelated outer repo whose .git the taint points at.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1

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
    sub="$(command mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(command mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1
    # Third, unrelated outer repo whose .git the taint points at.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1

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

# --- config.sh GIT_ENV_SCRUB_VARS single source (#356) -----------------------

# Regression (#356 / #355): the git hook-exported scrub var list must live in
# exactly ONE place — config.sh's GIT_ENV_SCRUB_VARS, surfaced through
# _git_env_scrub_names — with _repo_root_git and both worktree callers referencing
# it. Before #356 the list was copy-pasted into three files; a future addition
# (e.g. #355's GIT_CONFIG_*) applied to some but not all silently reopens the
# tainted-env vulnerability class (#279/#328), and nothing cross-checked the
# copies. #355 grew the static list to 14 names and added the dynamic
# GIT_CONFIG_KEY_<n>/VALUE_<n> pairs enumerated by _git_env_scrub_names. This
# static guard pins the single source:
#   1. sourcing config.sh yields the exact 14-name list, in order;
#   2. the literal set (fingerprinted by its most-likely-forgotten member
#      GIT_ALTERNATE_OBJECT_DIRECTORIES) appears under plugins/ ONLY in
#      config.sh and exactly once — no site re-lists it;
#   3. both callers scrub via $(_git_env_scrub_names), not a re-listed literal.
test_config_git_env_scrub_vars_single_source() {
    local out rc=0
    # (1) Sourcing config.sh defines GIT_ENV_SCRUB_VARS as the expected list.
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" -c '. "$1"; command printf "%s" "$GIT_ENV_SCRUB_VARS"' \
        _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "sourcing config.sh succeeds and exposes GIT_ENV_SCRUB_VARS"
    assert_equals \
        "GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM" \
        "$out" \
        "GIT_ENV_SCRUB_VARS is the exact 14-name scrub list, in order (#355)"

    # (1b) The list is a SECURITY INVARIANT: a plain assignment, NOT an
    # env-overridable `: "${GIT_ENV_SCRUB_VARS:=…}"` default. Pre-set a truncated
    # value in the child's environment before sourcing config.sh and confirm the
    # source CLOBBERS it back to the full 14-name list — a compromised git hook (or
    # a harness bug) pre-exporting an empty/short list must NOT be able to shrink
    # the scrub set and defeat the taint defense (#356).
    local override rc2=0
    override="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" GIT_ENV_SCRUB_VARS="GIT_DIR" \
        "$REAL_BASH" -c '. "$1"; command printf "%s" "$GIT_ENV_SCRUB_VARS"' \
        _ "$CONFIG" 2>&1)" || rc2=$?
    assert_exit 0 "$rc2" "sourcing config.sh with a pre-set GIT_ENV_SCRUB_VARS succeeds"
    assert_equals \
        "GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM" \
        "$override" \
        "config.sh clobbers an inherited GIT_ENV_SCRUB_VARS — the scrub set can't be shrunk from the env (#356)"

    # (2) The literal list appears under plugins/ only in config.sh, exactly once.
    # Fingerprint on the trailing member: a re-listed copy elsewhere would name it
    # too. `grep -rc` prints <file>:<count>; expect one line, config.sh, count 1.
    local hits
    hits="$(command grep -rlF 'GIT_ALTERNATE_OBJECT_DIRECTORIES' \
        "$REPO_ROOT/plugins" 2>/dev/null | command sort)"
    assert_equals "$CONFIG" "$hits" \
        "GIT_ALTERNATE_OBJECT_DIRECTORIES appears under plugins/ only in config.sh (#356)"
    local count
    count="$(command grep -cF 'GIT_ALTERNATE_OBJECT_DIRECTORIES' "$CONFIG" 2>/dev/null || command echo 0)"
    assert_equals "1" "$count" \
        "config.sh names the literal scrub set exactly once (the single source)"

    # (3) Both worktree callers scrub via the shared helper, not a literal list.
    assert_file_contains "$WT_NEW" 'unset $(_git_env_scrub_names)' \
        "worktree-new.sh scrubs via the shared _git_env_scrub_names"
    assert_file_contains "$WT_RM" 'unset $(_git_env_scrub_names)' \
        "worktree-rm.sh scrubs via the shared _git_env_scrub_names"

    # (4) _git_env_scrub_names appends the dynamically-indexed GIT_CONFIG_KEY_<n> /
    # GIT_CONFIG_VALUE_<n> pairs present in the environment to the static list —
    # these can't be fixed names (the count is dynamic), so the helper is what
    # keeps them in the scrub set (#355). Pre-set two pairs and assert both indices
    # appear after the 14 static names.
    local pairs rc4=0
    pairs="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        GIT_CONFIG_COUNT=2 \
        GIT_CONFIG_KEY_0=core.worktree GIT_CONFIG_VALUE_0=/x \
        GIT_CONFIG_KEY_1=url.z.insteadOf GIT_CONFIG_VALUE_1=/y \
        "$REAL_BASH" -c '. "$1"; command printf "%s" "$(_git_env_scrub_names)"' \
        _ "$CONFIG" 2>&1)" || rc4=$?
    assert_exit 0 "$rc4" "_git_env_scrub_names runs with GIT_CONFIG_* pairs present"
    assert_contains "$pairs" "GIT_CONFIG_KEY_0" \
        "_git_env_scrub_names enumerates the dynamic GIT_CONFIG_KEY_<n> pairs (#355)"
    assert_contains "$pairs" "GIT_CONFIG_VALUE_1" \
        "_git_env_scrub_names enumerates the dynamic GIT_CONFIG_VALUE_<n> pairs (#355)"
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
        git -C "$sb" branch --list "feature/issue-34")"
    assert_equals "" "$branches" "the feature/issue-34 branch is gone after rm"
}

# Regression (#486): the tmux-kill block must kill the session UNCONDITIONALLY,
# not gate the kill on `tmux has-session`. That guard raced the golem's own
# `claude … ; claude …` self-teardown and intermittently reported the session
# absent while it lingered a beat longer, so the kill was skipped and golem-N
# leaked into `tmux ls` / golem-status.sh. A stub `tmux` that returns NON-ZERO
# for `has-session` (the racy false reading) but ZERO for `kill-session` (the
# session really is there) distinguishes the two behaviors: the old guarded code
# would skip the kill (no "killed" line), the new code kills anyway. Pins that
# `kill-session` is invoked with the exact-name `=golem-N` target and the
# "killed tmux session" line still prints. --unset=BASH_ENV keeps the
# devcontainer's /etc/bash_env from resetting $PATH and shadowing the stub (see
# run_launch_auth and the devcontainer-bash-env-path-reset note).
test_worktree_rm_kills_session_despite_has_session_false() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 62
    assert_exit 0 "$RUN_RC" "worktree-new seeds the worktree to reap"

    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv; report has-session FALSE (racy guard) but kill-session OK.
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
case "$1" in
    has-session) exit 1 ;;
    kill-session) exit 0 ;;
    *) exit 0 ;;
esac
EOF
    command chmod +x "$sb/bin/tmux"

    local log="$sb/tmux-stub.log"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 62 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 with the tmux stub"
    assert_contains "$RUN_OUT" "killed tmux session golem-62" \
        "kills the session even though has-session would report it absent"
    local killlog
    killlog="$(command cat "$log" 2>/dev/null || true)"
    assert_contains "$killlog" "kill-session -t =golem-62" \
        "invokes kill-session with the exact-name =golem-N target"
}

# Regression companion (#486): the OTHER branch of the unconditional kill — tmux
# present but `kill-session` genuinely fails (no such session) — must stay a quiet
# exit-0 no-op: NO "killed tmux session" line and removed stays 0 (so a torn-down
# golem with nothing else to remove reports "nothing to remove", not a phantom
# kill). Without the old `has-session` guard, kill-session's own non-zero exit is
# the sole gate on the echo/removed=1, so pin it deterministically with a stub
# (kill-session -> non-zero) rather than relying on the host's real tmux. Run
# against an ABSENT issue so no worktree/branch removal masks removed=0.
test_worktree_rm_kill_session_failure_is_quiet_noop() {
    local sb
    new_sandbox sb

    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv; report every subcommand as FAILED (session truly absent).
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    local log="$sb/tmux-stub.log"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 63 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 when kill-session fails (absent session)"
    assert_not_contains "$RUN_OUT" "killed tmux session" \
        "does not claim a kill when kill-session returned non-zero"
    # removed stays 0: nothing else to remove for an absent issue -> "nothing to remove".
    assert_contains "$RUN_OUT" "nothing to remove" \
        "a failed kill does not set removed=1 (phantom removal)"
    local killlog
    killlog="$(command cat "$log" 2>/dev/null || true)"
    assert_contains "$killlog" "kill-session -t =golem-63" \
        "still attempts the exact-name kill-session before treating it as a no-op"
}

# Teardown emits a terminal `reaped` feed line (#446, Bug #2). worktree-rm.sh pipes
# a REAPED:-prefixed Notification to golem-notify.sh after a successful teardown so
# the torn-down golem's stale `gate` line is superseded and it does not ghost on
# golem-status.sh's BLOCKED list. Two things are pinned: the line lands in the feed
# with event=reaped, AND it carries the correct `golem-N` id (not `golem-?`) — the
# script runs in the MAIN checkout, so worktree-rm.sh must force GOLEM_ID or the
# hook's basename fallback would stamp `golem-?` and never correlate.
test_worktree_rm_emits_reaped_feed_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed-line assertion needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 51
    assert_exit 0 "$RUN_RC" "worktree-new seeds the worktree to reap"
    run_in "$sb" "$WT_RM" 51
    assert_exit 0 "$RUN_RC" "worktree-rm succeeds"

    local feed
    feed="$sb/.worktrees/.status/feed.jsonl"
    assert_file_exists "$feed" "worktree-rm wrote a feed line on teardown"
    # The most-recent line for golem-51 must be a reaped event with the right id.
    local reaped
    reaped="$(command grep '"golem":"golem-51"' "$feed" 2>/dev/null | command tail -n1)"
    assert_not_empty "$reaped" "a feed line for golem-51 was written"
    local ev
    ev="$(command printf '%s' "$reaped" | jq -r '.event' 2>/dev/null)"
    assert_equals "reaped" "$ev" "the teardown line classifies as event=reaped (#446)"
    # No golem-? ghost id: the forced GOLEM_ID must have resolved to golem-51.
    assert_not_contains "$reaped" "golem-?" "the reaped line carries golem-51, not the golem-? sentinel"
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
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch "feature/issue-79" 2>/dev/null || return 1

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
        git -C "$sb" branch --list "feature/issue-79")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-79")"
    assert_output_empty "$sb_branch" \
        "the SANDBOX branch was deleted (the mutation targeted the right repo)"
    assert_not_empty "$outer_branch" \
        "the outer/tainted repo's same-named branch is untouched (no cross-repo delete)"
}

# Security regression (#376, deferred from the #355/PR #375 pre-PR review): the
# mutation-level companion to test_worktree_rm_scrubs_tainted_git_env_for_mutations
# (#328), swapping the GIT_DIR taint for a GIT_CONFIG_COUNT/KEY_0/VALUE_0 config
# injection so the DESTRUCTIVE teardown (worktree remove / branch -D) is exercised
# under the dynamic GIT_CONFIG_* family end-to-end, not just at the repo_root()
# unit level. The injected core.hooksPath points at a hooks dir whose
# reference-transaction hook ALWAYS fails: if the scrub is dropped, worktree-rm's
# own `git branch -D` fires the hook and aborts the ref deletion (script exits
# non-zero, branch survives); with the scrub the injection is gone and the teardown
# runs clean, removing the sandbox worktree+branch. No GIT_SCRUB on the invocation
# — the taint is the point; the script's own #328 scrub must clear it. Pin GOLEM_*
# / HOME like run_in does otherwise.
test_worktree_rm_scrubs_git_config_injection_for_mutations() {
    local sb hooks
    new_sandbox sb
    # Seed the sandbox worktree+branch to remove (scrubbed path — safe).
    run_in "$sb" "$WT_NEW" 77
    assert_exit 0 "$RUN_RC" "worktree-new seeds the sandbox worktree+branch"
    _seed_failing_ref_hook "$sb" hooks

    local out rc=0
    out="$(cd "$sb" &&
        GIT_CONFIG_COUNT=1 \
            GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
            HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 77 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-rm exits 0 despite a GIT_CONFIG_* injection taint"

    assert_true "[ ! -e '$sb/.worktrees/issue-77' ]" \
        "the worktree directory is gone after rm despite the config injection"
    local sb_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-77")"
    assert_output_empty "$sb_branch" \
        "the sandbox branch was deleted despite the GIT_CONFIG_* injection (scrub clears the dynamic pairs)"
}

# Regression (#368, deferred from PR #367's pre-PR review): worktree-rm.sh's
# top-level `unset $(_git_env_scrub_names)` carries the same FAIL-LOUD contract as
# worktree-new's — "NO `|| true`: a readonly GIT_DIR makes `unset` fail, which
# under `set -e` aborts LOUDLY before any mutation." Without this test a future
# edit adding `|| true` would silently let worktree-rm's DESTRUCTIVE mutations
# (worktree remove / branch -D / config --unset core.worktree) run in a tainted
# env. Pins it: a readonly-exported GIT_DIR/GIT_COMMON_DIR must make worktree-rm
# EXIT NON-ZERO and delete NOTHING — the pre-seeded sandbox worktree+branch stay
# intact and the outer repo is untouched.
#
# Same SOURCING requirement as the worktree-new case above: `declare -rx`'s
# readonly attribute is dropped across `exec`, so the taint must be applied by
# sourcing the script inside a bash that first declared the readonly vars (the
# plain `bash script` form run_in uses would inherit only the value, not the
# readonly-ness, and the unset would succeed). No GIT_SCRUB on the invocation —
# the taint is the point; the script's own guard must abort on it.
test_worktree_rm_readonly_tainted_git_env_fails_loud() {
    local sb outer
    new_sandbox sb
    # Seed the sandbox worktree+branch to (attempt to) remove — scrubbed, safe.
    run_in "$sb" "$WT_NEW" 79
    assert_exit 0 "$RUN_RC" "worktree-new seeds the sandbox worktree+branch"

    # A separate outer repo carrying an identically-named branch: if worktree-rm
    # ran its `git branch -D` in the tainted env it would delete THIS branch.
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch "feature/issue-79" 2>/dev/null || return 1

    # Source worktree-rm inside a child bash that makes GIT_DIR/GIT_COMMON_DIR
    # `declare -rx` BEFORE the script's `unset` runs, so the unset fails and
    # `set -e` aborts before any destructive mutation.
    local out rc=0
    out="$(cd "$sb" &&
        HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" -c \
            'declare -rx GIT_DIR="$2/.git"; declare -rx GIT_COMMON_DIR="$2/.git"; . "$1" 79' \
            _ "$WT_RM" "$outer" 2>&1)" || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" \
        "worktree-rm aborts NON-ZERO under a readonly-tainted git environment (fail-loud)"

    # No mutation: the sandbox's worktree+branch survive, and the outer repo's
    # same-named branch is untouched (no cross-repo delete).
    local sb_branch outer_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-79")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-79")"
    assert_not_empty "$sb_branch" \
        "the sandbox branch survives (aborted before the destructive branch -D)"
    assert_true "[ -e \"$sb/.worktrees/issue-79\" ]" \
        "the sandbox worktree dir survives (aborted before git worktree remove)"
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
    inner="$(command mktemp -d "$WORKDIR/smsub.XXXXXX")" || return 1
    sup="$(command mktemp -d "$WORKDIR/smsuper.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" config user.name "Test"
    command mkdir -p "$inner/bin"
    command printf '#!/bin/sh\n' >"$inner/bin/fix.sh" # lint-allow-path: shebang in generated fixture-script data
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" add bin/fix.sh 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" config user.name "Test"
    command printf 'main\n' >"$sup/app.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" add app.txt 2>/dev/null
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$inner" mod 2>/dev/null; then
        return 2
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" -c commit.gpgsign=false commit -qm "add mod" 2>/dev/null || return 1
    command mkdir -p "$sup/.worktrees/.status" "$sup/.tmux"
    command printf '{}\n' >"$sup/.claude.json"
    # A submodule clone reads the invoking user's GLOBAL config (not the
    # superproject's repo-local config), and run_in pins HOME=$dir, so put
    # protocol.file.allow here to let the file:// submodule clone succeed.
    command printf '[protocol "file"]\n\tallow = always\n' >"$sup/.gitconfig"
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
    command printf 'UNCOMMITTED USER WORK\n' >>"$super/.worktrees/issue-41/app.txt"
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
        git -C "$sb" config core.worktree "$sb/.worktrees/issue-99"
    run_in "$sb" "$WT_RM" 99
    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 while repairing a stale core.worktree"
    assert_contains "$RUN_OUT" "repaired stale core.worktree" "reports the repair"
    local val inside
    val="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config --get core.worktree || true)"
    assert_equals "" "$val" "the stale core.worktree is unset after repair"
    inside="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" rev-parse --is-inside-work-tree 2>/dev/null || true)"
    assert_equals "true" "$inside" "the main checkout is a work tree again after repair"
}

# A core.worktree pointing at an EXISTING path is left untouched — no
# false-positive repair (#258).
test_worktree_rm_preserves_valid_core_worktree() {
    local sb
    new_sandbox sb
    # Point core.worktree at a path that exists on disk (the sandbox itself).
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config core.worktree "$sb"
    run_in "$sb" "$WT_RM" 99
    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 with a valid core.worktree"
    local val
    val="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config --get core.worktree || true)"
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
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a planted cache row"
    assert_contains "$RUN_OUT" "golem-42" "renders the planted golem row"
    assert_contains "$RUN_OUT" "GOLEM" "prints the table header"
}

# Gate age (#422): a fresh dated `gate` renders the "(gated Nm ago)" suffix so a
# stale-vs-fresh gate is visually distinguishable even if a clearing line was
# missed. Plant a cache row (so the BLOCKED section renders) plus a feed gate
# whose `ts` is a recent-but-non-zero age; the render must carry a "(gated …
# ago)" suffix. jq-gated like the sibling BLOCKED tests.
test_status_blocked_shows_gate_age() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot + age derivation need jq)"
        return 0
    fi
    local sb sd ts
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    command cat >"$sd/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    # A gate dated ~2 minutes ago: recent enough to stay inside the TTL, old
    # enough that _fmt_dur renders "2m" (a non-zero, human-visible age).
    ts="$(command date -u -d '130 seconds ago' +%FT%TZ 2>/dev/null ||
        command date -u -v-130S +%FT%TZ 2>/dev/null)"
    command cat >"$sd/feed.jsonl" <<EOF
{"golem":"golem-3","event":"gate","message":"push gate","ts":"$ts"}
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a dated gate"
    assert_contains "$RUN_OUT" "(gated " \
        "the BLOCKED render carries a (gated Nm ago) age suffix (#422)"
}

# --- _gate_age_suffix silent no-op arms (#432 gap 2) ------------------------
#
# _gate_age_suffix has three fall-through arms that each `return 0` with NO
# output: no-jq, no/empty `.ts`, and unparsable `.ts`. The render carries the
# bare BLOCKED line (never an error, never a bogus "0s") on all three. The no-`ts`
# and unparsable-`ts` arms are BOTH reachable end-to-end through the full render
# — a no-`ts` gate bypasses golem-gate-watch.sh's TTL, and (since #432 wrapped the
# snapshot's `fromdateiso8601` in `try … catch`) a malformed-`ts` gate degrades to
# that same fresh fallback and surfaces BLOCKED too, where _gate_age_suffix's own
# `_iso_to_epoch` still cannot parse it → no suffix. The no-jq arm yields an empty
# BLOCKED section upstream, so it is covered by UNIT-testing the helper directly.
# golem-status.sh carries a source guard for exactly this (mirrors
# golem-resolve.sh / golem-gate-watch.sh).

# gate_age_unit <outvar> <sandbox> <golem> <feed> <jq_mode>
#   Source $STATUS inside the sandbox (GIT_*/GOLEM_* scrubbed, HOME pinned, like
#   run_in) and call _gate_age_suffix <golem> <feed>, capturing its stdout into
#   the caller's named variable. <jq_mode> "nojq" stubs jq off PATH (bash-only
#   PATH, BASH_ENV unset so /etc/bash_env cannot restore it — mirrors
#   validate-golem-notify.sh's run_notify nojq); "jq" leaves PATH intact. The
#   source guard means sourcing runs only the helper defs, not the drive.
# The internal capture var is prefixed (`_gau_out`, not `out`) so it can't shadow
# the caller's chosen output variable: `printf -v "$__out"` would otherwise set
# this function's local instead of the caller's, leaving the caller unbound under
# `set -u` when it passes the name `out`.
gate_age_unit() {
    local __out="$1" dir="$2" golem="$3" feed="$4" jq_mode="$5" _gau_out
    if [ "$jq_mode" = "nojq" ]; then
        local stub="$dir/stub-bin"
        command mkdir -p "$stub"
        command ln -sf "$REAL_BASH" "$stub/bash"
        _gau_out="$(cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub" HOME="$dir" \
                GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
                "$REAL_BASH" -c 'source "$1"; _gate_age_suffix "$2" "$3"' \
                _ "$STATUS" "$golem" "$feed" 2>/dev/null || true)"
    else
        _gau_out="$(cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                HOME="$dir" \
                GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
                "$REAL_BASH" -c 'source "$1"; _gate_age_suffix "$2" "$3"' \
                _ "$STATUS" "$golem" "$feed" 2>/dev/null || true)"
    fi
    printf -v "$__out" '%s' "$_gau_out"
}

# no-`ts` arm: the golem's last feed line carries no `.ts` → empty output, no
# error. (This is the arm the render CAN reach; the render-level counterpart is
# test_status_blocked_no_ts_omits_gate_age below.)
test_gate_age_suffix_no_ts_empty() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (_gate_age_suffix reads the feed with jq)"
        return 0
    fi
    local sb out
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/feed.jsonl" <<'EOF'
{"golem":"golem-3","event":"gate","message":"push gate"}
EOF
    gate_age_unit out "$sb" golem-3 "$sb/.worktrees/.status/feed.jsonl" jq
    assert_output_empty "$out" "_gate_age_suffix emits nothing for a no-ts line"
}

# unparsable-`ts` arm: `_iso_to_epoch` returns empty for a non-date `.ts`, so the
# `[ -n "$_gas_epoch" ]` guard trips → empty output, no error (never a bogus 0s).
test_gate_age_suffix_bad_ts_empty() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (_gate_age_suffix reads the feed with jq)"
        return 0
    fi
    local sb out
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/feed.jsonl" <<'EOF'
{"golem":"golem-3","event":"gate","message":"push gate","ts":"not-a-date"}
EOF
    gate_age_unit out "$sb" golem-3 "$sb/.worktrees/.status/feed.jsonl" jq
    assert_output_empty "$out" "_gate_age_suffix emits nothing for an unparsable ts"
}

# no-jq arm: the `command -v jq` guard trips first → empty output, no error, even
# with a perfectly good dated line present (jq stubbed off PATH).
test_gate_age_suffix_no_jq_empty() {
    local sb out ts
    new_sandbox sb
    ts="$(command date -u -d '130 seconds ago' +%FT%TZ 2>/dev/null ||
        command date -u -v-130S +%FT%TZ 2>/dev/null)"
    command cat >"$sb/.worktrees/.status/feed.jsonl" <<EOF
{"golem":"golem-3","event":"gate","message":"push gate","ts":"$ts"}
EOF
    gate_age_unit out "$sb" golem-3 "$sb/.worktrees/.status/feed.jsonl" nojq
    assert_output_empty "$out" "_gate_age_suffix emits nothing when jq is absent"
}

# End-to-end: a no-`ts` gate surfaces in the BLOCKED list (it bypasses the TTL)
# but its render carries NO "(gated … ago)" suffix — the negative counterpart to
# test_status_blocked_shows_gate_age. Proves the fall-through is a clean omission
# at the render level, not just in isolation.
test_status_blocked_no_ts_omits_gate_age() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot needs jq)"
        return 0
    fi
    local sb sd
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    command cat >"$sd/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    # No `ts` → gate-watch treats it as fresh (bypasses TTL) so it surfaces
    # BLOCKED, but _gate_age_suffix can derive no age → no suffix.
    command cat >"$sd/feed.jsonl" <<'EOF'
{"golem":"golem-3","event":"gate","message":"push gate"}
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a no-ts gate"
    # Anchor on the BLOCKED-list render line ("  golem-N — <message>"), not the
    # bare message. (The raw "Recent feed" JSON echo that used to also carry this
    # substring was removed in #488 — the render now prints only a feed line count
    # — but the render-line anchor is the correct assertion regardless.)
    assert_contains "$RUN_OUT" "golem-3 — push gate" "the no-ts gate surfaces in the BLOCKED list"
    assert_not_contains "$RUN_OUT" "(gated " \
        "a no-ts BLOCKED line renders without a (gated Nm ago) suffix (#432)"
}

# Monitoring-integrity regression (#432): a single golem whose most-recent feed
# line carries a NON-EMPTY but malformed `.ts` must NOT blank the whole BLOCKED
# list. golem-gate-watch.sh's snapshot runs ONE `jq -rs` over the entire feed, so
# before the `try … catch` wrap an unparsable `ts` aborted the program (exit 5,
# swallowed by 2>/dev/null) and EVERY golem — even ones with a perfectly good
# `ts` — dropped out of BLOCKED (the #24 blast radius, re-entered through a
# strict-parse failure the null/empty guard doesn't cover). Plant two golems, one
# bad-`ts` and one good-`ts`, and assert BOTH surface: the good one proves the
# abort no longer nukes the list, the bad one proves it degrades to the fresh
# fallback rather than vanishing.
test_status_bad_ts_does_not_blank_blocked_list() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot needs jq)"
        return 0
    fi
    local sb sd good_ts
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    command cat >"$sd/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    command cat >"$sd/golem-5.json" <<'EOF'
{ "golem": "golem-5", "issue": 5, "branch": "feature/issue-5",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    good_ts="$(command date -u -d '60 seconds ago' +%FT%TZ 2>/dev/null ||
        command date -u -v-60S +%FT%TZ 2>/dev/null)"
    # golem-3's most-recent line has a non-empty but unparsable `ts`; golem-5's
    # is well-formed and recent. Pre-fix, golem-3's line aborted the snapshot jq
    # and BOTH vanished.
    command cat >"$sd/feed.jsonl" <<EOF
{"golem":"golem-3","event":"gate","message":"bad-ts gate","ts":"not-a-date"}
{"golem":"golem-5","event":"gate","message":"good-ts gate","ts":"$good_ts"}
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a mixed good/bad ts feed"
    # Anchor on the BLOCKED-LIST line form ("  golem-N — <message>"), NOT a bare
    # substring. The em-dash-separated render line appears ONLY when the golem
    # actually surfaces BLOCKED — a bare `good-ts gate` substring would be a weaker
    # assertion (before #488 the raw "Recent feed" JSON echo also carried it, a
    # classic false pass; that echo is now a one-line count, but the render-line
    # anchor remains the correct discriminator). Verified: reverting the try/catch
    # fails both asserts here.
    assert_contains "$RUN_OUT" "golem-5 — good-ts gate" \
        "the good-ts golem still renders in the BLOCKED list — a sibling's bad ts doesn't blank it (#432)"
    assert_contains "$RUN_OUT" "golem-3 — bad-ts gate" \
        "the bad-ts golem degrades to the fresh fallback and renders BLOCKED, rather than aborting the snapshot (#432)"
}

# The BLOCKED feed pass annotates an escalation/dead-end line that carries a
# brokered-gate id with the inbox state (#395): `[inbox: awaiting|answered|
# consumed]`. A routine permission gate (no gate-id token) stays un-annotated.
# Plant a feed with BOTH a token-carrying escalation and a token-less gate, plus
# a cache row (so render_status proceeds past the "no active golems" guard), and
# an inbox `answer` for the escalation's gate → the escalation line shows
# `[inbox: answered]` while the routine line is untouched. jq-guarded like the
# row test (golem-gate-watch's feed snapshot + golem-inbox's state both need jq).
test_status_annotates_blocked_inbox_state() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot + inbox state need jq)"
        return 0
    fi
    local sb sd gid
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    gid="gate-1784398516-abcd"
    # A cache row so render_status renders the BLOCKED section at all.
    command cat >"$sd/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "feature/issue-7",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    # Feed: a token-carrying escalation (golem-7) + a token-less ROUTINE gate
    # (golem-4) whose command text embeds a gate-SHAPED substring (`fix/gate-…`)
    # that is NOT a bracketed correlation token. Omit `ts` — golem-gate-watch's
    # TTL treats a missing ts as fresh, so the lines surface without clock
    # coupling. The routine line pins the anchored-regex fix: an unanchored scan
    # would falsely annotate it from that substring (the #395 review's Bug 2).
    command cat >"$sd/feed.jsonl" <<EOF
{"golem":"golem-7","event":"escalation","message":"ESCALATION: [$gid] pick sidecar"}
{"golem":"golem-4","event":"gate","message":"Claude needs permission to run: git branch -D fix/gate-1111111111-aaaa"}
EOF
    # An unconsumed answer for the escalation's gate → state should be `answered`.
    inbox_in "$sb" answer golem-7 "$gid" B

    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a planted feed + inbox"
    assert_contains "$RUN_OUT" "[inbox: answered]" \
        "annotates the escalation BLOCKED line with the inbox state"
    # The routine gate carries a gate-SHAPED substring but no bracketed token, so
    # it must stay un-annotated — the anchored `[gate-…]` match ignores it.
    assert_not_contains "$RUN_OUT" "fix/gate-1111111111-aaaa  [inbox:" \
        "a routine gate with a gate-shaped substring stays un-annotated (anchored to [gate-…])"
}

# The gate-id is extracted from the BRACKETED [gate-…] token, not the first
# gate-shaped substring: an escalation message that mentions an older bare
# gate-id before its own bracketed correlation id must query the BRACKETED one
# (the #395 review's Bug 2, wrong-gate variant). Answer the real bracketed gate;
# the annotation must read `answered`, proving it didn't query the stray mention.
test_status_inbox_annotation_uses_bracketed_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot + inbox state need jq)"
        return 0
    fi
    local sb sd real
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    real="gate-2222222222-real"
    command cat >"$sd/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "b", "state": "impl", "phase": "p", "blocking": false }
EOF
    command printf '{"golem":"golem-7","event":"escalation","message":"ESCALATION: after gate-1000000000-old, now [%s] pick sidecar"}\n' \
        "$real" >"$sd/feed.jsonl"
    inbox_in "$sb" answer golem-7 "$real" B
    run_in "$sb" "$STATUS"
    assert_contains "$RUN_OUT" "[inbox: answered]" \
        "queries the bracketed gate-id, not the stray earlier gate-shaped mention"
}

# `awaiting` (no inbox file) and `consumed` (answer + consume) render too — the
# two annotation states the answered case above doesn't cover.
test_status_inbox_state_awaiting_and_consumed() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot + inbox state need jq)"
        return 0
    fi
    local sb sd gid
    # awaiting: token in the feed, no inbox file written.
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    gid="gate-1784398600-aaaa"
    command cat >"$sd/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "b", "state": "impl", "phase": "p", "blocking": false }
EOF
    command printf '{"golem":"golem-7","event":"escalation","message":"ESCALATION: [%s] x"}\n' \
        "$gid" >"$sd/feed.jsonl"
    run_in "$sb" "$STATUS"
    assert_contains "$RUN_OUT" "[inbox: awaiting]" "no inbox answer yet → awaiting"

    # consumed: answer then consume the gate.
    local sb2 sd2 gid2
    new_sandbox sb2
    sd2="$sb2/.worktrees/.status"
    gid2="gate-1784398700-bbbb"
    command cat >"$sd2/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "b", "state": "impl", "phase": "p", "blocking": false }
EOF
    command printf '{"golem":"golem-7","event":"escalation","message":"ESCALATION: [%s] x"}\n' \
        "$gid2" >"$sd2/feed.jsonl"
    inbox_in "$sb2" answer golem-7 "$gid2" B
    inbox_in "$sb2" consume golem-7 "$gid2"
    run_in "$sb2" "$STATUS"
    assert_contains "$RUN_OUT" "[inbox: consumed]" "answer + consume → consumed"
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
            timeout "$secs" "$REAL_BASH" "$STATUS" "$@" 2>&1)" || RUN_RC=$?
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
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
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
    count="$(command printf '%s\n' "$RUN_OUT" | command grep -c '^GOLEM ')"
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

# --- golem-status.sh --checkpoint change-suppression (#488) ------------------

# A no-op --watch checkpoint sweep must not re-emit the whole table. With one
# stable cache row and GOLEM_SWEEP_INTERVAL=1 over a ~3s window, the full
# "STATUS CHECKPOINT" table renders exactly ONCE (first sweep) and every later
# unchanged sweep collapses to a single "no change since" heartbeat line. This is
# the primary AC: two consecutive no-change sweeps emit no repeated full table.
test_status_checkpoint_suppresses_noop_sweep() {
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
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    run_in_watch "$sb" 3 GOLEM_SWEEP_INTERVAL=1 -- --checkpoint --watch --level 3
    assert_exit 0 "$RUN_RC" "bounded --checkpoint --watch loop exits cleanly"
    local table_count
    table_count="$(command printf '%s\n' "$RUN_OUT" | command grep -c '^STATUS CHECKPOINT')"
    assert_true "[ '$table_count' = '1' ]" \
        "the full table renders exactly once across a no-change window (got $table_count)"
    assert_contains "$RUN_OUT" "no change since" \
        "later no-op sweeps collapse to a heartbeat line (proves >=2 sweeps, suppressed)"
}

# render_source_checkpoint <outvar> <sandbox> <interval> — source $STATUS in the
# sandbox (source guard, like gate_age_unit) and call render_checkpoint N times
# IN ONE PROCESS so the module-scope cp_prev_sig persists across calls (the same
# thing the --watch loop relies on). The sequence is fixed here: render once,
# render again unchanged, flip golem-42's .blocking to true, render a third time.
# Captures the combined stdout of all three renders so a single assertion set can
# check "printed → suppressed → re-emitted". Deterministic (no timing).
render_source_seq() {
    local __out="$1" dir="$2" interval="$3" _rss_out
    _rss_out="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c '
                source "$1"
                render_checkpoint "$2"
                render_checkpoint "$2"
                printf "%s" "{ \"golem\": \"golem-42\", \"issue\": 42, \"state\": \"impl\", \"blocking\": true }" \
                    >"$3/golem-42.json"
                render_checkpoint "$2"
            ' _ "$STATUS" "$interval" "$dir/.worktrees/.status" 2>/dev/null || true)"
    printf -v "$__out" '%s' "$_rss_out"
}

# A real row-state change re-emits promptly even after a suppressed sweep. Drive
# render_checkpoint three times in one process: (1) first render prints the table,
# (2) an identical sweep is suppressed to a heartbeat, (3) after flipping .blocking
# the table re-emits with the ⚠ BLOCKED marker. Anchors on the render-line/marker
# forms, never a bare feed echo (repo memory on feed-echo false-passes).
test_status_checkpoint_reemits_on_state_change() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb out table_count
    new_sandbox sb
    command printf '%s' \
        '{ "golem": "golem-42", "issue": 42, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-42.json"
    render_source_seq out "$sb" 60
    # Two full tables total: the first render and the post-flip re-emit. The middle
    # (unchanged) sweep is suppressed, so the count is 2, not 3.
    table_count="$(command printf '%s\n' "$out" | command grep -c '^STATUS CHECKPOINT')"
    assert_true "[ '$table_count' = '2' ]" \
        "table prints on render 1 and re-emits on the state change, but not the unchanged sweep (got $table_count)"
    assert_contains "$out" "no change since" \
        "the unchanged middle sweep is suppressed to a heartbeat"
    assert_contains "$out" "⚠ BLOCKED" \
        "the post-flip re-emit carries the BLOCKED state marker"
}

# The verbose render must NOT dump raw feed JSON (#488) — that was pure
# token-dense duplication of the classified BLOCKED/LIVENESS blocks. Plant a feed
# line with a distinctive marker; the render shows the one-line "Recent feed:"
# count but never the raw JSON.
test_status_verbose_no_raw_feed_dump() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb sd
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    command cat >"$sd/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "feature/issue-7",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    command cat >"$sd/feed.jsonl" <<'EOF'
{"golem":"golem-7","event":"idle","message":"DISTINCTFEEDMARKER working","ts":"2026-07-21T00:00:00Z"}
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "verbose render exits 0 with a planted feed"
    assert_contains "$RUN_OUT" "Recent feed: 1 line(s)" \
        "the verbose render shows a one-line feed count, not the raw JSON tail"
    assert_not_contains "$RUN_OUT" "DISTINCTFEEDMARKER" \
        "the raw feed JSON is no longer echoed into the render (#488)"
}

# render_source_gap <outvar> <sandbox> <interval> — like render_source_seq but the
# MIDDLE sweep hits the empty-state early return (the golem cache file is removed),
# then the SAME golem at the SAME state reappears. Drives render_checkpoint three
# times in one process: (1) render full, (2) remove golem-42.json → "No active
# golems" early return, (3) restore the identical golem-42.json → render again.
render_source_gap() {
    local __out="$1" dir="$2" interval="$3" _rsg_out
    _rsg_out="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c '
                row="{ \"golem\": \"golem-42\", \"issue\": 42, \"state\": \"impl\", \"blocking\": false }"
                source "$1"
                render_checkpoint "$2"
                rm -f "$3/golem-42.json"
                render_checkpoint "$2"
                printf "%s" "$row" >"$3/golem-42.json"
                render_checkpoint "$2"
            ' _ "$STATUS" "$interval" "$dir/.worktrees/.status" 2>/dev/null || true)"
    printf -v "$__out" '%s' "$_rsg_out"
}

# Regression (#488, review Bug 1): a sweep that renders NO table (all golems
# vanished → empty-state early return) is a GAP; the prior signature must be
# cleared so the SAME golem set reappearing at the SAME state is NOT wrongly
# suppressed as "no change". Without the clear, sweep 3 would compare equal to
# sweep 1's signature and hide the vanish→reappear transition behind a heartbeat.
test_status_checkpoint_gap_clears_suppression() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb out table_count
    new_sandbox sb
    command printf '%s' \
        '{ "golem": "golem-42", "issue": 42, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-42.json"
    render_source_gap out "$sb" 60
    # Two full tables: sweep 1 and the post-reappear sweep 3. Sweep 2 is the
    # empty-state early return (no table, no heartbeat). A stale-suppression bug
    # would make this count 1 (sweep 3 suppressed) — the discriminator.
    table_count="$(command printf '%s\n' "$out" | command grep -c '^STATUS CHECKPOINT')"
    assert_true "[ '$table_count' = '2' ]" \
        "the reappearing golem re-renders in full after an empty-state gap, not a heartbeat (got $table_count)"
    assert_contains "$out" "No active golems" \
        "the middle sweep hit the empty-state early return (the gap)"
    assert_not_contains "$out" "no change since" \
        "the reappear is never collapsed to a heartbeat — the gap cleared the prior signature (#488)"
}

# Regression (#488, review Bug 2): the blank separator line between the pool
# header and the STATUS CHECKPOINT title (present in the pre-#488 render) must
# survive the buffer restructure — a byte-layout parity check.
test_status_checkpoint_pool_header_blank_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-9.json" <<'EOF'
{ "golem": "golem-9", "issue": 9, "state": "impl", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/pool.json" <<'EOF'
{ "size": 3, "slots": [1, 2], "backlog_depth": 5, "accepting": "open" }
EOF
    run_in "$sb" "$STATUS" --checkpoint
    assert_exit 0 "$RUN_RC" "one-shot --checkpoint with a pool exits 0"
    # The pool line, a blank line, then the title — the exact three-line sequence.
    assert_contains "$RUN_OUT" "queue=open"$'\n'$'\n'"STATUS CHECKPOINT" \
        "a blank line separates the pool header from the checkpoint title (#488)"
}

# Regression (#488, review Bug 3): a one-shot --checkpoint (no --watch) must still
# surface the cache-mirror caveat (on stderr) — the relocation from per-sweep to
# once-at-startup must not drop it from the one-shot snapshot path.
test_status_checkpoint_oneshot_shows_cache_mirror_note() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-9.json" <<'EOF'
{ "golem": "golem-9", "issue": 9, "state": "impl", "blocking": false }
EOF
    run_in "$sb" "$STATUS" --checkpoint
    assert_exit 0 "$RUN_RC" "one-shot --checkpoint exits 0"
    # run_in merges stdout+stderr; the caveat lands on stderr but is captured here.
    assert_contains "$RUN_OUT" "PR/CI/Review are cache mirrors" \
        "the one-shot --checkpoint still prints the cache-mirror caveat (#488)"
}

# Regression (#488, review follow-up): the heartbeat's golem count uses a
# `grep -o '|' | wc -l` count, NOT `grep -c '|'` — GNU grep -c exits 1 on a zero
# count, which with a `|| echo 0` fallback double-appends and splits the heartbeat
# across two lines. The bug ONLY surfaces when cp_sig has zero `|` rows: a
# pool.json present (so the empty-state early return is skipped) but no golem
# cache rows and no live sessions. Drive render_checkpoint twice in-process; the
# suppressed 2nd sweep must be a SINGLE line reading "(0 golem(s))".
test_status_checkpoint_zero_golem_heartbeat_single_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb out hb_lines
    new_sandbox sb
    # pool.json only — no golem-*.json, no tmux sessions (TMUX_TMPDIR is empty).
    command cat >"$sb/.worktrees/.status/pool.json" <<'EOF'
{ "size": 3, "slots": [], "backlog_depth": 0, "accepting": "open" }
EOF
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c 'source "$1"; render_checkpoint "$2"; render_checkpoint "$2"' \
            _ "$STATUS" 60 2>/dev/null || true)"
    # The suppressed sweep's heartbeat must be exactly one line with (0 golem(s)) —
    # a split count renders "(0" and "0 golem(s))" on two lines.
    assert_contains "$out" "no change since" \
        "the zero-golem sweep is suppressed to a heartbeat"
    assert_contains "$out" "(0 golem(s))" \
        "the zero-golem heartbeat count is a clean single-line 0, not a split grep -c count (#488)"
    hb_lines="$(command printf '%s\n' "$out" | command grep -c 'golem(s))')"
    assert_true "[ '$hb_lines' = '1' ]" \
        "the heartbeat 'golem(s)' phrase renders on exactly one line (got $hb_lines)"
}

# render_source_multi <outvar> <sandbox> <interval> — three in-process renders
# over a MULTI-golem batch (the real use case, not the single-row fixtures the
# other #488 tests use): render full, render again unchanged (all suppressed),
# then flip ONLY golem-2's .blocking and render again — the whole table must
# re-emit (coarse-grained) with golem-2 ⚠ BLOCKED and the others still present.
render_source_multi() {
    local __out="$1" dir="$2" interval="$3" _rsm_out
    _rsm_out="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c '
                source "$1"
                render_checkpoint "$2"
                render_checkpoint "$2"
                printf "%s" "{ \"golem\": \"golem-2\", \"issue\": 2, \"state\": \"impl\", \"blocking\": true }" \
                    >"$3/golem-2.json"
                render_checkpoint "$2"
            ' _ "$STATUS" "$interval" "$dir/.worktrees/.status" 2>/dev/null || true)"
    printf -v "$__out" '%s' "$_rsm_out"
}

# Regression (#488, review test-coverage finding): the suppression signature is
# built by concatenating EVERY row's golem|statecol across a batch. With 3 golems,
# an unchanged sweep must suppress the whole table, and flipping ONE golem's state
# must re-emit the whole table (all three rows) — the coarse-grained guarantee the
# feature exists for. Asserts the exact 3-count heartbeat too.
test_status_checkpoint_multi_golem_batch_suppression() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb out table_count
    new_sandbox sb
    command printf '%s' '{ "golem": "golem-1", "issue": 1, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-1.json"
    command printf '%s' '{ "golem": "golem-2", "issue": 2, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-2.json"
    command printf '%s' '{ "golem": "golem-3", "issue": 3, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-3.json"
    render_source_multi out "$sb" 60
    # Full table on sweep 1 and the post-flip sweep 3; sweep 2 suppressed.
    table_count="$(command printf '%s\n' "$out" | command grep -c '^STATUS CHECKPOINT')"
    assert_true "[ '$table_count' = '2' ]" \
        "the 3-golem batch renders once, suppresses the unchanged sweep, and re-emits the whole table on a single-row flip (got $table_count)"
    assert_contains "$out" "(3 golem(s))" \
        "the heartbeat counts all three batch rows"
    assert_contains "$out" "⚠ BLOCKED" \
        "the re-emitted table carries golem-2's flipped BLOCKED state"
    # All three rows are present in the re-emitted table (coarse-grained re-emit,
    # not just the changed row) — golem-1 and golem-3 render alongside golem-2.
    assert_contains "$out" "golem-1" "golem-1 is still rendered in the re-emitted table"
    assert_contains "$out" "golem-3" "golem-3 is still rendered in the re-emitted table"
}

# --- golem-token-scrape.sh + golem-status token signal (#371) ---------------

# slug_for <abs-worktree-path> — the Claude Code project-dir slug for a worktree:
# its absolute path with every `/` and `.` replaced by `-`. Mirrors the
# derivation in golem-token-scrape.sh so fixtures land where the script looks.
slug_for() {
    local p="$1"
    command echo "${p//[\/.]/-}"
}

# plant_transcript <sandbox> <issue-N> <jsonl-body> — write a Claude Code session
# transcript for the sandbox's issue-N worktree under a fake projects base
# ($sb/projects), so golem-token-scrape.sh (CLAUDE_PROJECTS_DIR pointed there)
# resolves it. The body is raw JSONL (one record per line).
plant_transcript() {
    local sb="$1" n="$2" body="$3"
    local wt="$sb/.worktrees/issue-$n"
    local slug dir
    slug="$(slug_for "$wt")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    command printf '%s\n' "$body" >"$dir/session.jsonl"
}

# run_scrape <sandbox> <worktree-arg> — invoke golem-token-scrape.sh with the
# projects base pointed at the sandbox's fake $sb/projects. Captures RUN_RC/RUN_OUT.
run_scrape() {
    local sb="$1" arg="$2"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$SCRAPE" "$arg" 2>&1)" || RUN_RC=$?
}

# run_status_scrape <sandbox> [args...] — like run_in for golem-status.sh but with
# CLAUDE_PROJECTS_DIR pointed at the sandbox's fake projects base so the token
# scrape resolves planted transcripts. Captures RUN_RC/RUN_OUT.
run_status_scrape() {
    local sb="$1"
    shift
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$STATUS" "$@" 2>&1)" || RUN_RC=$?
}

# A transcript body with mixed sidechain records mirroring the REAL on-disk shape:
# Claude Code writes one line per assistant CONTENT BLOCK, all sharing the turn's
# message.id and repeating the same output_tokens. Here turn "m1" spans THREE
# blocks (output_tokens 100 x3 — must be counted ONCE) and turn "m2" is one block
# (50), for a correct top-level total of 150. One SUB-WORKFLOW record
# (output_tokens 999) MUST be excluded; a summary record carries no usage. A
# naive per-line sum would wrongly count 100x3 + 50 = 350 — so this fixture pins the
# message.id dedup (bug caught in #371 pre-PR review).
TRANSCRIPT_MIXED='{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}
{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}
{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}
{"isSidechain":true,"message":{"id":"s1","usage":{"output_tokens":999}}}
{"isSidechain":false,"message":{"id":"m2","usage":{"output_tokens":50}}}
{"type":"summary"}'

# A transcript whose every usage-bearing record is a SUB-WORKFLOW (isSidechain
# true) — no top-level output yet. The scrape's `add // 0` must yield the
# documented `0`, and golem-status must render "0 tokens (first reading)", NOT
# "tokens unknown" (a real 0 is a digit, distinct from an empty/failed scrape).
TRANSCRIPT_ALL_SIDECHAIN='{"isSidechain":true,"message":{"id":"s1","usage":{"output_tokens":100}}}
{"isSidechain":true,"message":{"id":"s2","usage":{"output_tokens":50}}}
{"type":"summary"}'

# iso_ago <seconds> — an ISO-8601 Z timestamp <seconds> in the past, in the same
# %FT%TZ shape golem-status.sh's _now_iso writes. Uses the same GNU-then-BSD
# `date` toolchain the script's _iso_to_epoch parses, so a seeded anchor maps
# back to a frozen-duration in the expected band. Prints nothing on failure.
iso_ago() {
    local n="$1" now past
    now="$(command date -u +%s)"
    past=$((now - n))
    command date -u -d "@$past" +%FT%TZ 2>/dev/null && return 0
    command date -u -r "$past" +%FT%TZ 2>/dev/null && return 0
    return 1
}

# scrape sums TOP-LEVEL output_tokens only, deduped by message.id (150),
# excluding the sidechain 999 and never multi-counting the 3-block turn m1.
test_scrape_sums_top_level_only() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "scrape of a planted transcript exits 0"
    # Exact match (not a substring) so the naive per-line sum 350 can't slip past
    # a loose "contains 150" — the whole point of the #371 dedup fix.
    assert_true "[ '$RUN_OUT' = '150' ]" "sums top-level output_tokens deduped by message.id (150, got '$RUN_OUT')"
    assert_not_contains "$RUN_OUT" "350" "the 3-block turn m1 is counted once, not per-line (naive sum 350 is the regression)"
    assert_not_contains "$RUN_OUT" "999" "the sub-workflow token count is excluded"
}

# No transcript directory → fail-loud (exit 2 + message), never a silent 0.
test_scrape_missing_transcript_fails_loud() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "scrape with no transcript dir exits 2 (fail-loud)"
    assert_contains "$RUN_OUT" "no transcript dir" "names the missing transcript"
}

# TRULY no worktree arg (argc 0) → usage error, exit 1. `run_scrape` passes an
# empty-STRING positional (argc 1), which reaches the transcript-missing path
# (exit 2), so invoke the script directly with no positional at all here.
test_scrape_no_arg_exits_1() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$SCRAPE" 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "scrape with no argument exits 1 (usage)"
    assert_contains "$RUN_OUT" "usage:" "prints the usage message on the no-arg path"
}

# Newest-mtime *.jsonl wins when multiple sessions exist (post-/clear fresh file).
test_scrape_newest_session_wins() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    local slug dir
    slug="$(slug_for "$sb/.worktrees/issue-42")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    command printf '%s\n' '{"isSidechain":false,"message":{"usage":{"output_tokens":10}}}' >"$dir/old.jsonl"
    # Ensure a distinct, newer mtime on the second file.
    command sleep 1
    command printf '%s\n' '{"isSidechain":false,"message":{"usage":{"output_tokens":77}}}' >"$dir/new.jsonl"
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "scrape with two sessions exits 0"
    assert_contains "$RUN_OUT" "77" "the newest-mtime session (77) is the one summed"
}

# A truncated/malformed trailing line (expected when a session is captured
# mid-write) is skipped, and the valid records before it still sum correctly.
test_scrape_tolerates_truncated_trailing_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb slug dir
    new_sandbox sb
    slug="$(slug_for "$sb/.worktrees/issue-42")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    # Two valid top-level records (60) then a truncated final line (no newline,
    # unterminated JSON) — the fromjson? guard must drop it without aborting.
    {
        command printf '%s\n' '{"isSidechain":false,"message":{"id":"a","usage":{"output_tokens":40}}}'
        command printf '%s\n' '{"isSidechain":false,"message":{"id":"b","usage":{"output_tokens":20}}}'
        command printf '%s' '{"isSidechain":false,"message":{"usage":{'
    } >"$dir/session.jsonl"
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "scrape tolerates a truncated trailing line (exit 0)"
    assert_true "[ '$RUN_OUT' = '60' ]" "sums the valid records (60), dropping the truncated line (got '$RUN_OUT')"
}

# jq missing on PATH → fail-loud exit 3, independent of whether the host has jq.
# A stub bin dir with a shadowing non-jq PATH exercises the version-gate arm.
test_scrape_no_jq_exits_3() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/nojq-bin"
    # A PATH holding only coreutils the script needs (via /usr/bin) but NO jq. We
    # point PATH at an empty stub dir plus /usr/bin sans jq is hard to guarantee,
    # so instead prepend a stub dir and drop /usr/bin's jq by pointing PATH at a
    # curated dir. Simplest portable approach: PATH= the stub dir only, and the
    # script's `command -v jq` fails. bash builtins still work; /usr/bin/* calls in
    # the script use absolute paths so they survive the stripped PATH.
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$sb/nojq-bin" \
            "$REAL_BASH" "$SCRAPE" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "scrape with no jq on PATH exits 3 (fail-loud)"
    assert_contains "$RUN_OUT" "jq not found" "names jq as the missing dependency"
}

# --- golem-transcript-liveness.sh (#248) ------------------------------------
# Direct unit coverage of the transcript classifier — the working/idle/errored
# read and its fail-loud exit codes. It resolves the SAME <projects>/<slug>/
# transcript as golem-token-scrape.sh (reusing plant_transcript/slug_for above),
# so the fixtures land where the script looks. The gate-watch suite exercises this
# script through liveness_snapshot's wiring; these pin its own contract in
# isolation.

# run_liveness <sandbox> <worktree-arg> — invoke golem-transcript-liveness.sh with
# the projects base pointed at the sandbox's fake $sb/projects. Captures
# RUN_RC/RUN_OUT.
run_liveness() {
    local sb="$1" arg="$2"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$TRANSCRIPT_LIVENESS" "$arg" 2>&1)" || RUN_RC=$?
}

# A last top-level assistant turn still in flight (stop_reason "tool_use") → working.
test_liveness_working() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a turn-in-flight transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'working' ]" "classifies working (got '$RUN_OUT')"
}

# A last top-level assistant turn that ENDED (stop_reason "end_turn") → idle.
test_liveness_idle() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a turn-ended transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'idle' ]" "classifies idle (got '$RUN_OUT')"
}

# isApiErrorMessage on the last top-level assistant record → errored.
test_liveness_errored_api() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"isApiErrorMessage":true,"message":{"stop_reason":"stop_sequence"}}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "an API-error transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'errored' ]" "classifies errored (got '$RUN_OUT')"
}

# A trailing "Unknown command" system record with NO top-level turn yet is the
# literal #229 first-command failure → errored (not indeterminate).
test_liveness_errored_unknown_command() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"system","subtype":"informational","content":"Unknown command: /workflow:next-issue"}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "an unknown-command transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'errored' ]" "classifies errored (got '$RUN_OUT')"
}

# The OTHER errored-via-Unknown-command path (#248 review): an assistant turn that
# already ENDED (end_turn) followed by a trailing "Unknown command" system record
# promotes idle → errored via the `.key > $last.key` ordering branch. The sibling
# test above exercises the no-top-level-turn branch; this pins the ordering branch,
# which would silently degrade to a plain 'idle' on an off-by-one.
test_liveness_errored_unknown_command_after_idle_turn() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        "$(command printf '%s\n%s' \
            '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}' \
            '{"type":"system","content":"Unknown command: /workflow:next-issue"}')"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "an idle-turn+trailing-unknown-command transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'errored' ]" "idle turn + trailing Unknown command promotes to errored (got '$RUN_OUT')"
}

# A sub-workflow (isSidechain true) tool_use record must NOT mask a top-level idle.
test_liveness_sidechain_not_masking() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        "$(command printf '%s\n%s' \
            '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}' \
            '{"type":"assistant","isSidechain":true,"message":{"stop_reason":"tool_use"}}')"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a mixed sidechain transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'idle' ]" "top-level idle not masked by sidechain tool_use (got '$RUN_OUT')"
}

# No transcript dir → fail-loud (exit 2 + message), never a silent class. This is
# the Mode-3-container / no-host-transcript path the caller falls back from.
test_liveness_missing_transcript_fails_loud() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "no transcript dir exits 2 (fail-loud)"
    assert_contains "$RUN_OUT" "no transcript dir" "names the missing transcript dir"
}

# A transcript with records but no top-level turn and no command error is
# indeterminate → exit 2 (the caller falls back to the mtime heartbeat).
test_liveness_indeterminate_exits_2() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 '{"type":"user","message":{"role":"user"}}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "an indeterminate transcript exits 2"
    assert_contains "$RUN_OUT" "indeterminate" "names the indeterminate condition"
}

# No worktree argument → usage error (exit 1).
test_liveness_no_arg_exits_1() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" "$REAL_BASH" "$TRANSCRIPT_LIVENESS" 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "no worktree arg exits 1 (usage)"
    assert_contains "$RUN_OUT" "usage:" "prints usage on the no-arg path"
}

# Missing jq on PATH → exit 3 fail-loud (mirrors test_scrape_no_jq_exits_3).
test_liveness_no_jq_exits_3() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/nojq-bin"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$sb/nojq-bin" \
            "$REAL_BASH" "$TRANSCRIPT_LIVENESS" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "transcript-liveness with no jq on PATH exits 3 (fail-loud)"
    assert_contains "$RUN_OUT" "jq not found" "names jq as the missing dependency"
}

# A relative worktree arg resolves to the same slug as its absolute form (mirrors
# test_scrape_relative_worktree_path — the pwd-prefix branch of the slug logic).
test_liveness_relative_worktree_path() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    # cd into the sandbox and pass the RELATIVE path — pwd-prefixing must land on
    # the same slug the absolute-path plant used.
    run_liveness "$sb" ".worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a relative worktree arg resolves (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "relative arg classifies working like the absolute one (got '$RUN_OUT')"
}

# Staleness bound (#248 review): a `working` verdict whose transcript has sat
# unmodified past GOLEM_STALL_THRESHOLD is DEMOTED to indeterminate (exit 2) — a
# crashed process frozen at stop_reason:"tool_use" must NOT read `working`
# forever, or the caller's mtime stall check is permanently short-circuited.
test_liveness_stale_working_demoted() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb tfile
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    # Backdate the planted session transcript well past the default 1200s window.
    tfile="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")/session.jsonl"
    command touch -d "@$(($(command date +%s) - 3600))" "$tfile"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "a stale 'working' transcript is demoted to indeterminate (exit 2)"
    assert_contains "$RUN_OUT" "stale 'working'" "names the staleness demotion"
}

# The staleness window is GOLEM_STALL_THRESHOLD-overridable: the same stale
# transcript above still reads `working` when the threshold is widened past its
# age (guards the env plumbing, symmetric to test_liveness_stale_working_demoted).
test_liveness_stale_working_threshold_overridable() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb tfile
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    tfile="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")/session.jsonl"
    command touch -d "@$(($(command date +%s) - 3600))" "$tfile"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            GOLEM_STALL_THRESHOLD=7200 \
            "$REAL_BASH" "$TRANSCRIPT_LIVENESS" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "a widened threshold keeps the 3600s-old transcript 'working' (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "GOLEM_STALL_THRESHOLD widens the staleness window (got '$RUN_OUT')"
}

# A stale IDLE transcript is NOT demoted — only `working` is mtime-gated. A golem
# parked/errored at its prompt for a long time is still correctly idle, and that
# is the actionable signal (guards against over-broad staleness gating).
test_liveness_stale_idle_not_demoted() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb tfile
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}'
    tfile="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")/session.jsonl"
    command touch -d "@$(($(command date +%s) - 3600))" "$tfile"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a long-idle transcript still classifies (exit 0)"
    assert_true "[ '$RUN_OUT' = 'idle' ]" "a stale idle transcript is not demoted (got '$RUN_OUT')"
}

# Fail-open on the staleness guard (#248 review): when the transcript's mtime is
# UNREADABLE (stat fails / returns non-numeric), the guard is skipped and the raw
# `working` class is trusted, rather than a stat quirk demoting a possibly-live
# golem. Force it by stubbing `stat` to emit garbage on a PATH that still carries
# real bash/git/jq — the script reaches stat via `command stat`, so the stub wins.
test_liveness_stale_working_stat_failure_fails_open() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb stub real_bash real_git real_jq
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    stub="$sb/stub-bin"
    command mkdir -p "$stub"
    real_bash="$(command -v bash)"
    real_git="$(command -v git)"
    real_jq="$(command -v jq)"
    command ln -s "$real_bash" "$stub/bash"
    command ln -s "$real_git" "$stub/git"
    command ln -s "$real_jq" "$stub/jq"
    # A `stat` that always emits non-numeric garbage and exits 0 — the script's
    # `command stat` resolves this stub, so _newest_mtime is non-numeric and the
    # guard's `'' | *[!0-9]*)` fail-open arm must fire (trust the class).
    command printf '%s\n' '#!/usr/bin/env bash' 'echo not-a-number' >"$stub/stat"
    command chmod +x "$stub/stat"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$stub:/usr/bin:/bin" \
            "$real_bash" "$TRANSCRIPT_LIVENESS" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "an unreadable mtime fails open on the guard (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "a non-numeric stat result trusts the class, not a demotion (got '$RUN_OUT')"
}

# Newest-mtime session wins (#248 review, mirrors test_scrape_newest_session_wins):
# two sessions in the same project dir with different classes — the newer one's
# class is reported.
test_liveness_newest_session_wins() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb dir
    new_sandbox sb
    dir="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")"
    command mkdir -p "$dir"
    # Older session: idle. Newer session: working. The newer must win.
    command printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}' \
        >"$dir/old.jsonl"
    command touch -d "@$(($(command date +%s) - 600))" "$dir/old.jsonl"
    command printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}' \
        >"$dir/new.jsonl"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a two-session dir resolves (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "the newest-mtime session's class wins (got '$RUN_OUT')"
}

# A truncated/malformed trailing JSONL line is tolerated (#248 review, mirrors
# test_scrape_tolerates_truncated_trailing_line): `fromjson? // empty` skips it and
# the valid record above still classifies.
test_liveness_tolerates_truncated_trailing_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        "$(command printf '%s\n%s' \
            '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}' \
            '{"type":"assistant","isSid')"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a truncated trailing line does not abort classification (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "the valid record classifies despite a truncated trailing line (got '$RUN_OUT')"
}

# golem-status renders the TOP-LEVEL TOKENS section: first read shows the count,
# a second read with an UNCHANGED transcript shows 'frozen', and the cache JSON
# gains top_level_tokens + top_level_tokens_at.
test_status_token_first_then_frozen() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a token transcript exits 0"
    assert_contains "$RUN_OUT" "TOP-LEVEL TOKENS" "renders the token section"
    assert_contains "$RUN_OUT" "150 tokens (first reading)" "first read shows the count as a first reading"
    # The cache JSON now carries both persisted fields.
    local persisted
    persisted="$(jq -r '.top_level_tokens' "$sb/.worktrees/.status/golem-42.json" 2>/dev/null)"
    assert_true "[ '$persisted' = '150' ]" "top_level_tokens persisted to the cache (got $persisted)"
    local anchor1
    anchor1="$(jq -r '.top_level_tokens_at' "$sb/.worktrees/.status/golem-42.json" 2>/dev/null)"
    assert_true "[ -n '$anchor1' ] && [ '$anchor1' != 'null' ]" \
        "top_level_tokens_at anchor persisted to the cache (got $anchor1)"
    # Second render, transcript unchanged → frozen. The anchor MUST be carried
    # forward byte-identically, not reset to now() each sweep — a reset-every-sweep
    # regression would still render "150 tokens, frozen 0s" and pass a substring
    # check, but it defeats the whole freeze-duration signal, so assert the
    # persisted anchor is unchanged across the two sweeps.
    command sleep 1
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "150 tokens, frozen" "second read with an unchanged count shows frozen"
    local anchor2
    anchor2="$(jq -r '.top_level_tokens_at' "$sb/.worktrees/.status/golem-42.json" 2>/dev/null)"
    assert_true "[ '$anchor2' = '$anchor1' ]" \
        "the frozen-since anchor is carried forward unchanged, not reset each sweep ($anchor1 -> $anchor2)"
}

# A changed transcript between sweeps shows 'advancing', not 'frozen'.
test_status_token_advancing_on_change() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    plant_transcript "$sb" 42 '{"isSidechain":false,"message":{"usage":{"output_tokens":100}}}'
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "100 tokens (first reading)" "first read shows 100"
    # Grow the transcript's top-level tokens, then re-render.
    local slug dir
    slug="$(slug_for "$sb/.worktrees/issue-42")"
    dir="$sb/projects/$slug"
    command printf '%s\n' \
        '{"isSidechain":false,"message":{"usage":{"output_tokens":100}}}' \
        '{"isSidechain":false,"message":{"usage":{"output_tokens":25}}}' >"$dir/session.jsonl"
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "125 tokens (advancing)" "a grown count reads as advancing, not frozen"
}

# A Mode-3 container golem whose host-POST has NOT landed yet (no token fields, or
# a non-numeric one) shows the graceful "awaiting token push" note and is NEVER
# scraped (no bogus frozen reading). (#390)
test_status_token_container_pending() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with an unposted container row exits 0"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "a Mode-3 container golem with no posted usage shows the awaiting-push note (#390)"
    assert_not_contains "$RUN_OUT" "agent01 — 0 tokens" "a container golem is never scraped to a bogus 0"
}

# A Mode-3 container golem whose host-POST HAS landed (top_level_tokens + a stale
# top_level_tokens_at written by the container producer) renders the SAME mechanical
# "frozen Xm" phrase as a Mode-2 golem, and golem-status READS those fields WITHOUT
# rewriting them (the producer owns the fields; a host rewrite would race the POST).
# (#390)
test_status_token_container_populated() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    # A stale anchor ~130s in the past → _fmt_dur's minutes arm ("frozen Nm").
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242, "top_level_tokens_at": "$anchor" }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a populated container row exits 0"
    assert_contains "$RUN_OUT" "4242 tokens, frozen" \
        "a posted container golem renders the mechanical frozen phrase, same as Mode 2 (#390)"
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq '4242 tokens, frozen [0-9]+m'" \
        "the seeded ~130s anchor renders _fmt_dur's minutes arm ('frozen Nm')"
    assert_not_contains "$RUN_OUT" "awaiting token push" "a posted container is not shown as pending"
    # READ-ONLY: golem-status must not rewrite the producer-owned fields.
    local tok_after at_after
    tok_after="$(jq -r '.top_level_tokens' "$sb/.worktrees/.status/agent01.json" 2>/dev/null)"
    at_after="$(jq -r '.top_level_tokens_at' "$sb/.worktrees/.status/agent01.json" 2>/dev/null)"
    assert_true "[ '$tok_after' = '4242' ]" "top_level_tokens is not rewritten by golem-status (got $tok_after)"
    assert_true "[ '$at_after' = '$anchor' ]" \
        "top_level_tokens_at anchor is read as-is, never reset to now() (got $at_after)"
}

# A Mode-3 container row whose externally-POSTed fields are MALFORMED degrades to
# the graceful container-pending note, never a bogus frozen render — the cache is
# co-written / the POST is untrusted, so each field is guarded: a corrupt count
# (leading-zero "089", overflow, non-numeric) and a non-ISO anchor ("now", which
# GNU `date -d` would otherwise parse into a plausible-but-wrong duration) must
# both blank out. Mirrors test_status_checkpoint_corrupt_prev_tokens_no_drop for
# the Mode-2 persisted prior. (#390)
test_status_token_container_malformed_degrades() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb good_anchor
    new_sandbox sb
    good_anchor="$(iso_ago 130)"
    if [ -z "$good_anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    # (a) A leading-zero count ("089" — the octal hazard) with a VALID anchor →
    # the count blanks → container-pending, never a bash arithmetic error.
    command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": "089", "top_level_tokens_at": "$good_anchor" }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "a container row with a corrupt count still exits 0"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "a leading-zero posted count degrades to container-pending, not a bogus frozen (#390)"
    assert_not_contains "$RUN_OUT" "089 tokens" "the octal-hazard count is never rendered as a frozen reading"
    # (b) A VALID count with a NON-ISO anchor ("now") → the anchor blanks →
    # container-pending, never a plausible-but-wrong `date -d "now"` duration.
    command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242, "top_level_tokens_at": "now" }
EOF
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "a non-ISO anchor degrades to container-pending, never a date -d-parsed bogus duration (#390)"
    assert_not_contains "$RUN_OUT" "4242 tokens, frozen" "a malformed anchor never renders a frozen duration"
}

# A Mode-3 container row with only ONE of the two fields posted (an asymmetric /
# racing partial POST) degrades to container-pending — the branch requires BOTH
# count AND anchor. Guards against a `&&`→`||` regression that would render a
# frozen phrase with a missing anchor or crash _frozen_phrase on an empty $2. (#390)
test_status_token_container_partial_post() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    # Count present, anchor absent.
    command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242 }
EOF
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "count present but anchor absent degrades to container-pending (#390)"
    assert_not_contains "$RUN_OUT" "4242 tokens, frozen" "a count-only partial POST never renders a frozen phrase"
    # Anchor present, count absent.
    command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens_at": "$anchor" }
EOF
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "anchor present but count absent degrades to container-pending (#390)"
}

# A Mode-2 golem with no transcript shows 'tokens unknown', never a bogus frozen.
test_status_token_unknown_no_transcript() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-77.json" <<'EOF'
{ "golem": "golem-77", "issue": 77, "branch": "feature/issue-77",
  "state": "working", "blocking": false }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a transcript-less golem exits 0"
    assert_contains "$RUN_OUT" "tokens unknown (no transcript)" \
        "a Mode-2 golem with no transcript shows tokens unknown"
    # "frozen" alone would match the section header ("frozen-counter signal"); pin
    # the render form instead — an unknown-token golem must never show "frozen Xm".
    assert_not_contains "$RUN_OUT" "tokens, frozen" "an unknown-token golem never reports a frozen duration"
}

# An UNPARSABLE stored anchor (top_level_tokens_at that `date` cannot read) →
# _iso_to_epoch returns empty → the render falls back to the raw "frozen since
# <iso>" branch, never a bogus "frozen 0s". Deterministic (no timing).
test_status_frozen_iso_parse_failure_raw_render() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # Seed a matching prior count (150 = what TRANSCRIPT_MIXED scrapes to) so the
    # sweep reads UNCHANGED → frozen, plus a garbage anchor `date` cannot parse.
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "top_level_tokens": 150, "top_level_tokens_at": "not-a-date" }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with an unparsable anchor exits 0"
    assert_contains "$RUN_OUT" "frozen since not-a-date" \
        "an unparsable anchor renders the raw 'frozen since <iso>' fallback"
    # A parse failure must NOT masquerade as a computed duration.
    assert_not_contains "$RUN_OUT" "150 tokens, frozen 0" \
        "the parse-failure branch never emits a bogus computed 'frozen 0s'"
}

# _fmt_dur's SECONDS arm (<60): an anchor ~20s in the past renders "frozen Ns".
test_status_fmt_dur_seconds_arm() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 20)"
    if [ -z "$anchor" ]; then
        skip_test "date could not compute a past anchor"
        return 0
    fi
    command cat >"$sb/.worktrees/.status/golem-42.json" <<EOF
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "top_level_tokens": 150, "top_level_tokens_at": "$anchor" }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a ~20s anchor exits 0"
    # ~20s is well below the 60s boundary, so a few seconds of test latency can't
    # flip the arm. Match the render form, not an exact second count.
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq 'frozen [0-9]+s'" \
        "an anchor under 60s renders _fmt_dur's seconds arm ('frozen Ns')"
    assert_not_contains "$RUN_OUT" "frozen 0m" "a sub-minute freeze never rounds to minutes"
}

# _fmt_dur's MINUTES arm (>=60): an anchor ~130s in the past renders "frozen Nm".
test_status_fmt_dur_minute_arm() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date could not compute a past anchor"
        return 0
    fi
    command cat >"$sb/.worktrees/.status/golem-42.json" <<EOF
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "top_level_tokens": 150, "top_level_tokens_at": "$anchor" }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a ~130s anchor exits 0"
    # ~130s is well above the 60s boundary (renders "2m"), clear of test latency.
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq 'frozen [0-9]+m'" \
        "an anchor at/above 60s renders _fmt_dur's minutes arm ('frozen Nm')"
    # And NO token line renders the seconds form — a bogus dual-render (minute +
    # second line for the same golem) must fail. `grep -q` matches any line, so
    # `!` is true only when zero lines carry a 'tokens, frozen Ns' form. (An
    # earlier `grep -Evq` was tautological: header/other lines always fail the
    # match, so per-line inversion was unconditionally true — #392 pre-PR review.)
    assert_true "! printf '%s' \"\$RUN_OUT\" | command grep -Eq 'tokens, frozen [0-9]+s'" \
        "the minutes arm never also emits a seconds-form freeze line"
}

# The scrape resolves a RELATIVE worktree arg against the cwd (the
# `*) abs="$(command pwd)/$worktree"` branch) to the same slug/count an absolute
# path yields. Every other scrape test passes an absolute path.
test_scrape_relative_worktree_path() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    # Invoke with cwd = $sb and a RELATIVE worktree arg, so the script prepends
    # $(command pwd) and must land on the same $sb/.worktrees/issue-42 slug.
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$SCRAPE" ".worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "scrape of a relative worktree path exits 0"
    assert_true "[ '$RUN_OUT' = '150' ]" \
        "a relative worktree arg resolves to the same slug/count as absolute (150, got '$RUN_OUT')"
}

# Zero-token end-to-end: an all-sidechain transcript scrapes to `0` (exit 0), and
# golem-status renders "0 tokens (first reading)", NOT "tokens unknown".
test_scrape_and_status_zero_tokens() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape + status token block need jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_ALL_SIDECHAIN"
    # (a) the scrape itself prints a literal 0, exit 0 — never fails loud on an
    #     all-sidechain transcript (no top-level output *yet* is a valid 0).
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "scrape of an all-sidechain transcript exits 0"
    assert_true "[ '$RUN_OUT' = '0' ]" "an all-sidechain transcript scrapes to 0 (got '$RUN_OUT')"
    # (b) golem-status renders the 0 as a first reading, distinct from unknown.
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "blocking": false }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a zero-token transcript exits 0"
    assert_contains "$RUN_OUT" "0 tokens (first reading)" \
        "a scraped 0 renders as a first reading, not tokens unknown"
    assert_not_contains "$RUN_OUT" "tokens unknown" \
        "a genuine 0 is never conflated with an empty/failed scrape"
}

# golem-status's OWN jq gate for the TOP-LEVEL TOKENS block: with jq absent from
# PATH the script still exits 0 and renders the main table, but emits NO token
# section. PATH is a curated shim of every tool the script tree needs EXCEPT jq
# (golem-status sources config.sh → needs git/dirname; plus date/mktemp/mv/rm/
# tmux), symlinked so no interpreter is required (mirrors the repo_root shim).
test_status_no_jq_skips_token_block() {
    local sb shim tp
    new_sandbox sb
    shim="$sb/shim"
    command mkdir -p "$shim"
    for t in git dirname env date mktemp mv rm tmux bash sh; do
        tp="$(command -v "$t" 2>/dev/null)" && command ln -s "$tp" "$shim/$t"
    done
    # A cache row makes the cache array non-empty, so the ONLY reason the token
    # block is skipped is the jq gate itself (not the empty-cache short-circuit).
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "blocking": false }
EOF
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$shim" \
            "$REAL_BASH" "$STATUS" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "golem-status without jq still exits 0 (degrades, not aborts)"
    assert_not_contains "$RUN_OUT" "TOP-LEVEL TOKENS" \
        "the token block is skipped when jq is absent"
}

# A cache row MISSING the `issue` field → issue_n empty → the scrape is skipped →
# cur empty → the shared "tokens unknown (no transcript)" arm (there is no
# issue-specific message; missing-issue funnels into the same empty-cur branch).
test_status_cache_row_missing_issue_tokens_unknown() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # No `issue` key at all — a valid golem row (renders in the table) but the
    # token loop cannot resolve a worktree to scrape.
    command cat >"$sb/.worktrees/.status/golem-88.json" <<'EOF'
{ "golem": "golem-88", "branch": "feature/issue-88",
  "state": "working", "blocking": false }
EOF
    # A transcript is planted for 88, yet the row still reads 'tokens unknown':
    # the missing `issue` collapses the scrape to an empty count regardless of a
    # present transcript (the observable contract this test pins).
    plant_transcript "$sb" 88 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with an issue-less cache row exits 0"
    assert_contains "$RUN_OUT" "tokens unknown (no transcript)" \
        "a cache row missing 'issue' funnels into the shared tokens-unknown arm"
    assert_not_contains "$RUN_OUT" "150 tokens" \
        "a missing 'issue' is never scraped to a real count"
}

# --- --checkpoint compact per-track status+burn table (#283) -----------------

# write_two_golem_tracks_sandbox <sandbox-var> — shared fixture for the checkpoint
# tests: two Mode-2 golem cache rows (42 in review-cycle with a PR + started;
# 89 ci-failing + blocking), a tracks.json placing 42 in lane 0 and 89 in lane 1,
# and a planted 150-token transcript for issue 42. new_sandbox does NOT write a
# tracks.json, so the grouping tests author it by hand.
# Internal sandbox var is uniquely named (`_wtgs_sb`) so it collides with neither
# the caller's out-var nor new_sandbox's own internal `dir` local — otherwise
# new_sandbox's `printf -v` would write a shadowed local and the path would never
# propagate (the dynamic-scope pitfall new_sandbox itself sidesteps).
write_two_golem_tracks_sandbox() {
    local __out="$1" _wtgs_sb
    new_sandbox _wtgs_sb
    command cat >"$_wtgs_sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "pr": 310, "blocking": false,
  "started": "2026-07-19T00:00:00Z" }
EOF
    command cat >"$_wtgs_sb/.worktrees/.status/golem-89.json" <<'EOF'
{ "golem": "golem-89", "issue": 89, "branch": "feature/issue-89",
  "state": "ci-failing", "phase": "implement", "blocking": true }
EOF
    command cat >"$_wtgs_sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "issues": [42], "autonomy_level": 2 },
              { "lane": 1, "issues": [89], "autonomy_level": 3 } ] }
EOF
    plant_transcript "$_wtgs_sb" 42 "$TRANSCRIPT_MIXED"
    printf -v "$__out" '%s' "$_wtgs_sb"
}

# --checkpoint renders the compact per-track table header, groups rows by lane,
# and prints the batch-totals footer.
test_status_checkpoint_renders_table_and_footer() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    write_two_golem_tracks_sandbox sb
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint exits 0"
    assert_contains "$RUN_OUT" "STATUS CHECKPOINT" "renders the checkpoint section header"
    assert_contains "$RUN_OUT" "TOKENS(Δ)" "renders the burn column header"
    # tracks.json puts 42 in lane 0 and 89 in lane 1 → both lane labels appear.
    assert_contains "$RUN_OUT" "L0" "golem-42 is grouped under its lane (L0)"
    assert_contains "$RUN_OUT" "L1" "golem-89 is grouped under its lane (L1)"
    assert_contains "$RUN_OUT" "150 (first)" "the 150-token transcript shows as a first reading"
    assert_contains "$RUN_OUT" "BATCH:" "prints the batch-totals footer"
    assert_contains "$RUN_OUT" "tokens=150" "footer sums the top-level tokens"
    # One-shot (no --watch) has no prior sweep → rate must be — , never fabricated.
    assert_contains "$RUN_OUT" "rate=—" "a one-shot checkpoint prints rate=— (no prior sweep to diff)"
    # The verbose render is REPLACED, not stacked, so its section header is absent.
    assert_not_contains "$RUN_OUT" "TOP-LEVEL TOKENS" "checkpoint replaces the verbose render, not stacks it"
}

# The burn Δ is computed across two sweeps: first reading has no delta, a grown
# transcript on the second sweep reports the (+N) delta and folds it into Δ.
test_status_checkpoint_delta_across_sweeps() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    plant_transcript "$sb" 42 '{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}'
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "100 (first)" "first sweep shows the count as a first reading"
    # Grow the top-level tokens by 25 → 125, then re-render: advancing (+25).
    local slug dir
    slug="$(slug_for "$sb/.worktrees/issue-42")"
    dir="$sb/projects/$slug"
    command printf '%s\n' \
        '{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}' \
        '{"isSidechain":false,"message":{"id":"m2","usage":{"output_tokens":25}}}' >"$dir/session.jsonl"
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "125 (+25)" "the second sweep shows the +25 burn delta"
    assert_contains "$RUN_OUT" "Δ=25" "the footer folds the per-golem delta into the batch Δ"
}

# With no tracks.json, every golem falls into the single untracked (—) group —
# the standalone/pool behavior (nlanes=0 → lane loop skipped).
test_status_checkpoint_no_tracks_untracked_group() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    # No tracks.json written → the golem must still render, in the — group.
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "checkpoint with no tracks.json exits 0"
    assert_contains "$RUN_OUT" "golem-42" "the golem renders even with no tracks.json"
    assert_contains "$RUN_OUT" "STATUS CHECKPOINT" "still renders the checkpoint table"
}

# A tracks.json (a status-dir sibling, not a golem-status file) must NOT be
# rendered as a bogus golem row — the latent glob bug fixed alongside #283.
test_status_checkpoint_excludes_tracks_json() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    write_two_golem_tracks_sandbox sb
    # The VERBOSE render must also skip tracks.json (the glob is shared).
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "verbose render with a tracks.json exits 0"
    assert_not_contains "$RUN_OUT" "tracks.json" "tracks.json is not rendered as a golem row"
}

# BLOCKED / CI-failing attention markers ride the STATE column as plain text (⚠),
# distinct from a normal state — never ANSI colour.
test_status_checkpoint_attention_markers() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    write_two_golem_tracks_sandbox sb
    run_status_scrape "$sb" --checkpoint
    # golem-89 is blocking → ⚠ BLOCKED; the blocked count is tallied in the footer.
    assert_contains "$RUN_OUT" "⚠ BLOCKED" "a blocking golem shows the ⚠ BLOCKED marker"
    assert_contains "$RUN_OUT" "blocked=1" "the footer tallies the blocked golem"
    # No ANSI escape sequences leak into the table (stays legible in a log/pipe).
    assert_not_contains "$RUN_OUT" "$(command printf '\033')" "the checkpoint table emits no ANSI colour"
}

# --checkpoint composes with --watch/--level: a bounded watch renders the compact
# table and the level-scaled cadence banner, exiting cleanly when timed out.
test_status_checkpoint_watch_composes() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    write_two_golem_tracks_sandbox sb
    # run_in_watch bounds the loop; --level 2 resolves the ~5-min cadence banner.
    run_in_watch "$sb" 2 \
        GOLEM_STATUS_DIR=.worktrees/.status \
        CLAUDE_PROJECTS_DIR="$sb/projects" \
        -- --checkpoint --watch --level 2 --interval 1
    assert_exit 0 "$RUN_RC" "--checkpoint --watch is a valid, bounded sweep (exit 0)"
    assert_contains "$RUN_OUT" "STATUS CHECKPOINT" "the watch loop renders the compact table"
    assert_contains "$RUN_OUT" "Status sweep every 1s" "the sweep banner reports the resolved cadence"
}

# A DROP in the cumulative top-level count across sweeps (a fresh session after
# /clear, per golem-token-scrape.sh's documented shape) renders as `(reset)` — a
# new baseline — and is EXCLUDED from the burn Δ, never a nonsensical negative
# delta or a fabricated negative aggregate rate. Regression guard for the
# signed-delta bug the pre-PR review reproduced.
test_status_checkpoint_reset_on_count_drop() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb slug dir
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-5.json" <<'EOF'
{ "golem": "golem-5", "issue": 5, "branch": "feature/issue-5",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    slug="$(slug_for "$sb/.worktrees/issue-5")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    # Sweep 1: a 500-token session establishes the baseline.
    command printf '%s\n' '{"isSidechain":false,"message":{"id":"a","usage":{"output_tokens":500}}}' >"$dir/session.jsonl"
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "500 (first)" "first sweep establishes the 500-token baseline"
    # Sweep 2: a fresh, SMALLER session (count drops 500 -> 50) — a new baseline.
    command sleep 1
    command printf '%s\n' '{"isSidechain":false,"message":{"id":"b","usage":{"output_tokens":50}}}' >"$dir/session2.jsonl"
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "50 (reset)" "a count drop renders as (reset), a new baseline"
    assert_not_contains "$RUN_OUT" "(+-" "a drop never renders a negative signed delta"
    assert_contains "$RUN_OUT" "Δ=0" "a reset is excluded from the batch burn Δ (no negative)"
    assert_not_contains "$RUN_OUT" "Δ=-" "the batch Δ never goes negative on a reset"
}

# The ⚠ gone marker fires for a cache golem whose tmux session vanished while a
# SIBLING golem session is still up (the wedged/dead-golem signal). Uses a tmux
# stub reporting only golem-42's session, so golem-99 (no session) reads ⚠ gone
# and golem-42 does not. Both golems are NON-blocking, so ⚠ gone is not masked by
# the higher-priority ⚠ BLOCKED marker (the shared fixture's golem-89 IS blocking,
# which is why this test builds its own non-blocking rows).
test_status_checkpoint_session_gone_marker() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/golem-99.json" <<'EOF'
{ "golem": "golem-99", "issue": 99, "branch": "feature/issue-99",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    # A tmux stub that lists ONLY golem-42 alive (golem-99's session is gone).
    # golem-status.sh scans `tmux ls | grep -oE '^golem-[0-9]+'`, so the stub
    # prints one matching line for `ls` and nothing for other subcommands.
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls) printf 'golem-42: 1 windows\n' ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    # --unset=BASH_ENV: in the devcontainer BASH_ENV points at /etc/bash_env,
    # which resets $PATH on non-interactive bash and would shadow the stub tmux
    # with the real one (see the devcontainer-bash-env-path-reset note).
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "checkpoint with a partial tmux session set exits 0"
    assert_contains "$RUN_OUT" "⚠ gone" "golem-99 (session vanished, sibling up) shows ⚠ gone"
    # golem-42's session IS present → it must NOT be flagged gone; it keeps its
    # real state (review-cycle), proving the marker is per-golem, not global.
    assert_contains "$RUN_OUT" "review-cycle" "golem-42 (session present) keeps its real state, not ⚠ gone"
}

# A corrupted persisted top_level_tokens value (the cache is co-written by the
# orchestrator model, so a non-canonical field is possible) must NOT throw a bash
# arithmetic error and drop the golem's row — the persisted prior is numeric-
# guarded the same way the freshly-scraped value is. Regression guard for the
# monitoring-integrity finding: `"089"` (a quoted leading-zero string) is invalid
# octal in `$(( ))` and previously vanished the row.
test_status_checkpoint_corrupt_prev_tokens_no_drop() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # Seed a cache row whose persisted count is a corrupt string ("089").
    command cat >"$sb/.worktrees/.status/golem-8.json" <<'EOF'
{ "golem": "golem-8", "issue": 8, "branch": "feature/issue-8",
  "state": "working", "phase": "implement", "blocking": false,
  "top_level_tokens": "089", "top_level_tokens_at": "2026-07-19T00:00:00Z" }
EOF
    plant_transcript "$sb" 8 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "a corrupt persisted token value does not crash --checkpoint"
    assert_contains "$RUN_OUT" "golem-8" "the golem's row is still rendered (not dropped by an arithmetic error)"
    # The corrupt prior is treated as no-prior → a fresh 'first' reading, never a
    # bash 'value too great for base' error leaking into the table.
    assert_contains "$RUN_OUT" "150 (first)" "a corrupt (leading-zero) prior reads as a fresh first reading"
    assert_not_contains "$RUN_OUT" "value too great" "no bash octal error leaks into the output"

    # An OVERFLOW-sized persisted value (>18 digits, past bash's signed 64-bit
    # range) must also degrade to a safe 'first' reading — NOT throw "integer
    # expression expected" and misclassify as frozen (a false #369 takeover signal).
    command cat >"$sb/.worktrees/.status/golem-8.json" <<'EOF'
{ "golem": "golem-8", "issue": 8, "branch": "feature/issue-8",
  "state": "working", "phase": "implement", "blocking": false,
  "top_level_tokens": 99999999999999999999999999999, "top_level_tokens_at": "2026-07-19T00:00:00Z" }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "an overflow-sized persisted token value does not crash --checkpoint"
    assert_contains "$RUN_OUT" "150 (first)" "an overflow prior reads as a fresh first reading, not frozen"
    assert_not_contains "$RUN_OUT" "integer expression" "no bash overflow error leaks into the output"
}

# derive_stage prefers .phase_detail over .phase/.state — assert the highest-
# priority Stage source actually wins (guards the jq `//` precedence).
test_status_checkpoint_stage_prefers_phase_detail() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "feature/issue-7",
  "state": "working", "phase": "implement", "phase_detail": "loop:make-it-tested",
  "blocking": false }
EOF
    plant_transcript "$sb" 7 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "loop:make-it-tested" "STAGE shows .phase_detail, its highest-priority source"
}

# The ⚠ CI marker fires independently of BLOCKED: a ci-failing golem that is NOT
# blocking reaches the ci-failing branch (the shared fixture's golem-89 sets both,
# so BLOCKED masks it there). Also exercises the 'merged' → shipped tally.
test_status_checkpoint_ci_and_shipped_markers() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-11.json" <<'EOF'
{ "golem": "golem-11", "issue": 11, "branch": "feature/issue-11",
  "state": "ci-failing", "phase": "implement", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/golem-12.json" <<'EOF'
{ "golem": "golem-12", "issue": 12, "branch": "feature/issue-12",
  "state": "merged", "phase": "ship", "blocking": false }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "⚠ CI" "a ci-failing, non-blocking golem shows ⚠ CI (not masked by BLOCKED)"
    assert_contains "$RUN_OUT" "shipped=1" "a merged golem is tallied as shipped in the footer"
    assert_contains "$RUN_OUT" "blocked=1" "the ci-failing golem is tallied as blocked"
}

# The checkpoint Tokens(Δ) column renders an UNPOSTED container ('n/a', excluded
# from totals) and a transcript-less ('—') golem distinctly — checkpoint-specific
# formatting the verbose token tests do not cover.
test_status_checkpoint_container_and_unknown_tokens() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/golem-77.json" <<'EOF'
{ "golem": "golem-77", "issue": 77, "branch": "feature/issue-77",
  "state": "working", "blocking": false }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "n/a" "an unposted container golem's Tokens(Δ) shows n/a (Mode-3, #390)"
    assert_contains "$RUN_OUT" "tokens=0" "unposted container + transcript-less golems contribute 0 tokens to the total"
}

# A container golem whose host-POST HAS landed folds its posted count into the
# checkpoint Σtokens total (rendered with a (frozen) tag), but a one-shot
# --checkpoint still shows rate=— (per-sweep Δ / rate need golem-status's own
# prior sample, which the read-only container path deliberately doesn't keep). (#390)
test_status_checkpoint_container_populated_tokens() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242, "top_level_tokens_at": "$anchor" }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "4242 (frozen)" \
        "a posted container's Tokens(Δ) shows the count with a (frozen) tag (#390)"
    assert_contains "$RUN_OUT" "tokens=4242" "a posted container folds its count into Σtokens"
    assert_contains "$RUN_OUT" "rate=—" \
        "a one-shot --checkpoint shows rate=— — a container has no per-sweep Δ baseline"
}

# --- --checkpoint follow-up coverage (#415, deferred from #283/PR #414) -------

# The ELAPSED column renders a REAL duration derived from .started (not just that
# the row renders). A .started ~130s in the past must show _fmt_dur's minutes arm
# ("2m"), never the "—" empty sentinel a missing .started would leave. Mirrors
# test_status_fmt_dur_minute_arm's iso_ago anchoring, but asserts the checkpoint
# ELAPSED cell specifically (the #283 tests only assert the row is present).
test_status_checkpoint_elapsed_from_started() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date could not compute a past anchor"
        return 0
    fi
    command cat >"$sb/.worktrees/.status/golem-42.json" <<EOF
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "started": "$anchor" }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint with a .started anchor exits 0"
    # ~130s → 2m (well past the 60s boundary, so a few seconds of test latency
    # can't flip the arm). Match the render form, not an exact minute count.
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq '[0-9]+m'" \
        "ELAPSED renders a real minutes duration derived from .started"
    assert_not_contains "$RUN_OUT" "frozen 0m" "a >60s elapsed never rounds to 0m"
}

# When .started is ABSENT (a Mode-2 golem whose dispatch wrote no cache stamp),
# ELAPSED must NOT collapse to the bare "—" that pushes the operator onto manual
# cross-clock arithmetic. Instead it falls back to the golem worktree dir's
# creation/index mtime — a TZ-agnostic epoch — rendered with a "~" prefix to mark
# it approximate (issue #515). The worktree dir must exist for _mtime_epoch to
# resolve; new_sandbox creates .worktrees/.status but not the per-issue dir.
test_status_checkpoint_elapsed_fallback_no_started() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # No "started" field at all — the exact Mode-2 no-cache-writer gap.
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    # A real worktree dir + a `.git` gitlink file (the stable launch anchor a
    # linked worktree carries) so the primary mtime fallback resolves.
    command mkdir -p "$sb/.worktrees/issue-42"
    command printf 'gitdir: /somewhere/.git/worktrees/issue-42\n' >"$sb/.worktrees/issue-42/.git"
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint with no .started exits 0"
    # The ELAPSED cell shows a "~"-prefixed approximate age (e.g. "~0s"/"~1m"),
    # never a bare "—". Match the "~<digits><unit>" render form.
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq '~[0-9]+[sm]'" \
        "ELAPSED falls back to a ~-marked worktree-mtime age when .started is absent (#515)"
}

# The fallback triggers on a present-but-UNPARSABLE .started too, not just an
# absent one: _iso_to_epoch returns empty for a garbage timestamp, ELAPSED stays
# "—" after the .started branch, and the worktree-mtime fallback takes over
# (#515). Mirrors test_status_frozen_iso_parse_failure_raw_render (#392) for the
# ELAPSED path.
test_status_checkpoint_elapsed_fallback_malformed_started() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "started": "not-a-valid-timestamp" }
EOF
    command mkdir -p "$sb/.worktrees/issue-42"
    command printf 'gitdir: /somewhere/.git/worktrees/issue-42\n' >"$sb/.worktrees/issue-42/.git"
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint with a malformed .started exits 0"
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq '~[0-9]+[sm]'" \
        "an unparsable .started still falls through to the ~-marked mtime fallback (#515)"
}

# The fallback is a fallback, not a fabrication: a started-less row whose
# worktree dir does NOT exist (container/reaped, or a genuinely anchorless row)
# keeps the bare "—" rather than inventing an age. new_sandbox does not create
# .worktrees/issue-42, so the anchor cannot resolve.
test_status_checkpoint_elapsed_no_anchor_stays_dash() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    # Deliberately NO .worktrees/issue-42 dir → _mtime_epoch returns empty.
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint with no anchor exits 0"
    assert_true "! printf '%s' \"\$RUN_OUT\" | command grep -Eq '~[0-9]+[sm]'" \
        "no worktree anchor → ELAPSED stays — , never a fabricated ~age (#515)"
}

# render_checkpoint's TWO early returns: (a) empty status dir + no sessions + no
# pool → "No active golems", exit 0 (the shared empty-state guard, before jq);
# (b) jq absent from PATH → the "cannot render checkpoint table" guard on stderr,
# exit 0 (degrade, not abort). The jq case plants a cache row so the empty-state
# guard is NOT the reason the table is skipped — isolating the jq gate. PATH is a
# curated shim of every tool the script tree needs EXCEPT jq (mirrors
# test_status_no_jq_skips_token_block).
test_status_checkpoint_empty_and_no_jq_guards() {
    local sb shim tp
    new_sandbox sb
    # (a) Empty-state early return (jq-independent: the guard precedes the jq
    # check, so run it unconditionally).
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with no golems exits 0"
    assert_contains "$RUN_OUT" "No active golems" "--checkpoint empty state reports no active golems"
    assert_not_contains "$RUN_OUT" "STATUS CHECKPOINT" "the empty-state guard returns before the table header"

    # (b) jq-missing early return: a curated PATH shim without jq + a planted
    # cache row (so the empty-state guard is passed and the jq gate is the sole
    # reason the table is skipped).
    shim="$sb/shim"
    command mkdir -p "$shim"
    for t in git dirname env date mktemp mv rm tmux bash sh; do
        tp="$(command -v "$t" 2>/dev/null)" && command ln -s "$tp" "$shim/$t"
    done
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "blocking": false }
EOF
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$shim" \
            "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "--checkpoint without jq still exits 0 (degrades, not aborts)"
    assert_contains "$RUN_OUT" "cannot render checkpoint table" \
        "--checkpoint without jq emits the fail-soft guard message"
    assert_not_contains "$RUN_OUT" "STATUS CHECKPOINT" "no table header is printed without jq"
}

# The pool.json header (the `Pool:` line) renders ahead of the checkpoint table
# when a pool.json sibling is present — the same header render_status prints. No
# other checkpoint test writes a pool.json, so this is the first fixture for it;
# fields (size/slots/backlog/queue) mirror the jq in render_checkpoint.
test_status_checkpoint_pool_header() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/pool.json" <<'EOF'
{ "size": 3, "slots": [42, 89], "backlog_depth": 5, "queue": "open" }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with a pool.json exits 0"
    assert_contains "$RUN_OUT" "Pool: size=3" "renders the pool header size"
    assert_contains "$RUN_OUT" "slots=2/3" "renders slots-in-use / size"
    assert_contains "$RUN_OUT" "backlog=5" "renders the backlog depth"
    assert_contains "$RUN_OUT" "queue=open" "renders the queue state"
    assert_contains "$RUN_OUT" "STATUS CHECKPOINT" "the table still renders after the pool header"
    # pool.json must NOT be rendered as a bogus golem row (the shared glob exclusion).
    assert_not_contains "$RUN_OUT" "pool.json" "pool.json is not rendered as a golem row"
}

# A live golem-N tmux session with NO cache file yet renders a "(live)" tail row
# (mirrors render_status's tail rows). A tmux stub reports golem-77 alive while
# no .status/golem-77.json exists → the tail-row branch must emit it.
test_status_checkpoint_live_tail_row() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # A cache row for a DIFFERENT golem so the table renders; golem-77 has none.
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    # A tmux stub listing golem-77 alive (no cache file for it → a (live) row).
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls) printf 'golem-77: 1 windows\n' ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "--checkpoint with a session-only golem exits 0"
    assert_contains "$RUN_OUT" "golem-77" "the session-only golem renders a tail row"
    assert_contains "$RUN_OUT" "(live)" "a cache-less session renders the (live) marker"
}

# Lane-boundary padding: a lane listing issue 42 must NOT capture the shorter
# issue 4 (the `" $iss "` exact-pad glob at the lane-membership check). The
# guarded bug is a PREFIX match — an unpadded " 4" is a substring of the lane
# string " 42 ", so without the exact trailing-space pad, issue 4 would wrongly
# land in issue 42's lane. Cache rows for 4 and 42, tracks.json lane 0 = [42]
# only → 4 falls to the untracked (—) group, not lane 0. Regression fixture for
# the in-code "so 4 does not match 42" comment.
test_status_checkpoint_lane_boundary_padding() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-4.json" <<'EOF'
{ "golem": "golem-4", "issue": 4, "branch": "feature/issue-4",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "issues": [42], "autonomy_level": 2 } ] }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with a single-issue lane exits 0"
    # golem-4's row must carry the untracked track label (—), not L0: issue 4 is
    # NOT in lane [42], and only a prefix (unpadded) match would pull it in. The
    # golem-4 row (its trailing space disambiguates it from golem-42) must render
    # and its first (TRACK) cell must not be L0.
    assert_true "command printf '%s\n' \"\$RUN_OUT\" | command grep -q 'golem-4 '" "golem-4 renders a row"
    assert_true "! command printf '%s\n' \"\$RUN_OUT\" | command grep 'golem-4 ' | command grep -q '^L0'" \
        "golem-4 is NOT pulled into lane 0 (issue 42's lane) by a prefix match"
    # golem-42 IS in lane 0 → its row starts with L0 (proves the lane join works).
    assert_true "command printf '%s\n' \"\$RUN_OUT\" | command grep 'golem-42' | command grep -q '^L0'" \
        "golem-42 IS grouped under its lane (L0)"
}

# derive_stage's fallback chain below .phase_detail: .phase wins when no
# .phase_detail; .state wins when neither .phase_detail nor .phase; "—" when none
# present. The #283 suite only asserts the .phase_detail win — these pin each
# lower rung of the jq `//` precedence individually.
test_status_checkpoint_derive_stage_fallbacks() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # (a) .phase win — no .phase_detail.
    command cat >"$sb/.worktrees/.status/golem-1.json" <<'EOF'
{ "golem": "golem-1", "issue": 1, "branch": "feature/issue-1",
  "state": "working", "phase": "implement-phase", "blocking": false }
EOF
    # (b) .state win — neither .phase_detail nor .phase.
    command cat >"$sb/.worktrees/.status/golem-2.json" <<'EOF'
{ "golem": "golem-2", "issue": 2, "branch": "feature/issue-2",
  "state": "state-token", "blocking": false }
EOF
    # (c) "—" — none of the three Stage sources present.
    command cat >"$sb/.worktrees/.status/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "blocking": false }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with the fallback-chain fixtures exits 0"
    assert_contains "$RUN_OUT" "implement-phase" "STAGE falls back to .phase when .phase_detail is absent"
    assert_contains "$RUN_OUT" "state-token" "STAGE falls back to .state when .phase_detail and .phase are absent"
    # golem-3 has no Stage source at all → its STAGE cell is the "—" sentinel. Its
    # STATE is also "—" (no .state), so assert the golem-3 row carries a "—" cell.
    assert_true "command printf '%s\n' \"\$RUN_OUT\" | command grep 'golem-3 ' | command grep -q '—'" \
        "STAGE degrades to — when no .phase_detail/.phase/.state is present"
}

# A container (Mode-3) golem is EXEMPT from the ⚠ gone marker even when a sibling
# golem-* session is visible (a container has no host tmux session by design, so
# session_gone would otherwise false-positive). The widened prefix-strip guard
# (`${_ecr_tstate#container}`) must keep BOTH container token-states exempt — the
# unposted `container-pending` AND the populated `container` (a regression that
# broke the strip for the 9-char populated string alone would slip past a
# pending-only fixture), so this test drives both.
test_status_checkpoint_container_never_gone() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    # A tmux stub showing a SIBLING golem-42 alive (proving the server is
    # reachable) — the condition under which session_gone would fire for a row
    # with no matching session. The container must be exempt regardless.
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls) printf 'golem-42: 1 windows\n' ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    # Two passes over the SAME scenario: (1) an unposted container (→
    # container-pending token-state) and (2) a populated container (posted
    # top_level_tokens + a valid anchor → the `container` token-state). Both must
    # stay exempt from ⚠ gone.
    local _label _cache
    for _label in pending populated; do
        if [ "$_label" = populated ]; then
            command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242, "top_level_tokens_at": "$anchor" }
EOF
        else
            command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false }
EOF
        fi
        RUN_RC=0
        RUN_OUT="$(cd "$sb" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                --unset=BASH_ENV \
                HOME="$sb" \
                PATH="$sb/bin:$PATH" \
                TMUX= TMUX_TMPDIR="$sb/.tmux" \
                GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                GOLEM_BASE_REF=HEAD \
                GOLEM_WORKTREE_LOCAL_FILES="" \
                CLAUDE_PROJECTS_DIR="$sb/projects" \
                "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
        assert_exit 0 "$RUN_RC" "--checkpoint with a $_label container + sibling session exits 0"
        assert_contains "$RUN_OUT" "agent01" "the $_label container golem renders its row"
        # The container row keeps its plain state and is never flagged gone. Assert on
        # the agent01 row(s) EXACTLY: zero of them may carry ⚠ gone (a `grep | grep -qv`
        # would pass as soon as ONE line lacked the marker — vacuous with a footer line).
        assert_true "[ \"\$(command printf '%s\n' \"\$RUN_OUT\" | command grep 'agent01' | command grep -c '⚠ gone')\" -eq 0 ]" \
            "no $_label-container agent01 row is flagged ⚠ gone (both token-states exempt from session_gone)"
    done
}

# An issue-less cache row (no .issue → the literal "?") must NOT be spuriously
# flagged ⚠ gone: session_gone's `*" golem-? "*` glob would treat "?" as a
# single-char wildcard and match any live golem-N. The `"$_ecr_issue" != "?"`
# guard keeps the row on its plain state. Regression fixture for the #414 fix.
test_status_checkpoint_issueless_row_not_gone() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # A cache row with NO issue field → .issue falls back to "?".
    command cat >"$sb/.worktrees/.status/golem-mystery.json" <<'EOF'
{ "golem": "golem-mystery", "branch": "feature/mystery",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    # A tmux stub with a live sibling golem-42 — the exact condition under which
    # the "?"-as-wildcard glob would false-match and flag the issue-less row gone.
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls) printf 'golem-42: 1 windows\n' ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "--checkpoint with an issue-less row + sibling session exits 0"
    assert_contains "$RUN_OUT" "golem-mystery" "the issue-less golem still renders its row"
    # Zero golem-mystery rows may carry ⚠ gone — an exact count, not a `grep -qv`
    # that would pass on the first non-matching line (vacuous with a footer line).
    assert_true "[ \"\$(command printf '%s\n' \"\$RUN_OUT\" | command grep 'golem-mystery' | command grep -c '⚠ gone')\" -eq 0 ]" \
        "no issue-less (?) row is spuriously flagged ⚠ gone by the wildcard glob"
}

# A malformed tracks.json listing the SAME issue under two lanes must render the
# golem row (and count its tokens) exactly ONCE — the `claimed` set dedups it
# across the lane passes. Without the guard the row (and its token total) would
# double. Regression fixture for the #414 double-lane-claim dedup.
test_status_checkpoint_double_lane_claim_dedup() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb count
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    # Issue 42 listed under BOTH lane 0 and lane 1 (malformed) — the dedup guard
    # must emit the row once, under the FIRST lane that claims it (L0).
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "issues": [42], "autonomy_level": 2 },
              { "lane": 1, "issues": [42], "autonomy_level": 3 } ] }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with a double-claimed issue exits 0"
    # The golem-42 row appears exactly once, not once per claiming lane.
    count="$(command printf '%s\n' "$RUN_OUT" | command grep -c 'golem-42')"
    assert_true "[ '$count' -eq 1 ]" "golem-42 renders exactly once despite two lane claims (got $count)"
    # Its 150 tokens are counted once, not doubled to 300 in the batch total.
    assert_contains "$RUN_OUT" "tokens=150" "the double-claimed golem's tokens are summed once, not doubled"
    assert_not_contains "$RUN_OUT" "tokens=300" "no double-count of the twice-claimed golem's tokens"
}

# extract_write_status_py — pull the write_status() Python heredoc body out of
# provision-protocol.md (the Mode-3 container entrypoint lives as a bash code
# block in the doc, not a bundled script). Anchors on the exact write_status
# `command python3 - "$STATUS_FILE" <<'PY'` line — NOT the sibling status_poller
# block, which uses a different pre-heredoc line — and strips the 3-space
# markdown-fence indent so the body runs as standalone Python. Mirrors
# validate-template-sync.sh's inline-extraction approach.
extract_write_status_py() {
    command awk '
        /LA="\$\(now\)" command python3 - "\$STATUS_FILE" <<'"'"'PY'"'"'/ { grab = 1; next }
        grab && /^   PY$/ { exit }
        grab { sub(/^   /, ""); print }
    ' "$PROVISION_PROTOCOL"
}

# The WRITE side of the #415 fix: the extracted write_status() Python stamps
# `started` on the FIRST call and PRESERVES it (idempotent) on later calls — the
# `doc.get("started") or ...` behavior, distinct from a re-stamp-every-write bug
# that would perpetually reset --checkpoint ELAPSED to ~0. The checkpoint render
# tests above only exercise the READ side (a fixture with `started` already
# present), so this closes the write-side coverage gap the pre-PR review flagged.
test_provision_write_status_started_idempotent() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 not available (write_status is a python heredoc)"
        return 0
    fi
    local sb body status_file first second
    new_sandbox sb
    body="$(extract_write_status_py)"
    # Guard the extraction itself: an empty body (anchor drift) must fail loudly,
    # never pass vacuously — the exact line the fix touches must be present.
    assert_not_empty "$body" "the write_status() Python body was extracted"
    assert_contains "$body" 'doc["started"] = doc.get("started") or os.environ["LA"]' \
        "the extracted body carries the idempotent started-stamp line (#415)"

    status_file="$sb/.worktrees/.status/agent01.json"
    # First call: no prior cache file → started is stamped with LA=T1.
    AGENT_ID=agent01 ISSUE=300 STATE=working ERR="" LA="2026-01-01T00:00:00Z" \
        python3 -c "$body" "$status_file"
    first="$(jq -r '.started' "$status_file" 2>/dev/null)"
    assert_true "[ '$first' = '2026-01-01T00:00:00Z' ]" \
        "the first write stamps started with the launch time (got '$first')"
    # Second call with a DIFFERENT LA=T2 (a later poller write): started must be
    # PRESERVED at T1, not overwritten — the idempotency the fix guarantees.
    AGENT_ID=agent01 ISSUE=300 STATE=pr-open ERR="" LA="2026-06-15T12:00:00Z" \
        python3 -c "$body" "$status_file"
    second="$(jq -r '.started' "$status_file" 2>/dev/null)"
    assert_true "[ '$second' = '2026-01-01T00:00:00Z' ]" \
        "a later write preserves the original started (not re-stamped to T2, got '$second')"
    # The state DID advance (proving the second write ran, not a no-op).
    assert_true "[ \"\$(jq -r '.state' '$status_file' 2>/dev/null)\" = 'pr-open' ]" \
        "the second write still updated the mutable state field"

    # #428 same-issue guarantee: a later write for the SAME issue must NOT wipe
    # the sibling monitor fields a prior status_poller write left (pr/ci/review/
    # blocking) — the reassignment reset below is mismatch-only. Seed them, write
    # again for issue 300, and confirm they survive (else the fleet monitor's
    # CI/PR columns would blank on every in-flight poll).
    jq '. + {pr:321, ci:"passing", review:"approved", blocking:false}' \
        "$status_file" >"$status_file.tmp" && command mv "$status_file.tmp" "$status_file"
    AGENT_ID=agent01 ISSUE=300 STATE=pr-open ERR="" LA="2026-06-16T12:00:00Z" \
        python3 -c "$body" "$status_file"
    assert_true "[ \"\$(jq -r '.pr // \"null\"' '$status_file' 2>/dev/null)\" = '321' ]" \
        "a same-issue write preserves the poller-written pr field (#428 mismatch-only reset)"
    assert_true "[ \"\$(jq -r '.ci // \"null\"' '$status_file' 2>/dev/null)\" = 'passing' ]" \
        "a same-issue write preserves the poller-written ci field"
}

# #428: the SAME agent slot reassigned to a DIFFERENT issue without the
# documented teardown ("Remove status file") → the bind-mounted host cache still
# holds the PREVIOUS issue's fields. A write for the new issue must clear every
# ISSUE-SCOPED field — not only `started` (ELAPSED, #415), but the sibling
# monitor fields status_poller writes (pr/ci/review/blocking) and `errors` — so
# --checkpoint and the fleet monitor never render the new issue with the old
# issue's CI/PR/blocking signal or a stale error. It must, however, PRESERVE the
# agent-slot IDENTITY fields (container/branch), which golem-status.sh keys
# Mode-3 detection off and golem-attach.sh uses to find the container. Its own
# sandbox — independent of the #415 idempotency test above.
test_provision_write_status_issue_reassignment_resets_stale_fields() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 not available (write_status is a python heredoc)"
        return 0
    fi
    local sb body status_file
    new_sandbox sb
    body="$(extract_write_status_py)"
    assert_not_empty "$body" "the write_status() Python body was extracted"
    assert_contains "$body" \
        'doc = {k: doc[k] for k in ("golem", "kind", "container", "branch") if k in doc}' \
        "the extracted body carries the issue-mismatch reset (keep-identity whitelist) (#428)"

    status_file="$sb/.worktrees/.status/agent01.json"
    # First write establishes an issue-300 row with a launch time.
    AGENT_ID=agent01 ISSUE=300 STATE=working ERR="" LA="2026-01-01T00:00:00Z" \
        python3 -c "$body" "$status_file"
    # Seed the sibling poller fields + an error (a prior run that opened a failing
    # PR) so the reset has stale issue-scoped state to clear, PLUS the agent-slot
    # identity fields (container/branch) that must SURVIVE.
    jq '. + {pr:555, ci:"failing", review:"changes-requested", blocking:true,
             errors:["boom: previous issue failure"],
             container:"proj-agent01-1", branch:"agent01"}' \
        "$status_file" >"$status_file.tmp" && command mv "$status_file.tmp" "$status_file"
    # Reassign the SAME slot to issue 999 (no teardown between).
    AGENT_ID=agent01 ISSUE=999 STATE=working ERR="" LA="2026-09-01T09:00:00Z" \
        python3 -c "$body" "$status_file"

    assert_true "[ \"\$(jq -r '.started' '$status_file' 2>/dev/null)\" = '2026-09-01T09:00:00Z' ]" \
        "reassigning the slot to a new issue re-stamps started to now"
    assert_true "[ \"\$(jq -r '.issue' '$status_file' 2>/dev/null)\" = '999' ]" \
        "the row rebound to the new issue number"
    # The stale issue-scoped fields from issue 300 must be GONE — a reassigned
    # golem that has not opened a PR must not render as ci-failing/blocking/errored.
    assert_true "[ \"\$(jq -r '.pr // \"null\"' '$status_file' 2>/dev/null)\" = 'null' ]" \
        "reassignment clears the previous issue's stale pr number"
    assert_true "[ \"\$(jq -r '.ci // \"null\"' '$status_file' 2>/dev/null)\" = 'null' ]" \
        "reassignment clears the previous issue's stale ci status"
    assert_true "[ \"\$(jq -r '.review // \"null\"' '$status_file' 2>/dev/null)\" = 'null' ]" \
        "reassignment clears the previous issue's stale review decision"
    assert_true "[ \"\$(jq -r '.blocking // \"null\"' '$status_file' 2>/dev/null)\" = 'null' ]" \
        "reassignment clears the previous issue's stale blocking flag"
    assert_true "[ \"\$(jq -r '.errors | length' '$status_file' 2>/dev/null)\" = '0' ]" \
        "reassignment clears the previous issue's stale error message"
    # But the agent-slot IDENTITY fields must PERSIST — the container is still
    # live; wiping these would break golem-status Mode-3 detection + golem-attach.
    assert_true "[ \"\$(jq -r '.container // \"null\"' '$status_file' 2>/dev/null)\" = 'proj-agent01-1' ]" \
        "reassignment PRESERVES the agent-slot container identity field"
    assert_true "[ \"\$(jq -r '.branch // \"null\"' '$status_file' 2>/dev/null)\" = 'agent01' ]" \
        "reassignment PRESERVES the agent-slot branch identity field"

    # A malformed cache (issue as a numeric STRING, schema violation) must not be
    # coerced into a spurious mismatch: a same-issue write with prev issue "300"
    # (string) and ISSUE=300 must PRESERVE started, not wipe it (#428 defensive
    # int() coercion). Seed a string issue + a started, write same issue.
    printf '%s\n' '{"golem":"agent01","kind":"container","issue":"300","started":"2026-01-01T00:00:00Z"}' \
        >"$status_file"
    AGENT_ID=agent01 ISSUE=300 STATE=working ERR="" LA="2026-10-01T00:00:00Z" \
        python3 -c "$body" "$status_file"
    assert_true "[ \"\$(jq -r '.started' '$status_file' 2>/dev/null)\" = '2026-01-01T00:00:00Z' ]" \
        "a numeric-string cached issue is coerced, not treated as a mismatch (started preserved)"
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
run_test test_launch_print_model_unset_omits_flag "golem-launch: unset GOLEM_MODEL emits no --model, byte-identical line (#487)"
run_test test_launch_print_model_set_both_claude_calls "golem-launch: GOLEM_MODEL splices --model into both claude calls (#487)"
run_test test_launch_dispatch_model_both_claude_calls "golem-launch: GOLEM_MODEL reaches the real launch dispatch, both claude calls (#487)"
run_test test_launch_dispatch_model_shell_metachars_escaped "golem-launch: GOLEM_MODEL shell-metachars are escaped, no injection (#487)"
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
run_test test_worktree_new_scrubs_git_config_injection_for_mutations "worktree-new: scrubs a GIT_CONFIG_* injection so the branch+worktree mutation lands in the right repo (#376, #328)"
run_test test_worktree_new_from_submodule_placement_under_taint "worktree-new: from inside a submodule UNDER a tainted git env lands worktree + branch at <super>, not .git/modules or the outer repo (#365, #338, #328)"
run_test test_worktree_new_readonly_tainted_git_env_fails_loud "worktree-new: aborts fail-loud (non-zero, no mutation) under a readonly-tainted GIT_DIR (#368)"
run_test test_config_repo_root_no_hardcoded_usr_bin "config.sh: repo_root has no hardcoded /usr/bin/* tool paths (#278)"
run_test test_config_repo_root_honors_path "config.sh: repo_root resolves via PATH, not command git (#278)"
run_test test_config_repo_root_dirname_root_edge "config.sh: repo_root returns '/' for a /.git common dir (#278)"
run_test test_config_repo_root_relative_common_dir "config.sh: repo_root absolutizes a relative common dir via command pwd (#278)"
run_test test_config_repo_root_scrubs_tainted_git_env "config.sh: repo_root scrubs a tainted GIT_DIR/GIT_COMMON_DIR (#279)"
run_test test_config_repo_root_scrubs_readonly_tainted_git_env "config.sh: repo_root scrubs a READONLY tainted GIT_DIR via env -u fallback (#328)"
run_test test_config_repo_root_scrubs_git_config_injection "config.sh: repo_root scrubs an injected GIT_CONFIG_* config value (#355)"
run_test test_config_repo_root_scrubs_git_config_parameters "config.sh: repo_root scrubs a GIT_CONFIG_PARAMETERS-injected config value (#355)"
run_test test_config_repo_root_scrubs_git_ceiling_directories "config.sh: repo_root scrubs a GIT_CEILING_DIRECTORIES discovery block (#355)"
run_test test_config_repo_root_scrubs_git_config_global "config.sh: repo_root scrubs a GIT_CONFIG_GLOBAL file-injected config value (#376, #355)"
run_test test_config_repo_root_scrubs_git_config_system "config.sh: repo_root scrubs a GIT_CONFIG_SYSTEM file-injected config value (#376, #355)"
run_test test_config_repo_root_scrubs_git_config_nosystem "config.sh: repo_root scrubs a GIT_CONFIG_NOSYSTEM invalid-bool taint (#376, #355)"
run_test test_config_repo_root_scrubs_git_discovery_across_filesystem "config.sh: repo_root scrubs a GIT_DISCOVERY_ACROSS_FILESYSTEM invalid-bool taint (#376, #355)"
run_test test_config_repo_root_submodule_superproject "config.sh: repo_root returns the superproject root inside a submodule (#324)"
run_test test_config_repo_root_submodule_superproject_scrubs_tainted_git_env "config.sh: repo_root scrubs a tainted GIT_DIR in the super_root probe inside a submodule (#337, #279)"
run_test test_config_repo_root_submodule_superproject_scrubs_readonly_tainted_git_env "config.sh: repo_root scrubs a READONLY tainted GIT_DIR in the super_root probe inside a submodule (#363, #337, #328)"
run_test test_config_repo_root_relative_super_root "config.sh: repo_root absolutizes a relative --show-superproject-working-tree via command pwd (#336)"
run_test test_config_git_env_scrub_vars_single_source "config.sh: GIT_ENV_SCRUB_VARS is the single source for the git-env scrub list (#356)"
run_test test_worktree_rm_non_integer_exits_2 "worktree-rm: non-integer arg exits 2"
run_test test_worktree_rm_absent_is_noop "worktree-rm: absent issue is a clean no-op (exit 0)"
run_test test_worktree_rm_round_trip "worktree-rm: round-trip removes worktree + branch"
run_test test_worktree_rm_kills_session_despite_has_session_false "worktree-rm: kills golem-N unconditionally despite a racy has-session false (#486)"
run_test test_worktree_rm_kill_session_failure_is_quiet_noop "worktree-rm: a failed kill-session stays a quiet exit-0 no-op, no phantom removal (#486)"
run_test test_worktree_rm_emits_reaped_feed_line "worktree-rm: teardown emits a reaped feed line with the right id (#446)"
run_test test_worktree_rm_scrubs_tainted_git_env_for_mutations "worktree-rm: scrubs a tainted GIT_DIR so deletions target the right repo (#328)"
run_test test_worktree_rm_scrubs_git_config_injection_for_mutations "worktree-rm: scrubs a GIT_CONFIG_* injection so the teardown mutation targets the right repo (#376, #328)"
run_test test_worktree_rm_readonly_tainted_git_env_fails_loud "worktree-rm: aborts fail-loud (non-zero, no mutation) under a readonly-tainted GIT_DIR (#368)"
run_test test_worktree_rm_forces_past_clean_submodule "worktree-rm: forces past a clean populated submodule (#325)"
run_test test_worktree_rm_refuses_dirty_regular_file_with_submodule "worktree-rm: refuses dirty regular file even with a submodule (#325)"
run_test test_worktree_rm_repairs_stale_core_worktree "worktree-rm: repairs a stale main-repo core.worktree (#258)"
run_test test_worktree_rm_preserves_valid_core_worktree "worktree-rm: preserves a valid core.worktree (#258)"
run_test test_attach_non_integer_exits_2 "golem-attach: non-integer arg exits 2"
run_test test_attach_no_session_exits_1 "golem-attach: no session/container exits 1"
run_test test_status_empty_reports_no_golems "golem-status: empty state reports no active golems"
run_test test_status_renders_planted_row "golem-status: planted cache row renders in the table"
run_test test_status_blocked_shows_gate_age "golem-status: BLOCKED render shows a (gated Nm ago) gate-age suffix (#422)"
run_test test_gate_age_suffix_no_ts_empty "golem-status: _gate_age_suffix emits nothing for a no-ts line (#432)"
run_test test_gate_age_suffix_bad_ts_empty "golem-status: _gate_age_suffix emits nothing for an unparsable ts (#432)"
run_test test_gate_age_suffix_no_jq_empty "golem-status: _gate_age_suffix emits nothing when jq is absent (#432)"
run_test test_status_blocked_no_ts_omits_gate_age "golem-status: a no-ts BLOCKED line renders without a (gated Nm ago) suffix (#432)"
run_test test_status_bad_ts_does_not_blank_blocked_list "golem-status: a malformed ts on one golem doesn't blank the whole BLOCKED list (#432)"
run_test test_status_annotates_blocked_inbox_state "golem-status: annotates a BLOCKED escalation line with the inbox state (#395)"
run_test test_status_inbox_state_awaiting_and_consumed "golem-status: inbox annotation renders awaiting + consumed (#395)"
run_test test_status_inbox_annotation_uses_bracketed_gate "golem-status: annotation keys on the bracketed [gate-…] token, not a stray mention (#395)"
run_test test_status_unknown_arg_exits_2 "golem-status: unknown argument exits 2 (#304)"
run_test test_status_watch_bad_level_exits_2 "golem-status: --watch --level out of range exits 2 (#304)"
run_test test_status_watch_bad_interval_exits_2 "golem-status: --watch --interval non-integer exits 2 (#304)"
run_test test_status_watch_loops_with_env_override "golem-status: --watch re-renders; GOLEM_SWEEP_INTERVAL overrides the level default (#304)"
run_test test_status_watch_uses_resolver_default "golem-status: --watch uses the resolver's level-scaled default cadence (#304)"
run_test test_status_checkpoint_suppresses_noop_sweep "golem-status: --checkpoint --watch suppresses no-op sweeps (full table once, then heartbeat) (#488)"
run_test test_status_checkpoint_reemits_on_state_change "golem-status: --checkpoint re-emits promptly on a row state change after suppression (#488)"
run_test test_status_verbose_no_raw_feed_dump "golem-status: verbose render shows a feed count, not the raw JSON tail (#488)"
run_test test_status_checkpoint_gap_clears_suppression "golem-status: an empty-state gap clears suppression — a reappearing golem re-renders, not a heartbeat (#488)"
run_test test_status_checkpoint_pool_header_blank_line "golem-status: --checkpoint keeps the blank line between pool header and title (#488)"
run_test test_status_checkpoint_oneshot_shows_cache_mirror_note "golem-status: one-shot --checkpoint still shows the cache-mirror caveat (#488)"
run_test test_status_checkpoint_zero_golem_heartbeat_single_line "golem-status: zero-golem heartbeat count is a clean single-line 0, not a split grep -c (#488)"
run_test test_status_checkpoint_multi_golem_batch_suppression "golem-status: multi-golem batch suppresses unchanged sweep + re-emits whole table on a single-row flip (#488)"
run_test test_scrape_sums_top_level_only "golem-token-scrape: sums top-level output_tokens only, excludes sidechain (#371)"
run_test test_scrape_missing_transcript_fails_loud "golem-token-scrape: missing transcript fails loud (exit 2), never a silent 0 (#371)"
run_test test_scrape_no_arg_exits_1 "golem-token-scrape: empty worktree arg fails loud (#371)"
run_test test_scrape_newest_session_wins "golem-token-scrape: newest-mtime session transcript wins (#371)"
run_test test_scrape_tolerates_truncated_trailing_line "golem-token-scrape: tolerates a truncated trailing JSONL line (#371)"
run_test test_scrape_no_jq_exits_3 "golem-token-scrape: missing jq on PATH exits 3 fail-loud (#371)"
run_test test_status_token_first_then_frozen "golem-status: token section shows first-reading then frozen; persists fields (#371)"
run_test test_status_token_advancing_on_change "golem-status: a grown top-level count reads as advancing, not frozen (#371)"
run_test test_status_token_container_pending "golem-status: an unposted Mode-3 container golem shows the awaiting-push note, never scraped (#390)"
run_test test_status_token_container_populated "golem-status: a posted Mode-3 container golem renders the mechanical frozen phrase, read-only (#390)"
run_test test_status_token_container_malformed_degrades "golem-status: a Mode-3 container row with a corrupt count / non-ISO anchor degrades to container-pending (#390)"
run_test test_status_token_container_partial_post "golem-status: a Mode-3 container row with only one of count/anchor posted degrades to container-pending (#390)"
run_test test_status_token_unknown_no_transcript "golem-status: a Mode-2 golem with no transcript shows tokens unknown (#371)"
run_test test_status_frozen_iso_parse_failure_raw_render "golem-status: an unparsable anchor renders the raw 'frozen since <iso>' fallback (#392)"
run_test test_status_fmt_dur_seconds_arm "golem-status: _fmt_dur seconds arm — a sub-60s freeze renders 'frozen Ns' (#392)"
run_test test_status_fmt_dur_minute_arm "golem-status: _fmt_dur minutes arm — a >=60s freeze renders 'frozen Nm' (#392)"
run_test test_scrape_relative_worktree_path "golem-token-scrape: a relative worktree arg resolves like an absolute one (#392)"
run_test test_liveness_working "golem-transcript-liveness: turn-in-flight -> working (#248)"
run_test test_liveness_idle "golem-transcript-liveness: turn-ended -> idle (#248)"
run_test test_liveness_errored_api "golem-transcript-liveness: isApiErrorMessage -> errored (#248)"
run_test test_liveness_errored_unknown_command "golem-transcript-liveness: trailing Unknown command (no turn) -> errored (#248)"
run_test test_liveness_errored_unknown_command_after_idle_turn "golem-transcript-liveness: idle turn + trailing Unknown command -> errored (#248)"
run_test test_liveness_sidechain_not_masking "golem-transcript-liveness: sidechain tool_use does not mask a top-level idle (#248)"
run_test test_liveness_missing_transcript_fails_loud "golem-transcript-liveness: missing transcript exits 2 fail-loud (#248)"
run_test test_liveness_indeterminate_exits_2 "golem-transcript-liveness: no top-level turn is indeterminate, exits 2 (#248)"
run_test test_liveness_no_arg_exits_1 "golem-transcript-liveness: empty worktree arg exits 1 (#248)"
run_test test_liveness_no_jq_exits_3 "golem-transcript-liveness: missing jq on PATH exits 3 fail-loud (#248)"
run_test test_liveness_relative_worktree_path "golem-transcript-liveness: a relative worktree arg resolves like an absolute one (#248)"
run_test test_liveness_stale_working_demoted "golem-transcript-liveness: a stale 'working' transcript is demoted to indeterminate (#248)"
run_test test_liveness_stale_working_threshold_overridable "golem-transcript-liveness: GOLEM_STALL_THRESHOLD widens the staleness window (#248)"
run_test test_liveness_stale_idle_not_demoted "golem-transcript-liveness: a stale idle transcript is not demoted (#248)"
run_test test_liveness_stale_working_stat_failure_fails_open "golem-transcript-liveness: an unreadable mtime fails open on the staleness guard (#248)"
run_test test_liveness_newest_session_wins "golem-transcript-liveness: newest-mtime session wins (#248)"
run_test test_liveness_tolerates_truncated_trailing_line "golem-transcript-liveness: tolerates a truncated trailing JSONL line (#248)"
run_test test_scrape_and_status_zero_tokens "golem-token-scrape/status: an all-sidechain transcript is a real 0, not tokens unknown (#392)"
run_test test_status_no_jq_skips_token_block "golem-status: no jq on PATH skips the TOP-LEVEL TOKENS block, still exits 0 (#392)"
run_test test_status_cache_row_missing_issue_tokens_unknown "golem-status: a cache row missing 'issue' shows tokens unknown (#392)"
run_test test_status_checkpoint_renders_table_and_footer "golem-status: --checkpoint renders the per-track table + batch-totals footer (#283)"
run_test test_status_checkpoint_delta_across_sweeps "golem-status: --checkpoint computes the burn Δ across two sweeps (#283)"
run_test test_status_checkpoint_no_tracks_untracked_group "golem-status: --checkpoint with no tracks.json renders every golem in the untracked group (#283)"
run_test test_status_checkpoint_excludes_tracks_json "golem-status: tracks.json is excluded from the golem-row glob, not a bogus row (#283)"
run_test test_status_checkpoint_attention_markers "golem-status: --checkpoint STATE column carries ⚠ markers, no ANSI colour (#283)"
run_test test_status_checkpoint_watch_composes "golem-status: --checkpoint composes with --watch/--level (#283)"
run_test test_status_checkpoint_reset_on_count_drop "golem-status: --checkpoint renders a count drop as (reset), excluded from burn Δ — no negative delta (#283)"
run_test test_status_checkpoint_corrupt_prev_tokens_no_drop "golem-status: --checkpoint numeric-guards a corrupt persisted token value, never drops the row (#283)"
run_test test_status_checkpoint_session_gone_marker "golem-status: --checkpoint flags a vanished-session golem ⚠ gone when a sibling is up (#283)"
run_test test_status_checkpoint_stage_prefers_phase_detail "golem-status: --checkpoint STAGE prefers .phase_detail over .phase/.state (#283)"
run_test test_status_checkpoint_ci_and_shipped_markers "golem-status: --checkpoint ⚠ CI (non-blocking) + merged→shipped tally (#283)"
run_test test_status_checkpoint_container_and_unknown_tokens "golem-status: --checkpoint renders unposted-container n/a + transcript-less — token cells (#283)"
run_test test_status_checkpoint_container_populated_tokens "golem-status: --checkpoint folds a posted container's count into Σtokens with a (frozen) tag (#390)"
run_test test_status_checkpoint_elapsed_from_started "golem-status: --checkpoint ELAPSED renders a real duration from .started, not — (#415)"
run_test test_status_checkpoint_elapsed_fallback_no_started "golem-status: --checkpoint ELAPSED falls back to a ~-marked worktree-mtime age when .started is absent (#515)"
run_test test_status_checkpoint_elapsed_fallback_malformed_started "golem-status: --checkpoint ELAPSED falls back to the mtime anchor on a malformed .started too (#515)"
run_test test_status_checkpoint_elapsed_no_anchor_stays_dash "golem-status: --checkpoint ELAPSED stays — with no worktree anchor, never a fabricated ~age (#515)"
run_test test_status_checkpoint_empty_and_no_jq_guards "golem-status: --checkpoint empty-state + jq-missing early returns exit 0 (#415)"
run_test test_status_checkpoint_pool_header "golem-status: --checkpoint renders the pool.json header ahead of the table (#415)"
run_test test_status_checkpoint_live_tail_row "golem-status: --checkpoint renders a (live) tail row for a cache-less session (#415)"
run_test test_status_checkpoint_lane_boundary_padding "golem-status: --checkpoint lane membership pads exactly (issue 4 does not capture 42) (#415)"
run_test test_status_checkpoint_derive_stage_fallbacks "golem-status: --checkpoint STAGE falls back .phase → .state → — individually (#415)"
run_test test_status_checkpoint_container_never_gone "golem-status: --checkpoint never flags a container golem ⚠ gone (#415)"
run_test test_status_checkpoint_issueless_row_not_gone "golem-status: --checkpoint issue-less (?) row is not wildcard-matched ⚠ gone (#415)"
run_test test_status_checkpoint_double_lane_claim_dedup "golem-status: --checkpoint dedups a double-lane-claimed golem — one row, tokens once (#415)"
run_test test_provision_write_status_started_idempotent "provision-agent: write_status() stamps started once and preserves it + sibling fields on same-issue writes (#415/#428)"
run_test test_provision_write_status_issue_reassignment_resets_stale_fields "provision-agent: write_status() clears issue-scoped fields but preserves container/branch identity on issue reassignment (#428)"

generate_report
