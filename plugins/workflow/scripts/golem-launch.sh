#!/usr/bin/env bash
# golem-launch.sh — portable golem dispatch helper: permission preflight +
# ONE standalone `tmux new-session` per golem.
#
# Replaces ad-hoc `tmux new-session` golem launches so the dispatch path runs
# WITHOUT `just`, on host / bare Linux / inside a devcontainer — and so the
# launch shape always MATCHES the `Bash(tmux new-session:*)` auto-mode allow
# rule (see #29). Two responsibilities:
#
#   1. preflight   — detect whether the launch permission rules are authorized
#                    in the effective Claude Code settings (BOTH the project
#                    `.claude/settings.local.json` AND global
#                    `~/.claude/settings.json`). If absent, print a clear,
#                    copy-pasteable remediation and the exact rules to add, plus
#                    the scope choice. It NEVER writes settings itself —
#                    "suggest + ask, never write silently" (adding settings is
#                    correctly gated by auto mode; the human authorizes it).
#
#   2. launch <N>  — emit + run exactly ONE bare `tmux new-session` for golem N.
#                    A bare `tmux new-session …` matches `Bash(tmux new-session:*)`;
#                    wrapping N launches in a shell `for` loop makes the whole
#                    command a for-loop STRING that does NOT match the rule and
#                    is re-denied (#29). To dispatch a batch, call `launch <N>`
#                    once per issue — never loop inside one Bash invocation.
#
# Required launch permission rules (all three — dispatch, list, teardown):
#   Bash(tmux new-session:*)   Bash(tmux ls:*)   Bash(tmux kill-session:*)
#
# Version-skew guard (#230): before dispatching, verify the version of the
# plugin THIS running helper belongs to matches the ACTIVE installed `workflow`
# plugin. A stale cached skill can drag a stale `golem-launch.sh` along via
# ${CLAUDE_PLUGIN_ROOT}; the old helper emitted pre-namespace commands
# (`/next-issue`) that the active plugin rejects as `Unknown command`, wedging
# every golem SILENTLY. On a detectable mismatch, `launch` refuses (exit 3) with
# an actionable message naming both versions rather than letting the golem idle.
# When either version is undeterminable (no install record / no jq — the common
# host / bare-linux case) the check SKIPS silently, never breaking a valid run.
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR (.worktrees)   GOLEM_BRANCH_PREFIX (feature/issue-)
# Preflight scope overrides (env-overridable):
#   CLAUDE_PROJECT_SETTINGS  (.claude/settings.local.json, repo-root-relative)
#   CLAUDE_GLOBAL_SETTINGS   ($HOME/.claude/settings.json)
# Version-skew overrides (env-overridable):
#   CLAUDE_INSTALLED_PLUGINS ($HOME/.claude/plugins/installed_plugins.json) —
#                            the active-install registry the guard reads.
#   GOLEM_SKIP_VERSION_CHECK (unset) — set to 1 to downgrade a detected skew from
#                            a fatal refusal to a non-fatal warning (legitimate
#                            mid-release / worktree dispatch).
#
# Usage:
#   golem-launch.sh preflight                # check both scopes; print remediation
#   golem-launch.sh launch <issue-number>    # one standalone tmux new-session
#   golem-launch.sh print  <issue-number>    # print the launch line only (no run)
#
# Exit codes:
#   0  success (preflight: rules present in at least one scope; launch: started)
#   2  usage error
#   3  preflight: launch rules MISSING in both scopes (actionable, not opaque);
#      launch: plugin version skew detected (running helper != active install)
set -uo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

# The three rules the documented golem launch path needs under auto mode.
REQUIRED_RULES=(
    'Bash(tmux new-session:*)'
    'Bash(tmux ls:*)'
    'Bash(tmux kill-session:*)'
)

