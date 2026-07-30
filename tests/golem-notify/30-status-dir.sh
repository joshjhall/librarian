# shellcheck shell=bash
# Status-dir resolution — golem-notify hook tests (issue #564 split).
#
# Covers the GOLEM_STATUS_DIR / GOLEM_WORKTREE_DIR overrides (#405) and the drift guard pinning the hook's inlined defaults to config.sh (#424).
#
# Sourced by tests/validate-golem-notify.sh, which defines NOTIFY / CONFIG_SH /
# REAL_BASH and sources tests/lib/golem-notify-sandbox.sh for the shared drivers
# BEFORE this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_test list.

# Local to this area: only the status-dir tests drive the GOLEM_WORKTREE_DIR
# override, so it stays here rather than in the shared library.
# run_notify_worktree_dir <sandbox> <payload> <golem_id> <worktree_override>
# Like run_notify_status_dir, but exports ONLY GOLEM_WORKTREE_DIR (leaving
# GOLEM_STATUS_DIR unset after the GOLEM_SCRUB) so the hook's SECOND `:=` composes
# the status dir from the worktree dir: `${GOLEM_WORKTREE_DIR}/.status`. Reads the
# feed back at the COMPOSED path <sandbox>/<worktree_override>/.status/feed.jsonl,
# exercising the branch neither the both-unset default nor the
# GOLEM_STATUS_DIR-set-directly override reaches (#424).
run_notify_worktree_dir() {
    local dir="$1" payload="$2" gid="$3" wt="$4"
    local feed="$dir/$wt/.status/feed.jsonl"
    command rm -f "$feed"
    NOTIFY_RC=0
    (
        cd "$dir" &&
            command printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" \
                HOME="$dir" GOLEM_ID="$gid" GOLEM_WORKTREE_DIR="$wt" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_LINE="$(command tail -n 1 "$feed" 2>/dev/null || true)"
}

# --- Status-dir resolution (GOLEM_STATUS_DIR override, #405) -----------------

# The emitter must resolve its feed path the same env-overridable way the reader
# scripts (golem-status.sh / golem-gate-watch.sh / golem-inbox.sh) do, so a
# GOLEM_STATUS_DIR override moves BOTH together. Before #405 the hook hardcoded
# .worktrees/.status, so an override silently split the feed path — gates written
# by the emitter would never surface to readers watching the override path.

# An override moves the emitter: the feed lands under the override dir, is valid
# JSON, and the legacy .worktrees/.status path is NOT written (proving the
# override MOVED the sink, not merely added a second one).
test_status_dir_override_honored() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_notify_status_dir "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "custom-status"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (GOLEM_STATUS_DIR override)"
    assert_valid_json "$NOTIFY_LINE" \
        "feed line under override dir is valid JSON"
    assert_true "[ -f '$sb/custom-status/feed.jsonl' ]" \
        "feed written under GOLEM_STATUS_DIR override (custom-status/feed.jsonl)"
    assert_true "[ ! -e '$sb/.worktrees/.status/feed.jsonl' ]" \
        "legacy .worktrees/.status/feed.jsonl NOT written — override moved the sink"
}

# With GOLEM_STATUS_DIR unset, the resolution is byte-for-byte unchanged: the
# feed still lands at .worktrees/.status. new_sandbox + run_notify (which do NOT
# set GOLEM_STATUS_DIR) already exercise the default path; this pins the
# acceptance criterion explicitly, guarding against a future default drift.
test_status_dir_default_unchanged() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_notify "$sb" \
        '{"message":"Claude needs your permission to run git push"}' "golem-1"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (GOLEM_STATUS_DIR unset)"
    assert_valid_json "$NOTIFY_LINE" "default-path feed line is valid JSON"
    assert_true "[ -f '$sb/.worktrees/.status/feed.jsonl' ]" \
        "GOLEM_STATUS_DIR unset still lands at .worktrees/.status (unchanged)"
}

# The COMPOSED-default branch: GOLEM_WORKTREE_DIR overridden while GOLEM_STATUS_DIR
# stays unset, so the hook's second `:=` expands `${GOLEM_WORKTREE_DIR}/.status`.
# Neither the both-unset default (test_status_dir_default_unchanged) nor the
# GOLEM_STATUS_DIR-set-directly override (test_status_dir_override_honored)
# exercises this composition. A regression that hardcoded `.status` under the repo
# root, or reordered the two `:=` lines, would pass the whole rest of the suite
# but fail here — the feed would NOT land at <override>/.status (#424, finding 2).
test_status_dir_composed_from_worktree_dir() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_notify_worktree_dir "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "custom-wt"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (GOLEM_WORKTREE_DIR-only override)"
    assert_valid_json "$NOTIFY_LINE" "composed-default feed line is valid JSON"
    assert_true "[ -f '$sb/custom-wt/.status/feed.jsonl' ]" \
        "GOLEM_STATUS_DIR unset composes feed under <GOLEM_WORKTREE_DIR>/.status"
    assert_true "[ ! -e '$sb/.worktrees/.status/feed.jsonl' ]" \
        "legacy .worktrees/.status NOT written — composition moved the sink"
}

