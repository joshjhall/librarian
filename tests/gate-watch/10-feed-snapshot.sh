# shellcheck shell=bash
# feed_snapshot — golem-gate-watch tests (issue #564 split).
#
# Covers TTL/`.ts` guarding (#24), event-kind precedence, the `golem-?` orphan sentinel (#323), the #446 ghost filter, and the jq-absent silent no-op.
#
# Sourced by tests/golem-gate-watch.sh, which defines GATE_WATCH and sources
# tests/lib/gate-watch-sandbox.sh for the shared drivers BEFORE this file. This
# fragment only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.

# Regression: a legacy line with no `.ts` field must NOT abort the pipeline and
# drop every blocked golem. Both the legacy line and a valid dated gate survive.
# A high TTL keeps the dated gate inside the freshness window regardless of when
# the test runs.
test_legacy_line_does_not_drop_golems() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 999999999999 \
        '{"golem":"golem-1","event":"blocked","message":"legacy block"}' \
        '{"golem":"golem-2","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 even with a no-ts legacy line"
    assert_not_empty "$SNAP_OUT" "Snapshot is non-empty (legacy line must not abort the pipeline)"
    assert_contains "$SNAP_OUT" "golem-1" "Legacy no-ts blocked golem is honored as a gate"
    assert_contains "$SNAP_OUT" "golem-2" "Valid dated gate golem still appears"
}

# Symmetry: the positive TTL branch still works. A gate whose `.ts` IS present
# but is far older than the TTL window must age out (be excluded), while a fresh
# gate in the same feed survives — guarding against a refactor that drops the
# TTL comparison and shows stale gates forever.
test_stale_ts_gate_ages_out() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 60 \
        '{"golem":"golem-old","event":"gate","message":"ancient","ts":"1970-01-01T00:00:00Z"}' \
        '{"golem":"golem-new","event":"blocked","message":"legacy still fresh"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with a stale-ts gate"
    assert_not_empty "$SNAP_OUT" "Snapshot is non-empty (the no-ts golem is still fresh)"
    assert_contains "$SNAP_OUT" "golem-new" "No-ts golem is honored as fresh"
    # assert_not_contains is glob-based (no eval), so attacker-influenceable
    # $SNAP_OUT never reaches an eval'd command.
    assert_not_contains "$SNAP_OUT" "golem-old" "Stale dated gate ages out of the TTL window"
}

# Distinct from the no-`ts` case: a present-but-empty `.ts` ("") is a string, so
# it passes the `(.ts|type)=="string"` guard and is caught only by the `.ts!=""`
# half. Feeding "" to fromdateiso8601 aborts jq exactly like the original bug —
# so this guards against a refactor that collapses the two conditions into one.
test_empty_ts_treated_as_fresh() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 60 \
        '{"golem":"golem-empty","event":"gate","message":"empty ts","ts":""}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with an empty-string ts"
    assert_not_empty "$SNAP_OUT" "Snapshot is non-empty (empty ts must not abort the pipeline)"
    assert_contains "$SNAP_OUT" "golem-empty" "Empty-ts golem is honored as fresh"
}

# Escalation (#176): a mid-flight `escalation` event surfaces in the BLOCKED feed
# set alongside `gate`/`blocked`, is labelled distinctly ("escalation — …") so a
# judgement call is not lost among routine permission gates, while an `idle` in
# the same feed is still excluded. Guards the three-way select and the jq label
# branch together.
test_escalation_surfaces_labelled() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 999999999999 \
        '{"golem":"golem-esc","event":"escalation","message":"ESCALATION: reuse state file or sidecar?","ts":"2026-06-27T10:00:00Z"}' \
        '{"golem":"golem-gate","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}' \
        '{"golem":"golem-idle","event":"idle","message":"Claude is waiting for your input","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with an escalation line"
    assert_contains "$SNAP_OUT" "golem-esc" "Escalation golem surfaces in the BLOCKED set"
    assert_contains "$SNAP_OUT" "escalation — ESCALATION: reuse state file or sidecar?" \
        "Escalation is labelled distinctly (escalation — …)"
    assert_contains "$SNAP_OUT" "golem-gate" "A routine gate still surfaces alongside the escalation"
    # The gate line must NOT carry the escalation label.
    assert_not_contains "$SNAP_OUT" "escalation — push gate" \
        "A routine gate is not mislabelled as an escalation"
    assert_not_contains "$SNAP_OUT" "golem-idle" "An idle in the same feed is still excluded"
}

