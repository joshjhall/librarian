#!/usr/bin/env bash
# config.sh — shared, env-overridable configuration for the workflow plugin's
# bundled golem/worktree scripts. Source this near the top of every script:
#
#     SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
#     # shellcheck source=./config.sh
#     . "$SCRIPT_DIR/config.sh"
#
# These scripts were de-coupled from the containers repo's justfile so the
# golem/worktree flow runs WITHOUT `just` — on a host, on bare Linux, or inside
# a devcontainer. Every tunable below has a sane default and is overridable from
# the environment, so a project can relocate worktrees or rename branches
# without editing the scripts.
#
# Tunables (all overridable via the environment):
#   GOLEM_WORKTREE_DIR   Directory (repo-root-relative) holding per-issue
#                        worktrees.                      Default: .worktrees
#   GOLEM_STATUS_DIR     Directory holding golem status JSON + feed.jsonl.
#                        Default: <GOLEM_WORKTREE_DIR>/.status
#   GOLEM_EVENT_SINKS    Space/comma-separated list of http(s):// endpoints the
#                        golem-notify.sh Notification hook POSTs each classified
#                        event to, IN ADDITION to feed.jsonl (which is always
#                        written). Empty/unset ⇒ feed only, no network calls —
#                        byte-for-byte the pre-#406 behavior. Each POST is
#                        best-effort and bounded (never blocks the golem).
#                                                          Default: (empty)
#   GOLEM_EVENT_SINK_TIMEOUT
#                        Per-POST connect+total timeout (seconds) for each
#                        GOLEM_EVENT_SINKS endpoint, so a slow/dead sink can
#                        never wedge the golem.            Default: 2
#   GOLEM_BRANCH_PREFIX  Branch-name prefix; the branch for issue N is
#                        "<prefix><N>".                  Default: feature/issue-
#   GOLEM_LEVEL          Autonomy level (1-4) baked into a golem's launch line
#                        by golem-launch.sh. Overridden per-call by
#                        `launch/print <N> --level M`.   Default: 4
#   GOLEM_BASE_REF       The ref new worktree branches fork from.
#                        Default: origin/main
#   GOLEM_WORKTREE_LOCAL_FILES
#                        Space-separated list of gitignored, machine-local files
#                        copied from the main checkout into a fresh worktree so a
#                        push from inside it has what it needs (e.g. .env,
#                        .claude/settings.local.json). Empty disables copying.
#                        Default: ".env .claude/settings.local.json"
#   GOLEM_STALL_THRESHOLD
#                        Liveness window, seconds. A golem with no detectable
#                        progress (worktree / status-cache activity) for longer
#                        than this is flagged a *possible stall* (SOFT, advisory
#                        — never auto-killed).            Default: 1200 (20 min)
#   GOLEM_HEARTBEAT_INTERVAL
#                        Poll interval for the liveness stream (--stream-liveness),
#                        seconds.                         Default: 60
#   GOLEM_INBOX_WAIT     Per-call ceiling, seconds, of golem-inbox.sh `consume`'s
#                        bounded-blocking read (the orchestrator-brokered gate
#                        reverse channel, #227). Kept below the Bash tool's 600s
#                        call ceiling; a golem re-invokes `consume` in a loop on
#                        the NO-DECISION sentinel so "wait indefinitely" holds
#                        without any single call hitting the ceiling.
#                                                          Default: 300 (5 min)
#   GOLEM_INBOX_POLL     Poll interval, seconds, of `consume`'s inner loop while
#                        it waits for a matching decision.  Default: 3
#   GOLEM_SWEEP_INTERVAL Cadence, seconds, of the orchestrator's Phase M status
#                        sweep (golem-status.sh --watch, #304). Env OVERRIDE for
#                        the level-scaled default: unset -> the per-level cadence
#                        from autonomy-resolve.sh (L1 180 / L2 300 / L3 480 / L4
#                        900). Deliberately has NO `:=` default line below — its
#                        absence must fall through to the resolver, so
#                        golem-status.sh reads it directly rather than defaulting
#                        it here.                          Default: (unset)
#
# This file only DEFINES variables (no side effects beyond `export`), so it is
# safe to source from any script.

# Use full paths / the `command` builtin for coreutils throughout these scripts:
# aliases or shell functions can change output format and break parsing.

# Per-issue worktree dir, repo-root-relative.
: "${GOLEM_WORKTREE_DIR:=.worktrees}"

# Golem status cache + feed, repo-root-relative (sits under the worktree dir by
# default so it travels with it).
: "${GOLEM_STATUS_DIR:=${GOLEM_WORKTREE_DIR}/.status}"

