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
#                    NOTE (#282): the allow-list is NECESSARY, not SUFFICIENT.
#                    The auto-mode safety classifier ([Create Unsafe Agents]) is
#                    a SEPARATE gate that re-evaluates each launch on its own
#                    judgment and is non-deterministic on this launch shape — so
#                    preflight passing does NOT guarantee a launch clears the
#                    classifier. The success message says so; the remedy for a
#                    classifier denial is to RETRY the identical command (it
#                    typically passes), not fall back to a manual `!` paste.
#
#   2. launch <N>  — emit + run exactly ONE bare `tmux new-session` for golem N.
#                    A bare `tmux new-session …` matches `Bash(tmux new-session:*)`;
#                    wrapping N launches in a shell `for` loop makes the whole
#                    command a for-loop STRING that does NOT match the rule and
#                    is re-denied (#29). To dispatch a batch, call `launch <N>`
#                    once per issue — never loop inside one Bash invocation.
#
#   3. auth inject — before dispatch, resolve ANTHROPIC_AUTH_TOKEN (and, when it
#                    comes from the cache, ANTHROPIC_BASE_URL) and pass it to the
#                    golem via `tmux -e` so its session env carries it (#244). A
#                    `tmux`-spawned login shell does NOT re-source the container
#                    startup cache /dev/shm/op-secrets-cache, so without this the
#                    golem starts tokenless and dies at its first network call
#                    (often its own /ship-issue), stranding work in the worktree.
#                    This is an OPTIONAL accelerator, never a dependency: on a
#                    bare host / macOS / OAuth setup (no cache, no `op`, no
#                    OP_*_REF) resolution falls through SILENTLY and dispatches
#                    exactly as before. Every probe is non-interactive and
#                    time-bounded (`op read` is wrapped in bounded-run.sh's
#                    coreutils-free watchdog so a locked op session can never
#                    wedge the launch, on any host); the token is only
#                    injected when actually resolved (never an empty value that
#                    could override what the golem's own shell init would supply)
#                    and is NEVER echoed to a pane or log.
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
# Autonomy level: the launch line carries `/workflow:next-issue <N> --level M`,
# which is what persists `autonomy_level` into the next-issue state file (and
# from there drives /ship-issue's merge disposition). The level is resolved per
# dispatch with precedence: a `--level M` flag > $GOLEM_LEVEL env > the built-in
# default 4. A bare `launch <N>` / `print <N>` therefore behaves exactly as
# before (L4). `--permission-mode auto` is the orthogonal HARNESS flag and is
# unaffected (#301).
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR (.worktrees)   GOLEM_BRANCH_PREFIX (feature/issue-)
#   GOLEM_LEVEL (4)  — autonomy level baked into the launch line when no
#                      per-call --level is given.
#   GOLEM_MODEL (unset) — model passed via --model to every `claude` call in the
#                      launch line; unset emits no --model (inherits the operator
#                      default). Shell-escaped by config.sh's golem_model_flag.
# Preflight scope overrides (env-overridable):
#   CLAUDE_PROJECT_SETTINGS  (.claude/settings.local.json, repo-root-relative)
#   CLAUDE_GLOBAL_SETTINGS   ($HOME/.claude/settings.json)
# Auth-injection overrides (env-overridable; all optional — absence = skip):
#   OP_SECRETS_CACHE         (/dev/shm/op-secrets-cache) — the container startup
#                            cache sourced for ANTHROPIC_AUTH_TOKEN/BASE_URL.
#   OP_ANTHROPIC_AUTH_TOKEN_REF (unset) — an `op://…` ref read (time-bounded) as
#                            the last-resort token source when `op` is on PATH.
# Version-skew overrides (env-overridable):
#   CLAUDE_INSTALLED_PLUGINS ($HOME/.claude/plugins/installed_plugins.json) —
#                            the active-install registry the guard reads.
#   GOLEM_SKIP_VERSION_CHECK (unset) — set to 1 to downgrade a detected skew from
#                            a fatal refusal to a non-fatal warning (legitimate
#                            mid-release / worktree dispatch).
#
# Usage:
#   golem-launch.sh preflight                       # check both scopes; print remediation
#   golem-launch.sh launch <issue-number> [--level M]  # one standalone tmux new-session
#   golem-launch.sh print  <issue-number> [--level M]  # print the launch line only (no run)
#
# Exit codes:
#   0  success (preflight: rules present in at least one scope; launch: started)
#   2  usage error
#   3  preflight: launch rules MISSING in both scopes (actionable, not opaque);
#      launch: plugin version skew detected (running helper != active install)
set -uo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=./bounded-run.sh
. "$SCRIPT_DIR/bounded-run.sh"

