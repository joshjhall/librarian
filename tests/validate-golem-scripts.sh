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
    # A shim `git` that forwards to the real binary, placed in a dir that is the
    # ONLY entry on PATH (no /usr/bin), so resolution must go through PATH.
    local shim="$sb/shim"
    /usr/bin/mkdir -p "$shim"
    {
        /usr/bin/printf '#!/usr/bin/env bash\n'
        /usr/bin/printf 'exec %q "$@"\n' "$real_git"
    } >"$shim/git"
    /usr/bin/chmod +x "$shim/git"

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
run_test test_config_repo_root_no_hardcoded_usr_bin "config.sh: repo_root has no hardcoded /usr/bin/* tool paths (#278)"
run_test test_config_repo_root_honors_path "config.sh: repo_root resolves via PATH, not /usr/bin/git (#278)"
run_test test_worktree_rm_non_integer_exits_2 "worktree-rm: non-integer arg exits 2"
run_test test_worktree_rm_absent_is_noop "worktree-rm: absent issue is a clean no-op (exit 0)"
run_test test_worktree_rm_round_trip "worktree-rm: round-trip removes worktree + branch"
run_test test_attach_non_integer_exits_2 "golem-attach: non-integer arg exits 2"
run_test test_attach_no_session_exits_1 "golem-attach: no session/container exits 1"
run_test test_status_empty_reports_no_golems "golem-status: empty state reports no active golems"
run_test test_status_renders_planted_row "golem-status: planted cache row renders in the table"

generate_report
