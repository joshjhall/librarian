#!/usr/bin/env bash
# config.sh — shared, env-overridable configuration for the workflow plugin's
# bundled golem/worktree scripts. Source this near the top of every script:
#
#     SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
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
#   GOLEM_EVENT_LISTEN_ADDR
#                        Bind address of golem-event-listener (the #407 receiver
#                        that appends POSTed events into feed.jsonl). Loopback by
#                        default so it is not reachable off-host unless the
#                        operator deliberately widens it.  Default: 127.0.0.1
#   GOLEM_EVENT_LISTEN_PORT
#                        Bind port of golem-event-listener; the port a container
#                        golem's GOLEM_EVENT_SINKS points at.  Default: 8787
#   GOLEM_EVENT_MAX_BODY Max accepted request-body size (bytes) for the listener,
#                        so an oversized POST is rejected, not buffered.
#                                                          Default: 65536
#   GOLEM_BRANCH_PREFIX  Branch-name prefix; the branch for issue N is
#                        "<prefix><N>".                  Default: feature/issue-
#   GOLEM_LEVEL          Autonomy level (1-4) baked into a golem's launch line
#                        by golem-launch.sh. Overridden per-call by
#                        `launch/print <N> --level M`.   Default: 4
#   GOLEM_MODEL          Model passed (via `--model`) to every `claude`
#                        invocation in a golem's launch line — both the
#                        next-issue and ship-issue calls. Unset → NO `--model`
#                        is emitted, so the golem inherits the operator/session
#                        default (typically Opus) and the launch line is
#                        byte-identical to the pre-knob behavior. Set (e.g.
#                        `GOLEM_MODEL=sonnet`) to run the whole multi-hour
#                        pipeline on a cheaper model.     Default: (unset)
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
#   GOLEM_LIVENESS_SUMMARY_INTERVAL
#                        Cadence of the aggregate one-line liveness summary on
#                        --stream-liveness, seconds; 0 disables it. The per-golem
#                        heartbeat is transition-deduped (#489), so this is the
#                        only periodic positive signal.    Default: 900 (15 min)
#   GOLEM_INBOX_WAIT     Per-call ceiling, seconds, of golem-inbox.sh `consume`'s
#                        bounded-blocking read (the orchestrator-brokered gate
#                        reverse channel, #227). Kept below the Bash tool's 600s
#                        call ceiling; a golem re-invokes `consume` in a loop on
#                        the NO-DECISION sentinel so "wait indefinitely" holds
#                        without any single call hitting the ceiling.
#                                                          Default: 300 (5 min)
#   GOLEM_INBOX_POLL     Poll interval, seconds, of `consume`'s inner loop while
#                        it waits for a matching decision.  Default: 3
#   GOLEM_MODE_FIX_ATTEMPTS
#                        Max mode-cycle keystrokes golem-mode-check.sh --fix will
#                        send to ONE golem in a single run before giving up and
#                        escalating. Bounds the #659 auto-correct so a genuine
#                        mode-lock (the keystroke does not stick) escalates to the
#                        operator instead of becoming an infinite keystroke loop.
#                                                          Default: 3
#   GOLEM_MODE_CHECK_INTERVAL
#                        Poll interval, seconds, of golem-mode-check.sh --watch.
#                        Drift is corrected within one poll rather than at
#                        operator noticing.                Default: 60
#   GOLEM_SWEEP_INTERVAL Cadence, seconds, of the orchestrator's Phase M status
#                        sweep (golem-status.sh --watch; opt-in since #485,
#                        was default-on #304). Env OVERRIDE for
#                        the level-scaled default: unset -> the per-level cadence
#                        from autonomy-resolve.sh (L1 180 / L2 300 / L3 480 / L4
#                        900). Deliberately has NO `:=` default line below — its
#                        absence must fall through to the resolver, so
#                        golem-status.sh reads it directly rather than defaulting
#                        it here.                          Default: (unset)
#   BIFROST_URL          Base URL of the Bifrost gateway's ADMIN API, used by
#                        token-report.sh (#781). REQUIRED — deliberately has no
#                        default, because there is no correct one to guess: the
#                        issue's AC5 forbids a hardcoded hostname, and the
#                        obvious candidate is wrong. ANTHROPIC_BASE_URL points at
#                        the *proxy* path (…/anthropic); `/api/logs/stats` under
#                        it returns the web UI's HTML shell with HTTP 200, not
#                        JSON — a silent wrong answer, the exact failure class
#                        #781 exists to prevent. Point this at the gateway ROOT
#                        (e.g. https://bifrost.example). Unset ⇒ usage error
#                        (exit 2), which is distinct from unreachable (77).
#                                                          Default: (unset)
#   TOKEN_REPORT_TIMEOUT
#                        Per-request connect+total timeout, seconds, for every
#                        token-report.sh gateway call. The aggregate endpoint
#                        answers in ~16ms, so this bounds a hung/black-holed
#                        gateway rather than slow work.     Default: 30
#   TOKEN_REPORT_RECONCILE_PCT
#                        Reconciliation tolerance, PERCENT of the unfiltered
#                        request total. token-report.sh sums the per-model
#                        request counts and compares them against the same
#                        window queried unfiltered; a gap wider than this is a
#                        hard failure (exit 1). A COMPLETE model list reconciles
#                        EXACTLY (measured delta 0), so the tolerance is headroom,
#                        not an observed need — it absorbs a request the gateway
#                        attributes to no model without turning that into a hard
#                        failure. Keep it tight: it must stay far below the
#                        N-fold gap a dropped `models=` filter opens (measured at
#                        a 14x overstatement). Note an incomplete model list also
#                        inflates the gap, but that is caught earlier and by
#                        name — see enumerate_models.
#                                                          Default: 0.5
#   CONTEXT_BUDGET_THRESHOLD
#                        Session context size, in tokens, at which a golem hands
#                        off to a fresh session rather than starting new work
#                        (#784). Read by context-budget.sh, which turns it into
#                        an ok/advise/handoff verdict; the advisory band opens at
#                        80% of it.
#                        DERIVED, NOT PICKED (the issue's AC2). Pure token
#                        accounting is monotonic — cycling sooner always wins —
#                        so the sweep only yields a threshold once the
#                        re-derivation cost of a handoff is priced in. Doing that
#                        and sweeping the handoff cost across its whole plausible
#                        range, 175k minimizes WORST-CASE regret (4.1%, vs 6.1%
#                        at 150k and 14.5% at 250k). This supersedes the 250-300k
#                        figure in #784's body, which assumed a 78k floor against
#                        a measured ~91k. Derivation + reproduction recipe:
#                        docs/verification/context-threshold-derivation-784.md.
#                                                          Default: 175000
#   CONTEXT_BUDGET_FLOOR The measured cost of a session's FIRST request — the
#                        system prompt, tools, and skill preamble a fresh session
#                        re-pays before it does anything (#784). Emitted by
#                        context-budget.sh as context for the verdict: it is what
#                        a handoff costs, so it is what makes cycling too eagerly
#                        a net loss. Measured ~91k across 28 local sessions.
#                                                          Default: 91000
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