# The three rules the documented golem launch path needs under auto mode.
REQUIRED_RULES=(
    'Bash(tmux new-session:*)'
    'Bash(tmux ls:*)'
    'Bash(tmux kill-session:*)'
)

# _bounded_op_read <ref> — print the op secret at <ref> on stdout, wall-clock
# bounded so a locked/absent op session can NEVER hang the dispatch (we have seen
# `op` block on "connecting to desktop app"). Any non-zero / empty result → prints
# nothing. Never prints diagnostics (would risk leaking).
#
# Bounded via bounded-run.sh (#543). This used to try `timeout`, then `gtimeout`,
# and SKIP the probe entirely when neither existed — safe, but it silently
# disabled op-based auth on exactly the base-macOS host the fallback was written
# for. The pure-shell watchdog needs only sleep/kill/mktemp, so the probe now both
# runs and stays bounded everywhere.
_bounded_op_read() {
    local ref="$1"
    [ -n "$ref" ] || return 0
    command -v op >/dev/null 2>&1 || return 0
    bounded_run 5 op read "$ref" 2>/dev/null || true
}

# resolve_auth_token — set RESOLVED_AUTH_TOKEN (and RESOLVED_BASE_URL when it
# came from the cache) WITHOUT ever printing the value. Resolution order, first
# hit wins:
#   1. the launcher's own inherited env ($ANTHROPIC_AUTH_TOKEN);
#   2. the container startup cache ($OP_SECRETS_CACHE, default
#      /dev/shm/op-secrets-cache) — sourced in a SUBSHELL so its other exports
#      never leak into the launcher, emitting just token<TAB>baseurl;
#   3. a last-resort time-bounded `op read` of $OP_ANTHROPIC_AUTH_TOKEN_REF.
# Every arm degrades to empty (→ no injection) when its source is absent, so on a
# bare host / macOS / OAuth setup this is a silent no-op.
RESOLVED_AUTH_TOKEN=""
RESOLVED_BASE_URL=""
resolve_auth_token() {
    RESOLVED_AUTH_TOKEN=""
    RESOLVED_BASE_URL=""

    # 1. Already in the launcher's env — nothing to resolve.
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        RESOLVED_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN"
        RESOLVED_BASE_URL="${ANTHROPIC_BASE_URL:-}"
        return 0
    fi

    # 2. Container startup cache. Source in a subshell (its other secrets stay
    # out of the launcher env) and emit token<TAB>baseurl; the cache's own stdout
    # is muted so a chatty cache can't corrupt the capture.
    local cache="${OP_SECRETS_CACHE:-/dev/shm/op-secrets-cache}" line
    if [ -r "$cache" ]; then
        line="$(
            # shellcheck disable=SC1090  # dynamic, host-provided cache path
            . "$cache" >/dev/null 2>&1
            command printf '%s\t%s' "${ANTHROPIC_AUTH_TOKEN:-}" "${ANTHROPIC_BASE_URL:-}"
        )"
        RESOLVED_AUTH_TOKEN="${line%%$'\t'*}"
        RESOLVED_BASE_URL="${line#*$'\t'}"
        [ -n "$RESOLVED_AUTH_TOKEN" ] && return 0
        RESOLVED_BASE_URL=""
    fi

    # 3. Last resort: a time-bounded `op read` of the configured ref.
    if [ -n "${OP_ANTHROPIC_AUTH_TOKEN_REF:-}" ]; then
        RESOLVED_AUTH_TOKEN="$(_bounded_op_read "$OP_ANTHROPIC_AUTH_TOKEN_REF")"
    fi
    return 0
}

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
    root="$(repo_root)" || root="$(command pwd)"
    proj_settings="$root/${CLAUDE_PROJECT_SETTINGS:-.claude/settings.local.json}"
    global_settings="${CLAUDE_GLOBAL_SETTINGS:-$HOME/.claude/settings.json}"

    local in_project=1 in_global=1
    settings_has_rules "$proj_settings" && in_project=0
    settings_has_rules "$global_settings" && in_global=0

    if [ "$in_project" -eq 0 ] || [ "$in_global" -eq 0 ]; then
        local where="project ($proj_settings)"
        [ "$in_global" -eq 0 ] && where="global ($global_settings)"
        command echo "golem-launch: tmux launch allow-list rules present in $where (necessary, not sufficient). The auto-mode classifier is a SEPARATE gate that re-evaluates each launch on its own judgment — a [Create Unsafe Agents] denial is non-deterministic; retry the identical command (it typically passes)."
        return 0
    fi

    # Missing in BOTH scopes — emit an ACTIONABLE suggestion, never an opaque
    # classifier denial, and never write settings silently. The operator picks
    # the scope and authorizes the add.
    command cat >&2 <<EOF