# Multi-sink event fan-out (#406, ADR-0001 Decision 2). golem-notify.sh writes
# feed.jsonl ALWAYS and, in addition, POSTs each classified event to every
# http(s):// URL in GOLEM_EVENT_SINKS (space/comma list), best-effort and bounded
# by GOLEM_EVENT_SINK_TIMEOUT so a dead endpoint never wedges the golem. Empty
# default ⇒ feed only, no network — the pre-#406 behavior unchanged. NOTE: the
# hook inlines these two defaults rather than sourcing config.sh (see its header),
# so this block is their documented home; the two stay pinned equivalent by
# tests/validate-golem-notify.sh's test_event_sink_defaults_match_config_sh
# drift guard.
#
# TRUST BOUNDARY: GOLEM_EVENT_SINKS is fully-trusted OPERATOR input — the same
# trust model as PATH for these scripts (see repo_root's PATH-trust note below)
# and the sinks the containers claude-host-event.sh already POSTs to. The event
# payload carries the golem's classified message (which may include in-flight
# permission-request text / file paths), and the hook does NOT restrict the host
# (loopback/link-local/RFC1918/cloud-metadata are all reachable), enforce https,
# or sign the request. So a sink URL is as sensitive as PATH: point it only at an
# endpoint you control. Host allow-listing, https-only, and a shared-secret auth
# header are deliberate NON-goals of this emitter — they belong to the
# orchestrator-side receiver follow-up (#407), not this best-effort fan-out.
: "${GOLEM_EVENT_SINKS:=}"
: "${GOLEM_EVENT_SINK_TIMEOUT:=2}"

# Branch naming: issue N -> "<GOLEM_BRANCH_PREFIX><N>".
: "${GOLEM_BRANCH_PREFIX:=feature/issue-}"

# Autonomy level (1-4) baked into a golem's launch line by golem-launch.sh. A
# per-call `--level M` flag overrides this; absent both, the launcher defaults
# to 4. This env fallback carries the operator's chosen level to callers that
# set it in the environment rather than passing the flag.
: "${GOLEM_LEVEL:=4}"

# Ref that new worktree branches are created from.
: "${GOLEM_BASE_REF:=origin/main}"

# Gitignored machine-local files a push from inside a worktree needs.
: "${GOLEM_WORKTREE_LOCAL_FILES:=.env .claude/settings.local.json}"

# Liveness/heartbeat (SOFT, advisory — never auto-kills a golem):
# how long a golem may show no progress before it is flagged a possible stall,
# and the poll interval of the liveness stream.
: "${GOLEM_STALL_THRESHOLD:=1200}"
: "${GOLEM_HEARTBEAT_INTERVAL:=60}"

# Orchestrator-brokered gate reverse channel (golem-inbox.sh, #227): the
# per-call ceiling and poll interval of `consume`'s bounded-blocking read. The
# ceiling stays under the Bash tool's 600s per-call limit; the golem re-invokes
# `consume` in a loop on NO-DECISION so the never-time-out rule holds without any
# single call approaching the ceiling.
: "${GOLEM_INBOX_WAIT:=300}"
: "${GOLEM_INBOX_POLL:=3}"

export GOLEM_WORKTREE_DIR GOLEM_STATUS_DIR GOLEM_BRANCH_PREFIX GOLEM_LEVEL \
    GOLEM_BASE_REF GOLEM_WORKTREE_LOCAL_FILES GOLEM_STALL_THRESHOLD \
    GOLEM_HEARTBEAT_INTERVAL GOLEM_INBOX_WAIT GOLEM_INBOX_POLL \
    GOLEM_EVENT_SINKS GOLEM_EVENT_SINK_TIMEOUT