# Orchestrator-side event RECEIVER (#407, ADR-0001 Decision 3 — the consumption
# half of the multi-sink bus above). golem-event-listener.{py,sh} is an OPTIONAL
# HTTP listener that receives the events golem-notify.sh POSTs to a
# GOLEM_EVENT_SINKS endpoint and appends each into THIS orchestrator's feed.jsonl,
# so the existing golem-gate-watch.sh --stream Monitor floor surfaces a container
# golem's gate identically to a locally-emitted one. It binds a socket only when
# the operator runs it; absent, the feed + Monitor floor is unchanged (AC2). See
# golem-event-listener.py for the full design and trust notes.
#
# TRUST BOUNDARY: the receiver is the counterpart to the emitter's trust model.
# It binds LOOPBACK (GOLEM_EVENT_LISTEN_ADDR=127.0.0.1) by default, so it is not
# reachable off-host unless the operator deliberately widens the bind address.
# The received message is only ever re-serialized into the feed as a JSON string
# (never interpreted as an instruction/path/shell word) and the body is bounded
# by GOLEM_EVENT_MAX_BODY, so a malformed/oversized POST is rejected without
# writing a feed line or crashing the listener. Host allow-listing beyond the
# loopback default, TLS, and request signing stay deliberate NON-goals of this
# best-effort receiver — the same stance the #406 emitter documented as the
# receiver's concern.
: "${GOLEM_EVENT_LISTEN_ADDR:=127.0.0.1}"
: "${GOLEM_EVENT_LISTEN_PORT:=8787}"
: "${GOLEM_EVENT_MAX_BODY:=65536}"

# Branch naming: issue N -> "<GOLEM_BRANCH_PREFIX><N>".
: "${GOLEM_BRANCH_PREFIX:=feature/issue-}"

# Autonomy level (1-4) baked into a golem's launch line by golem-launch.sh. A
# per-call `--level M` flag overrides this; absent both, the launcher defaults
# to 4. This env fallback carries the operator's chosen level to callers that
# set it in the environment rather than passing the flag.
: "${GOLEM_LEVEL:=4}"

# Model baked into a golem's launch line (both the next-issue and ship-issue
# `claude` calls). Empty default → no `--model` is emitted, so an unset knob
# leaves the launch line byte-identical to the pre-knob behavior and the golem
# inherits the operator/session default. See golem_model_flag below.
: "${GOLEM_MODEL:=}"

# Ref that new worktree branches are created from.
: "${GOLEM_BASE_REF:=origin/main}"

# Gitignored machine-local files a push from inside a worktree needs.
: "${GOLEM_WORKTREE_LOCAL_FILES:=.env .claude/settings.local.json}"

# Liveness/heartbeat (SOFT, advisory — never auto-kills a golem):
# how long a golem may show no progress before it is flagged a possible stall,
# and the poll interval of the liveness stream.
: "${GOLEM_STALL_THRESHOLD:=1200}"
: "${GOLEM_HEARTBEAT_INTERVAL:=60}"
: "${GOLEM_LIVENESS_SUMMARY_INTERVAL:=900}"