# --- Drift guard: hook inlined defaults vs config.sh (#424, finding 1) -------

# The hook INLINES config.sh's GOLEM_WORKTREE_DIR / GOLEM_STATUS_DIR default chain
# verbatim (deliberately not sourced — sourcing config.sh would pull in its
# repo_root()/superproject probe and change the hook's own git-common-dir root
# resolution). Nothing else pins the two together: if config.sh's defaults change
# without a matching hook edit, emitter and readers silently split the feed path
# again — exactly the class #405 fixed, CI green throughout. This gate converts the
# hook's "lines 66,70" prose comment into an enforced invariant.
#
# It is an EQUIVALENCE assertion — the path the hook actually lands its feed at
# (both vars unset) must equal config.sh's own resolved GOLEM_STATUS_DIR default —
# so a drift introduced on EITHER side fails it, not just a config.sh change. The
# config.sh defaults are read in a GOLEM_SCRUB'd subshell so this worktree's own
# exported GOLEM_STATUS_DIR cannot leak in and mask a real divergence.
test_defaults_match_config_sh() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local cfg_wt cfg_status
    cfg_wt="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        '. "$1"; printf "%s" "$GOLEM_WORKTREE_DIR"' _ "$CONFIG_SH" 2>/dev/null || true)"
    cfg_status="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        '. "$1"; printf "%s" "$GOLEM_STATUS_DIR"' _ "$CONFIG_SH" 2>/dev/null || true)"
    assert_equals ".worktrees" "$cfg_wt" \
        "config.sh resolves GOLEM_WORKTREE_DIR default to .worktrees"
    assert_equals ".worktrees/.status" "$cfg_status" \
        "config.sh resolves GOLEM_STATUS_DIR default to .worktrees/.status"

    # The hook, both vars unset, must land its feed at exactly config.sh's
    # resolved GOLEM_STATUS_DIR default (relative to the repo root).
    local sb
    new_sandbox sb
    run_notify "$sb" \
        '{"message":"Claude needs your permission to run git push"}' "golem-1"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (drift-guard default path)"
    assert_true "[ -f '$sb/$cfg_status/feed.jsonl' ]" \
        "hook feed lands at config.sh's resolved GOLEM_STATUS_DIR default — no drift"
}

# Sibling drift guard for the #406 sink vars. golem-notify.sh INLINES config.sh's
# GOLEM_EVENT_SINKS / GOLEM_EVENT_SINK_TIMEOUT defaults (not sourced, same reason
# as above), and both files' comments claim this test pins the two equivalent.
# That claim must be TRUE: assert the value each side resolves with both vars
# unset is identical. config.sh is read in a GOLEM_SCRUB'd subshell (so this
# worktree's own exported values can't leak in); the hook's inlined defaults are
# read by sourcing ONLY its two `: "${GOLEM_EVENT_SINK*:=...}"` assignment lines
# in a scrubbed subshell — the same isolation the config.sh side uses, and enough
# to catch a one-sided default edit (e.g. bumping the timeout in config.sh but
# not the hook) that would otherwise stay green.
test_event_sink_defaults_match_config_sh() {
    local cfg_sinks cfg_timeout hook_sinks hook_timeout
    # config.sh side.
    cfg_sinks="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        '. "$1"; printf "%s" "$GOLEM_EVENT_SINKS"' _ "$CONFIG_SH" 2>/dev/null || true)"
    cfg_timeout="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        '. "$1"; printf "%s" "$GOLEM_EVENT_SINK_TIMEOUT"' _ "$CONFIG_SH" 2>/dev/null || true)"
    # Hook side: eval ONLY the two inlined sink-default lines (grep them out so we
    # do not run the whole hook), then print what they resolve to.
    local hook_defaults
    hook_defaults="$(command grep -E '^: "\$\{GOLEM_EVENT_SINK(S|_TIMEOUT):=' "$NOTIFY" || true)"
    hook_sinks="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        "$hook_defaults"'; printf "%s" "$GOLEM_EVENT_SINKS"' 2>/dev/null || true)"
    hook_timeout="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        "$hook_defaults"'; printf "%s" "$GOLEM_EVENT_SINK_TIMEOUT"' 2>/dev/null || true)"
    # Known defaults (guards against BOTH sides drifting together to a new value).
    assert_equals "" "$cfg_sinks" "config.sh GOLEM_EVENT_SINKS default is empty"
    assert_equals "2" "$cfg_timeout" "config.sh GOLEM_EVENT_SINK_TIMEOUT default is 2"
    # Equivalence: hook inlined defaults must match config.sh's (the drift guard).
    assert_equals "$cfg_sinks" "$hook_sinks" \
        "hook GOLEM_EVENT_SINKS default matches config.sh — no drift (#406)"
    assert_equals "$cfg_timeout" "$hook_timeout" \
        "hook GOLEM_EVENT_SINK_TIMEOUT default matches config.sh — no drift (#406)"
}