# GIT_ENV_SCRUB_VARS — git's hook-exported environment variables that
# _repo_root_git (below) and the worktree-new/-rm callers scrub before running
# git, so a tainted env forwarded from a git hook cannot pin git at an OUTER repo
# (#279 / #328 / #355). SINGLE SOURCE OF TRUTH: all three scrub sites reference
# this one list (via _git_env_scrub_names below), so a future addition lands in
# ONE place instead of needing a lockstep edit across three files where a missed
# copy silently reopens the vulnerability class (#356).
#
# The set spans three redirect classes:
#   1. PATH redirect (#279/#328) — GIT_DIR / GIT_COMMON_DIR / GIT_WORK_TREE and
#      the object/index/prefix vars pin git at an outer repo directly (the
#      original 7-name set; see the assignment below for the exact members).
#   2. CONFIG injection (#355) — GIT_CONFIG_COUNT (with its indexed
#      GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n> pairs, scrubbed dynamically by
#      _git_env_scrub_names — they are not fixed names), GIT_CONFIG_PARAMETERS
#      (the shell-quoted single-var encoding of the SAME key=value injection —
#      a fixed name, so it lives in the static list), and
#      GIT_CONFIG_GLOBAL/SYSTEM/NOSYSTEM inject or swap config (e.g.
#      core.worktree, url.<base>.insteadOf) that redirects where a mutation lands
#      WITHOUT touching GIT_DIR.
#   3. DISCOVERY availability (#355) — GIT_CEILING_DIRECTORIES /
#      GIT_DISCOVERY_ACROSS_FILESYSTEM can make discovery FAIL, an availability
#      regression on a golem host whose hook sets them.
#
# A space-separated string, NOT `declare -A` (bash-3.2 clean per
# tests/lint-shell-portability.sh). Deliberately a PLAIN assignment, not an
# env-overridable `: "${GIT_ENV_SCRUB_VARS:=…}"` default — the scrub set is a
# security invariant, and letting the environment shrink or empty it would defeat
# the very taint it defends against. The two consumption forms differ (`unset
# $list` word-split vs `env -u <v> …`), so only the NAME LIST is shared, expanded
# differently at each site.
GIT_ENV_SCRUB_VARS="GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM"

# _git_env_scrub_names — the EFFECTIVE scrub name list: the static
# GIT_ENV_SCRUB_VARS plus any dynamically-indexed GIT_CONFIG_KEY_<n> /
# GIT_CONFIG_VALUE_<n> pairs currently present in the environment. git reads
# those pairs when GIT_CONFIG_COUNT is set (#355), but the count — hence the
# index range — is dynamic, so they can't be fixed entries in GIT_ENV_SCRUB_VARS;
# they must be enumerated at scrub time. `${!prefix@}` prefix expansion is
# bash-3.2 available (NOT a bash-4 construct — see tests/lint-shell-portability.sh)
# and expands to nothing under `set -u` when no var matches, so the `for` is safe
# even with no pairs present. All three scrub sites word-split this helper's
# output, so the static list AND the dynamic pairs are scrubbed identically and
# defined in exactly one place.
_git_env_scrub_names() {
    command printf '%s' "$GIT_ENV_SCRUB_VARS"
    local _n
    for _n in ${!GIT_CONFIG_KEY_@} ${!GIT_CONFIG_VALUE_@}; do
        command printf ' %s' "$_n"
    done
}

# _repo_root_git — run `git "$@"` with git's hook-exported environment scrubbed,
# safe even when a GIT_* var is READONLY (`declare -rx GIT_DIR=…`), which a bare
# `unset` cannot clear (issue #328 — the readonly gap #279's plain unset left
# open). MUST be called inside a command-substitution subshell so the scrub stays
# contained and never leaks back to the caller (the whole point of #279).
#
# Try plain `unset` first: it needs no PATH lookup, so the common path stays
# dependency-free and the PATH-stripped test harness (repo_root resolved with
# only `git` on PATH, #278) keeps working. On a readonly GIT_* var `unset` FAILS,
# so fall back to `env -u`, which UNEXPORTS the vars for the git child regardless
# of the readonly attribute — `repo_root()` then still resolves the real root
# rather than the tainted one. `env` (and git) are PATH-resolved (`command env` /
# the child `git`), matching #278's no-hardcoded-/usr/bin rule; env is reached
# ONLY on the readonly path, never in the common case.
#
# Both arms consume the shared scrub name list via _git_env_scrub_names (#356 /
# #355): the `unset` arm word-splits it directly; the `env -u` arm builds one
# `-u <name>` pair per member (the readonly-attribute-independent form), so the
# effective scrub set is identical and defined in exactly one place — including
# the dynamic GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n> pairs the helper enumerates.
_repo_root_git() {
    local _names _u _v
    _names="$(_git_env_scrub_names)"
    # shellcheck disable=SC2086  # intentional word-split: unset each scrub var by name
    if unset $_names 2>/dev/null; then
        command git "$@"
    else
        _u=""
        for _v in $_names; do
            _u="$_u -u $_v"
        done
        # shellcheck disable=SC2086  # intentional word-split of the built -u <name> pairs
        command env $_u git "$@"
    fi
}