# Resolve-then-sweep (#422): the compliant plan-approval broker resolves a plan
# gate with `tmux send-keys 1 Enter`, which fires no Notification — so without an
# explicit clearing line the golem's `gate` stays the most-recent feed line and
# renders BLOCKED for the whole TTL. golem-resolve.sh closes this by emitting a
# `resolved` line; like `idle`, `resolved` is NOT in the BLOCKED set, so once it
# is the golem's most-recent line `group_by | map(.[-1])` drops the golem from
# the snapshot. This pins acceptance criterion 3: gate followed by a later
# `resolved` for the same golem ⇒ not BLOCKED, while a still-gated golem in the
# same feed still surfaces (so the clearing is targeted, not a blanket drop).
test_resolved_supersedes_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 999999999999 \
        '{"golem":"golem-5","event":"gate","message":"plan gate","ts":"2026-06-27T10:00:00Z"}' \
        '{"golem":"golem-5","event":"resolved","message":"RESOLVED: plan gate approved via send-keys","ts":"2026-06-27T10:01:00Z"}' \
        '{"golem":"golem-6","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with a resolved line"
    assert_not_contains "$SNAP_OUT" "golem-5" \
        "A gate superseded by a later resolved line drops out of BLOCKED (#422)"
    assert_contains "$SNAP_OUT" "golem-6" \
        "A still-gated golem in the same feed still surfaces (resolve is targeted)"
}

# Orphan sentinel (#323): golem-notify.sh stamps a feed line `golem-?` when the
# Notification fires from a session with no GOLEM_ID that is not in a worktree
# root. No real golem carries that id, so no future `idle` ever supersedes it and
# (being no-`ts`) it bypasses the TTL — a permanent phantom BLOCKED entry. It is
# never actionable (`golem-?` has no golem-attach target), so feed_snapshot()
# must drop it while a REAL gate in the same feed still surfaces. Both branches
# asserted together so a refactor dropping the sentinel filter is caught.
test_golem_question_sentinel_excluded() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 999999999999 \
        '{"golem":"golem-?","event":"gate","message":"Claude needs your permission"}' \
        '{"golem":"golem-1","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with an orphan golem-? line"
    assert_not_empty "$SNAP_OUT" "Snapshot is non-empty (the real gate must still surface)"
    assert_contains "$SNAP_OUT" "golem-1" "A real gate still surfaces alongside the orphan sentinel"
    # assert_not_contains is glob-based (no eval), so attacker-influenceable
    # $SNAP_OUT never reaches an eval'd command.
    assert_not_contains "$SNAP_OUT" "golem-?" "The orphan golem-? sentinel is filtered out"
}

# jq-absent contract (#28): feed_snapshot() guards on `command -v jq ... ||
# return 0`, so with jq off $PATH the `--once` snapshot is a silent no-op —
# exit 0, EMPTY output — EVEN with a fresh gated entry in the feed. This pins
# that documented behavior (a runtime missing jq must not crash the watcher, and
# its silence is indistinguishable from a clean empty feed by design). Unlike
# the sibling tests it does NOT skip when jq is present: it stubs jq OFF the
# script's PATH so the guard fires regardless of the host. Skips only when the
# host bash cannot be resolved (the stub needs a real bash to symlink).
test_jq_absent_is_silent_noop() {
    if ! command -v bash >/dev/null 2>&1; then
        skip_test "bash not resolvable on PATH (cannot build a jq-free stub PATH)"
        return 0
    fi

    # A fresh, valid, dated gate that WOULD appear if jq were present.
    _run_once_snapshot_no_jq 999999999999 \
        '{"golem":"golem-7","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 when jq is absent"
    assert_output_empty "$SNAP_OUT" "Snapshot emits nothing when jq is absent, even with a fresh gate"
}
