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
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR (.worktrees)   GOLEM_BRANCH_PREFIX (feature/issue-)
# Preflight scope overrides (env-overridable):
#   CLAUDE_PROJECT_SETTINGS  (.claude/settings.local.json, repo-root-relative)
#   CLAUDE_GLOBAL_SETTINGS   ($HOME/.claude/settings.json)
#
# Usage:
#   golem-launch.sh preflight                # check both scopes; print remediation
#   golem-launch.sh launch <issue-number>    # one standalone tmux new-session
#   golem-launch.sh print  <issue-number>    # print the launch line only (no run)
#
# Exit codes:
#   0  success (preflight: rules present in at least one scope; launch: started)
#   2  usage error
#   3  preflight: launch rules MISSING in both scopes (actionable, not opaque)
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
        "tmux new-session -d -s golem-$n -c \"$wt\" -e GOLEM_ID=golem-$n \"claude --permission-mode auto '/next-issue $n --auto' ; claude --permission-mode auto '/next-issue-ship --auto'\""
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
        launch_line "$N"
        command echo ""
        ;;
    launch)
        N="${2:-}"
        if ! [[ "$N" =~ ^[0-9]+$ ]]; then
            command echo "golem-launch: launch needs an issue number, got '$N'" >&2
            exit 2
        fi
        # Preflight first so a missing rule surfaces as guidance, not an opaque
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
            "claude --permission-mode auto '/next-issue $N --auto' ; claude --permission-mode auto '/next-issue-ship --auto'"
        command echo "golem-launch: started golem-$N in $wt"
        ;;
    *)
        command echo "Usage: golem-launch.sh {preflight | launch <N> | print <N>}" >&2
        exit 2
        ;;
esac