# Orchestrator-brokered gate reverse channel (golem-inbox.sh, #227): the
# per-call ceiling and poll interval of `consume`'s bounded-blocking read. The
# ceiling stays under the Bash tool's 600s per-call limit; the golem re-invokes
# `consume` in a loop on NO-DECISION so the never-time-out rule holds without any
# single call approaching the ceiling.
: "${GOLEM_INBOX_WAIT:=300}"
: "${GOLEM_INBOX_POLL:=3}"

# Mode-drift check (golem-mode-check.sh, #659): the per-golem auto-correct bound
# and the --watch cadence. The attempt bound is the guardrail the issue asks for
# — a golem whose mode will not stick escalates to the operator rather than
# spinning keystrokes forever.
: "${GOLEM_MODE_FIX_ATTEMPTS:=3}"
: "${GOLEM_MODE_CHECK_INTERVAL:=60}"

# Token-cost measurement over the Bifrost gateway (token-report.sh, #781).
# BIFROST_URL deliberately gets NO `:=` default — see its entry in the header
# block above. A guessed default would be a hardcoded hostname (AC5) and the one
# plausible guess (ANTHROPIC_BASE_URL) resolves to the proxy path, which answers
# /api/logs/stats with HTML and HTTP 200. Absence must reach the script as
# absence so it can fail loudly with exit 2.
: "${TOKEN_REPORT_TIMEOUT:=30}"
: "${TOKEN_REPORT_RECONCILE_PCT:=0.5}"

# Session-length bounding (#784) — see the header entries for the derivation.
# context-budget.sh INLINES these same two defaults so it stays runnable
# standalone (it is called directly by skills, not only by scripts that source
# this file); the pair is pinned equivalent by validate-context-budget.sh's drift
# guard, the same arrangement golem-notify.sh's inlined sink defaults use.
: "${CONTEXT_BUDGET_THRESHOLD:=175000}"
: "${CONTEXT_BUDGET_FLOOR:=91000}"

export TOKEN_REPORT_TIMEOUT TOKEN_REPORT_RECONCILE_PCT

export GOLEM_WORKTREE_DIR GOLEM_STATUS_DIR GOLEM_BRANCH_PREFIX GOLEM_LEVEL \
    GOLEM_MODEL GOLEM_BASE_REF GOLEM_WORKTREE_LOCAL_FILES GOLEM_STALL_THRESHOLD \
    GOLEM_HEARTBEAT_INTERVAL GOLEM_LIVENESS_SUMMARY_INTERVAL \
    GOLEM_INBOX_WAIT GOLEM_INBOX_POLL \
    GOLEM_MODE_FIX_ATTEMPTS GOLEM_MODE_CHECK_INTERVAL \
    GOLEM_EVENT_SINKS GOLEM_EVENT_SINK_TIMEOUT \
    GOLEM_EVENT_LISTEN_ADDR GOLEM_EVENT_LISTEN_PORT GOLEM_EVENT_MAX_BODY

# golem_model_flag — print ` --model "<GOLEM_MODEL>"` when GOLEM_MODEL is set,
# else nothing. SINGLE SOURCE OF TRUTH for the model-flag shape: golem-launch.sh
# (both the `print`/launch_line and the `launch` tmux string) and
# worktree-new.sh's echoed launch hint all splice its output in after each
# `claude` token. The leading space means the fragment slots in cleanly after
# `claude` while an UNSET knob expands to the empty string, leaving the launch
# line byte-identical to the pre-knob behavior (no regression — the invariant
# tests/validate-golem-scripts.sh pins).
#
# QUOTING / INJECTION SAFETY: the emitted ` --model "…"` fragment lands inside a
# DOUBLE-QUOTED word in the string that `tmux new-session` hands to `sh -c` (and,
# for `print`/the hint, that an operator pastes into their shell). A raw value
# containing `"`, backtick, `$`, or `\` would break out of that quoting — e.g.
# GOLEM_MODEL='x"; rm -rf ~; echo "' would inject a command into the golem's
# pane at dispatch. So backslash-escape exactly the four characters that are
# special inside a POSIX double-quoted word — backslash FIRST (so the escapes we
# add next are not themselves re-escaped), then `"`, backtick, `$`. This is
# preferred over an allow-list regex because legitimate model ids include
# bracketed forms (e.g. `claude-opus-4-8[1m]`) that a naive allow-list would
# reject, while `[`/`]` are NOT special inside double quotes and pass through
# untouched. `${v//old/new}` pattern substitution is bash-3.2 clean (NOT the
# banned `${v,,}`/`${v^^}` case-conversion — see tests/lint-shell-portability.sh).
# Pure POSIX otherwise (`command printf`, `[ -n ]`, plain function).
golem_model_flag() {
    local esc
    if [ -n "${GOLEM_MODEL:-}" ]; then
        esc=$GOLEM_MODEL
        esc=${esc//\\/\\\\}
        esc=${esc//\"/\\\"}
        esc=${esc//\`/\\\`}
        esc=${esc//\$/\\\$}
        command printf ' --model "%s"' "$esc"
    fi
}

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
# rather than the tainted one. `env` (and git) are PATH-resolved (`env` /
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