# repo_root — print the main checkout's root directory, bare-repo-safe.
#
# `git rev-parse --show-toplevel` ABORTS in a bare repository (the worktree-host
# layout the golem flow runs on). Resolve the root from the git COMMON dir
# instead, whose parent is the main checkout — cwd- and bare-independent, and
# from inside a worktree it still returns the MAIN root (worktrees share the
# common dir), which is what the scripts want.
#
# Prints the absolute root on stdout and returns 0; prints nothing and returns 1
# when not inside a git repository.
repo_root() {
    local super_root common_dir
    # Submodule case: when these scripts run from inside a git SUBMODULE working
    # tree (the golem flow vendored into a consuming repo as a submodule),
    # --git-common-dir below resolves to <superproject>/.git/modules/<name>, so
    # the common-dir logic would return <superproject>/.git/modules — a
    # git-internal path — and `git worktree add` would land worktrees under
    # .git/modules/.worktrees/issue-N instead of <superproject>/.worktrees/issue-N
    # (issue #324, migrated from containers#637). Prefer the superproject
    # working-tree root, which `git rev-parse --show-superproject-working-tree`
    # prints ONLY when inside a submodule (empty otherwise) — so it is both the
    # detector and the correct value; an empty result falls through to the
    # common-dir resolution below (normal repos + bare-repo worktree hosts,
    # unchanged). Same env scrub as the common-dir probe (#279 hook-safety): a
    # tainted GIT_DIR/GIT_COMMON_DIR must not pin the resolved root to an outer
    # repo. Scrub lives in this probe's own subshell, keeping config.sh
    # side-effect-free at source time (see the file header).
    super_root="$(
        _repo_root_git rev-parse --path-format=absolute --show-superproject-working-tree 2>/dev/null || true
    )"
    if [ -n "$super_root" ]; then
        # --path-format=absolute should guarantee absolute, but stay defensive
        # (mirrors the common-dir arm below).
        case "$super_root" in
            /*) ;;
            *) super_root="$(command pwd)/$super_root" ;;
        esac
        command echo "$super_root"
        return 0
    fi

    # Resolve git via PATH (`command git`), not a hardcoded /usr/bin/git — on a
    # host where git lives elsewhere (minimal container, NixOS, Homebrew-first
    # macOS) the absolute path exits 127, gets swallowed by `|| true`, and this
    # would silently return empty, tripping every caller's "not a repo" branch
    # inside a valid repo (issue #278, sibling of #228/#241).
    # NOTE: git is PATH-resolved here, so repo_root() trusts the first `git` on
    # PATH. seed-worktree-trust.sh anchors its under-root check to this value
    # (#21), so a caller that prepends a malicious `git` to PATH could spoof the
    # root — an accepted trade-off matching worktree-new.sh (#228/#241); these
    # scripts assume an operator-controlled PATH.
    #
    # Scrub git's hook-exported environment for THIS rev-parse (via
    # _repo_root_git). When repo_root() is invoked from inside a git hook (or a
    # wrapper forwarding a tainted env), GIT_DIR / GIT_COMMON_DIR / … would
    # otherwise pin `--git-common-dir` to an OUTER repo, so repo_root() would
    # RETURN the wrong root — redirecting seed-worktree-trust.sh's #21 under-root
    # trust guard, whose only git use is this return value (issue #279). The scrub
    # lives in the rev-parse's own command-substitution subshell so it scrubs
    # exactly where it matters and never leaks back to the caller's environment,
    # keeping config.sh side-effect-free at source time (see the file header).
    # _repo_root_git also closes the readonly-GIT_DIR gap #279's plain unset left
    # open (a `declare -rx GIT_DIR` taint), falling back to `env -u` (issue #328).
    #
    # SCOPE: this hardens repo_root()'s RETURN VALUE only. A caller that issues
    # its OWN direct git commands after repo_root() (e.g. worktree-new.sh's
    # `git worktree add`, worktree-rm.sh's `git branch -D`) runs them in its own
    # process environment; those callers now scrub it process-wide right after
    # sourcing config.sh (issue #328), so a tainted GIT_DIR can no longer redirect
    # their mutations to an outer repo.
    common_dir="$(
        _repo_root_git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
    )"
    if [ -z "$common_dir" ]; then
        command echo "repo-root: not inside a git repository" >&2
        return 1
    fi
    # --path-format=absolute should guarantee absolute, but stay defensive.
    case "$common_dir" in
        /*) ;;
        *) common_dir="$(command pwd)/$common_dir" ;;
    esac
    # Pure-bash dirname (no /usr/bin/dirname). common_dir is absolute here (forced
    # just above), so it always contains a slash: strip the trailing /<name>.
    # Stripping a single-slash path (e.g. "/.git", a bare repo rooted at /) leaves
    # the empty string; GNU dirname returns "/" there, so fall back to "/".
    local parent="${common_dir%/*}"
    command echo "${parent:-/}"
}