# settings_has_rules <file> — return 0 if the settings JSON's
# permissions.allow array contains EVERY required rule, else 1. Missing file or
# missing jq → treated as "not present" (return 1) so preflight stays loud.
settings_has_rules() {
    local file="$1"
    [ -f "$file" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local rule
    for rule in "${REQUIRED_RULES[@]}"; do
        if ! jq -e --arg r "$rule" \
            '((.permissions.allow // []) | index($r)) != null' \
            "$file" >/dev/null 2>&1; then
            return 1
        fi
    done
    return 0
}

preflight() {
    local root proj_settings global_settings
    root="$(repo_root)" || root="$(/usr/bin/pwd)"
    proj_settings="$root/${CLAUDE_PROJECT_SETTINGS:-.claude/settings.local.json}"
    global_settings="${CLAUDE_GLOBAL_SETTINGS:-$HOME/.claude/settings.json}"

    local in_project=1 in_global=1
    settings_has_rules "$proj_settings" && in_project=0
    settings_has_rules "$global_settings" && in_global=0

    if [ "$in_project" -eq 0 ] || [ "$in_global" -eq 0 ]; then
        local where="project ($proj_settings)"
        [ "$in_global" -eq 0 ] && where="global ($global_settings)"
        command echo "golem-launch: tmux launch permissions present in $where — dispatch will not hit the classifier wall."
        return 0
    fi

    # Missing in BOTH scopes — emit an ACTIONABLE suggestion, never an opaque
    # classifier denial, and never write settings silently. The operator picks
    # the scope and authorizes the add.
    command cat >&2 <<EOF
golem-launch: REQUIRED tmux launch permissions are NOT authorized in either scope.

Without them, a golem dispatch (\`tmux new-session …\`) is DENIED by the
Claude Code auto-mode classifier ([Create Unsafe Agents]) — an opaque hard wall
on the first \`/orchestrate dispatch\`.

Add these rules to ONE scope's "permissions.allow":

  ${REQUIRED_RULES[0]}
  ${REQUIRED_RULES[1]}
  ${REQUIRED_RULES[2]}

  Scope choices (pick one — this script does NOT write settings for you):
    project-local : $proj_settings   (this repo only)
    global        : $global_settings (all repos on this host)

Suggest + ask: surface this to the operator and let them authorize the add
(always-allow -> write the rule; allow-once -> proceed this run). Do not write
the rule silently — adding settings is itself permission-gated by design.
EOF
    return 3
}

# running_plugin_name / running_plugin_version — read `.name` / `.version` from
# the plugin.json of the plugin THIS running helper belongs to (the sibling
# `<scripts>/../.claude-plugin/plugin.json`). Print the value on stdout, or
# nothing when the file or jq is absent (→ the skew check skips). jq errors are
# swallowed so a malformed manifest degrades to "undeterminable", never a crash.
plugin_manifest() {
    command echo "$SCRIPT_DIR/../.claude-plugin/plugin.json"
}
running_plugin_name() {
    local mf
    mf="$(plugin_manifest)"
    [ -f "$mf" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '.name // empty' "$mf" 2>/dev/null || true
}
# The literal string "unknown" is the registry's in-band sentinel for "no semver
# could be introspected" (Claude Code writes it for plugins it can't version-pin).
# Treat it exactly like an absent/empty version so the skew check stays in its
# "undeterminable → skip silently" contract instead of firing a false positive.
running_plugin_version() {
    local mf ver
    mf="$(plugin_manifest)"
    [ -f "$mf" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    ver="$(jq -r '.version // empty' "$mf" 2>/dev/null || true)"
    [ "$ver" = "unknown" ] && ver=""
    command echo "$ver"
}

# active_plugin_version <name> — read the version of the ACTIVE installed plugin
# named <name> from the installed-plugins registry
# (CLAUDE_INSTALLED_PLUGINS, default $HOME/.claude/plugins/installed_plugins.json).
# The registry keys plugins as "<name>@<marketplace>", so match the FIRST key
# whose part before `@` equals <name> (a marketplace rename still resolves).
# Each value is an array of install records; take the first record's `.version`.
# Prints nothing when the file, jq, or a matching record is absent (→ skip).
active_plugin_version() {
    local name="$1" reg ver
    [ -n "$name" ] || return 0
    # ${HOME:-} so an unset HOME under `set -u` yields an unreadable path
    # (→ skip), never a fatal "unbound variable" abort of the whole launch.
    reg="${CLAUDE_INSTALLED_PLUGINS:-${HOME:-}/.claude/plugins/installed_plugins.json}"
    [ -f "$reg" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    ver="$(jq -r --arg n "$name" '
        (.plugins // {}) | to_entries
        | map(select((.key | split("@")[0]) == $n))
        | (.[0].value[0].version // empty)
    ' "$reg" 2>/dev/null || true)"
    # "unknown" is the registry sentinel for "unversioned" — treat as skip.
    [ "$ver" = "unknown" ] && ver=""
    command echo "$ver"
}

# check_version_skew <mode> — compare the running helper's plugin version against
# the active install and act per <mode> ("launch" or "print"). Silent when either
# side is undeterminable or the two agree. On a real mismatch:
#   launch → fatal (exit 3) unless GOLEM_SKIP_VERSION_CHECK=1 downgrades to a warn
#   print  → always a warning only (print has no side effect worth blocking)
check_version_skew() {
    local mode="$1" name running active
    name="$(running_plugin_name)"
    running="$(running_plugin_version)"
    active="$(active_plugin_version "$name")"

    # Undeterminable on either side, or in agreement → nothing to do.
    [ -n "$running" ] && [ -n "$active" ] || return 0
    [ "$running" != "$active" ] || return 0

    if [ "$mode" = "print" ]; then
        command echo "golem-launch: WARNING version skew — this helper is ${name:-workflow} $running but the active install is $active; the emitted line may target the wrong command namespace." >&2
        return 0
    fi

    # mode = launch. Escape hatch downgrades the refusal to a warning.
    if [ "${GOLEM_SKIP_VERSION_CHECK:-}" = "1" ]; then
        command echo "golem-launch: WARNING version skew — running ${name:-workflow} $running != active $active (GOLEM_SKIP_VERSION_CHECK=1, proceeding anyway)." >&2
        return 0
    fi

    command cat >&2 <<EOF
golem-launch: REFUSING to dispatch — plugin version skew detected.

  running helper : ${name:-workflow} $running  (this ${BASH_SOURCE[0]##*/} under \$CLAUDE_PLUGIN_ROOT)
  active install : ${name:-workflow} $active  (installed_plugins.json)

A stale cached skill can load an OLD golem-launch.sh whose launch line targets a
command namespace the ACTIVE plugin no longer resolves — every golem would die on
\`Unknown command\` and idle silently (#230). Refusing so the skew is visible.

Remediation (any one):
  - Re-run /orchestrate after updating the plugin so the loaded skill and its
    helper are the SAME version (claude plugin update workflow@librarian).
  - Dispatch from the active install's helper directly.
  - If this skew is intentional (mid-release / worktree testing), re-run with
    GOLEM_SKIP_VERSION_CHECK=1 to downgrade this refusal to a warning.
EOF
    exit 3
}

# launch_line <N> — print the single bare `tmux new-session` command for golem
# N. Kept as a function so `launch` and `print` share one definition (one source
# of truth for the launch shape).
launch_line() {
    local n="$1" root wt
    root="$(repo_root)" || root="$(/usr/bin/pwd)"
    wt="$root/$GOLEM_WORKTREE_DIR/issue-$n"
    # ONE standalone new-session, matching Bash(tmux new-session:*). The chained
    # `;` second prompt is the resume backstop (NOT `&&`); see orchestrate
    # SKILL.md Phase D / mode-protocol.md § Supervised launch.
    command printf '%s' \
        "tmux new-session -d -s golem-$n -c \"$wt\" -e GOLEM_ID=golem-$n \"claude --permission-mode auto '/workflow:next-issue $n --level 4' ; claude --permission-mode auto '/workflow:ship-issue'\""
}

cmd="${1:-}"
case "$cmd" in
    preflight)
        preflight
        ;;
    print)
        N="${2:-}"
        if ! [[ "$N" =~ ^[0-9]+$ ]]; then
            command echo "golem-launch: print needs an issue number, got '$N'" >&2
            exit 2
        fi
        # Warn (never block) if the emitted line's namespace may be stale.
        check_version_skew print
        launch_line "$N"
        command echo ""
        ;;
    launch)
        N="${2:-}"
        if ! [[ "$N" =~ ^[0-9]+$ ]]; then
            command echo "golem-launch: launch needs an issue number, got '$N'" >&2
            exit 2
        fi
        # Version-skew guard FIRST — refuse (exit 3) before any tmux side effect
        # if this stale helper would emit commands the active plugin can't resolve
        # (#230). Skips silently when versions match or are undeterminable.
        check_version_skew launch
        # Preflight next so a missing rule surfaces as guidance, not an opaque
        # classifier denial. Continue on exit 3 so a host that authorizes
        # allow-once (without persisting the rule) can still proceed this run.
        preflight || true
        root="$(repo_root)" || root="$(/usr/bin/pwd)"
        wt="$root/$GOLEM_WORKTREE_DIR/issue-$N"
        if [ ! -d "$wt" ]; then
            command echo "golem-launch: worktree $wt missing — run worktree-new.sh $N first" >&2
            exit 2
        fi
        # Bare, standalone new-session — matches Bash(tmux new-session:*).
        tmux new-session -d -s "golem-$N" -c "$wt" -e GOLEM_ID="golem-$N" \
            "claude --permission-mode auto '/workflow:next-issue $N --level 4' ; claude --permission-mode auto '/workflow:ship-issue'"
        command echo "golem-launch: started golem-$N in $wt"
        ;;
    *)
        command echo "Usage: golem-launch.sh {preflight | launch <N> | print <N>}" >&2
        exit 2
        ;;
esac