golem-launch: REQUIRED tmux launch permissions are NOT authorized in either scope.

Without them, a golem dispatch (\`tmux new-session …\`) is DENIED by the
Claude Code auto-mode classifier ([Create Unsafe Agents]) — an opaque hard wall
on the first \`/workflow:orchestrate dispatch\`.

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
  - Re-run /workflow:orchestrate after updating the plugin so the loaded skill and its
    helper are the SAME version (claude plugin update workflow@librarian).
  - Dispatch from the active install's helper directly.
  - If this skew is intentional (mid-release / worktree testing), re-run with
    GOLEM_SKIP_VERSION_CHECK=1 to downgrade this refusal to a warning.
EOF
    exit 3
}

# resolve_level [flag-level] — echo the effective autonomy level (1-4) with
# precedence: an explicit --level value > $GOLEM_LEVEL env > the built-in
# default 4. Validates the result as a single digit 1-4; on an out-of-range or
# non-numeric value it prints an actionable message and exits 2 (mirroring the
# issue-number guard). Kept as a function so `launch` and `print` resolve the
# level identically (one source of truth).
resolve_level() {
    local level="${1:-${GOLEM_LEVEL:-4}}"
    if ! [[ "$level" =~ ^[1-4]$ ]]; then
        command echo "golem-launch: --level must be 1, 2, 3, or 4, got '$level'" >&2
        exit 2
    fi
    command echo "$level"
}

# parse_level_flag <arg3> <arg4> — echo the raw level to hand resolve_level for
# the optional trailing `--level M`. Prints nothing when no `--level` was given
# (→ resolve_level falls to $GOLEM_LEVEL/4). A bare `--level` with no value is
# malformed: exit 2 rather than silently defaulting (fail loud — the whole point
# of #301 is that a wrong/absent level must not pass unnoticed).
parse_level_flag() {
    [ "${1:-}" = "--level" ] || return 0
    if [ -z "${2:-}" ]; then
        command echo "golem-launch: --level needs a value (1-4)" >&2
        exit 2
    fi
    command echo "$2"
}

# launch_line <N> <level> — print the single bare `tmux new-session` command for
# golem N at autonomy <level>. Kept as a function so `launch` and `print` share
# one definition (one source of truth for the launch shape).
launch_line() {
    local n="$1" level="$2" root wt
    root="$(repo_root)" || root="$(command pwd)"
    wt="$root/$GOLEM_WORKTREE_DIR/issue-$n"
    # ONE standalone new-session, matching Bash(tmux new-session:*). The chained
    # `;` second prompt is the resume backstop (NOT `&&`); see orchestrate
    # SKILL.md Phase D / mode-protocol.md § Supervised launch.
    local model_flag
    model_flag="$(golem_model_flag)"
    command printf '%s' \
        "tmux new-session -d -s golem-$n -c \"$wt\" -e GOLEM_ID=golem-$n \"claude$model_flag --permission-mode auto '/workflow:next-issue $n --level $level' ; claude$model_flag --permission-mode auto '/workflow:ship-issue'\""
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
        # Optional `--level M` after the issue number; else $GOLEM_LEVEL / 4.
        LEVEL_FLAG="$(parse_level_flag "${3:-}" "${4:-}")" || exit $?
        LEVEL="$(resolve_level "$LEVEL_FLAG")" || exit $?
        # Warn (never block) if the emitted line's namespace may be stale.
        check_version_skew print
        launch_line "$N" "$LEVEL"
        command echo ""
        ;;
    launch)
        N="${2:-}"
        if ! [[ "$N" =~ ^[0-9]+$ ]]; then
            command echo "golem-launch: launch needs an issue number, got '$N'" >&2
            exit 2
        fi
        # Optional `--level M` after the issue number; else $GOLEM_LEVEL / 4.
        # Resolve (and validate) BEFORE the version-skew/preflight side effects
        # so a bad level fails fast with exit 2.
        LEVEL_FLAG="$(parse_level_flag "${3:-}" "${4:-}")" || exit $?
        LEVEL="$(resolve_level "$LEVEL_FLAG")" || exit $?
        # Version-skew guard FIRST — refuse (exit 3) before any tmux side effect
        # if this stale helper would emit commands the active plugin can't resolve
        # (#230). Skips silently when versions match or are undeterminable.
        check_version_skew launch
        # Preflight next so a missing rule surfaces as guidance, not an opaque
        # classifier denial. Continue on exit 3 so a host that authorizes
        # allow-once (without persisting the rule) can still proceed this run.
        preflight || true
        root="$(repo_root)" || root="$(command pwd)"
        wt="$root/$GOLEM_WORKTREE_DIR/issue-$N"
        if [ ! -d "$wt" ]; then
            command echo "golem-launch: worktree $wt missing — run worktree-new.sh $N first" >&2
            exit 2
        fi
        # Resolve the auth token (#244) and build the tmux `-e` env args. Only
        # inject ANTHROPIC_AUTH_TOKEN when it actually resolved — an empty value
        # is NEVER passed (it could override a token the golem's own shell init
        # would otherwise supply on a host). ANTHROPIC_BASE_URL rides along only
        # when it came from the cache AND the launcher's own env lacks it.
        resolve_auth_token
        env_args=(-e "GOLEM_ID=golem-$N")
        if [ -n "$RESOLVED_AUTH_TOKEN" ]; then
            env_args+=(-e "ANTHROPIC_AUTH_TOKEN=$RESOLVED_AUTH_TOKEN")
            if [ -n "$RESOLVED_BASE_URL" ] && [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
                env_args+=(-e "ANTHROPIC_BASE_URL=$RESOLVED_BASE_URL")
            fi
        elif [ -e "${OP_SECRETS_CACHE:-/dev/shm/op-secrets-cache}" ]; then
            # A cache marker exists but nothing resolved — this env looks like it
            # NEEDS a token, so warn (don't fail) rather than silently dispatch a
            # golem that will die at ship time. Bare host / no cache falls through
            # to no warning at all.
            command echo "golem-launch: WARNING no ANTHROPIC_AUTH_TOKEN resolvable though an op-secrets cache is present; golem-$N may start unauthenticated. Dispatching anyway." >&2
        fi
        # Bare, standalone new-session — matches Bash(tmux new-session:*). The
        # token lives only inside env_args (never echoed) so it can't leak to a
        # pane or log. $(golem_model_flag) splices ` --model "…"` after each
        # `claude` when GOLEM_MODEL is set, and expands to nothing (byte-identical
        # launch line) when unset.
        MODEL_FLAG="$(golem_model_flag)"
        tmux new-session -d -s "golem-$N" -c "$wt" "${env_args[@]}" \
            "claude$MODEL_FLAG --permission-mode auto '/workflow:next-issue $N --level $LEVEL' ; claude$MODEL_FLAG --permission-mode auto '/workflow:ship-issue'"
        command echo "golem-launch: started golem-$N in $wt"
        ;;
    *)
        command echo "Usage: golem-launch.sh {preflight | launch <N> [--level M] | print <N> [--level M]}" >&2
        exit 2
        ;;
esac
