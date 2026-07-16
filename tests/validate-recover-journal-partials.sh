#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/recover-journal-partials.sh (issue #224).
#
# The script recovers finding-shaped results from a stopped fan-out review
# harness's journal — the defined replacement for the "had to be recovered by
# hand" step the issue describes. A silent regression here (an extraction that
# stops finding wrapped findings, an exit code the caller keys its
# manual-recovery fallback on, an abort on the truncated final line every killed
# run leaves) would ship unnoticed, so this gate pins the deterministic paths:
#   - fingerprint extraction of both bare and envelope-wrapped findings,
#   - skipping non-finding records and malformed/truncated lines,
#   - the fail-loud exit codes (usage / missing journal / jq absent).
#
# Pure bash + coreutils + jq, reached via the `command` builtin. jq-dependent
# cases skip cleanly when jq is absent (matching the golem preflight gates).
# Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RECOVER="$REPO_ROOT/plugins/workflow/scripts/recover-journal-partials.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "recover-journal-partials.sh (#224)"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
    HAVE_JQ=1
fi

# Build a representative journal once: an envelope record wrapping two findings
# (blocking + deferrable), a non-finding status record, a bare top-level finding,
# and a truncated final line (a run killed mid-write leaves exactly this).
JOURNAL="$WORKDIR/journal.jsonl"
{
    command printf '%s\n' '{"agent":"review:security","result":{"blocking":[{"severity":"high","file":"a.js","line_start":10,"line_end":12,"category":"security","title":"Injection"}],"deferrable":[{"severity":"low","file":"b.js","line_start":3,"line_end":3,"category":"style","title":"Nit"}]}}'
    command printf '%s\n' '{"event":"phase","name":"Review","note":"budget low"}'
    command printf '%s\n' '{"severity":"critical","file":"c.js","line_start":1,"line_end":9,"category":"correctness","title":"NPE"}'
    # Near-miss #1: line_start present but a STRING, not a number (wrong type).
    command printf '%s\n' '{"severity":"high","file":"typed.js","line_start":"7","category":"security","title":"WrongType"}'
    # Near-miss #2: missing the `category` key entirely (incomplete fingerprint).
    command printf '%s\n' '{"severity":"low","file":"nocat.js","line_start":2,"title":"NoCategory"}'
    command printf '%s' '{"severity":"high","file":"trunc.js","line_start":5,"cate'
} >"$JOURNAL"

# --- Extraction -------------------------------------------------------------

test_recovers_all_findings() {
    [ "$HAVE_JQ" -eq 1 ] || {
        skip_test "jq not available"
        return 0
    }
    local out count
    out="$("$RECOVER" "$JOURNAL")"
    count="$(command printf '%s' "$out" | jq 'length')"
    # Two from the envelope + one bare top-level = 3; the status record and the
    # truncated line contribute nothing.
    assert_equals "3" "$count" "recovers exactly the three well-formed findings"
    assert_contains "$out" "Injection" "recovers the wrapped blocking finding"
    assert_contains "$out" "Nit" "recovers the wrapped deferrable finding"
    assert_contains "$out" "NPE" "recovers the bare top-level finding"
}

test_skips_nonfinding_and_truncated() {
    [ "$HAVE_JQ" -eq 1 ] || {
        skip_test "jq not available"
        return 0
    }
    local out
    out="$("$RECOVER" "$JOURNAL")"
    # The status record's fields and the truncated line's file must not appear.
    assert_not_contains "$out" "budget low" "does not emit the non-finding status record"
    assert_not_contains "$out" "trunc.js" "does not emit the truncated final line"
}

test_rejects_fingerprint_near_misses() {
    [ "$HAVE_JQ" -eq 1 ] || {
        skip_test "jq not available"
        return 0
    }
    local out
    out="$("$RECOVER" "$JOURNAL")"
    # A wrong-typed line_start (string, not number) fails the type check; a record
    # missing `category` fails the completeness check. Neither is finding-shaped,
    # so the extractor must drop both — the fingerprint is type-AND-completeness,
    # not just "has a title".
    assert_not_contains "$out" "typed.js" "rejects a finding whose line_start is a string, not a number"
    assert_not_contains "$out" "nocat.js" "rejects a record missing the category key"
}

test_empty_journal_yields_empty_array() {
    [ "$HAVE_JQ" -eq 1 ] || {
        skip_test "jq not available"
        return 0
    }
    local empty out rc
    empty="$WORKDIR/empty.jsonl"
    : >"$empty"
    out="$("$RECOVER" "$empty")"
    rc=$?
    assert_exit "0" "$rc" "an empty journal is a clean read, not an error"
    assert_equals "0" "$(command printf '%s' "$out" | jq 'length')" "empty journal -> empty array"
}

# --- Fail-loud exit codes ---------------------------------------------------

test_usage_error_no_args() {
    local rc=0
    "$RECOVER" >/dev/null 2>&1 || rc=$?
    assert_exit "1" "$rc" "no argument exits 1 (usage)"
}

test_missing_journal() {
    local rc=0
    "$RECOVER" "$WORKDIR/does-not-exist.jsonl" >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing/unreadable journal exits 2"
}

test_missing_journal_message_to_stderr() {
    local err
    err="$("$RECOVER" "$WORKDIR/does-not-exist.jsonl" 2>&1 >/dev/null || true)"
    assert_contains "$err" "not found or unreadable" "missing journal fails loud on stderr"
}

test_jq_absent_fails_loud() {
    # Drive the jq-guard by running the script under a PATH that holds the tools
    # it calls before that guard (only `cat`, for usage) but NOT jq. BASH_ENV
    # must be unset for the child: /etc/bash_env re-seeds $PATH on non-interactive
    # bash, which would silently restore the real jq and defeat the isolation
    # (the devcontainer-bash-env-path-reset gotcha).
    local realbash empty rc=0
    realbash="$(command -v bash)"
    empty="$WORKDIR/nojq-bin"
    command mkdir -p "$empty"
    if command -v cat >/dev/null 2>&1; then
        command ln -sf "$(command -v cat)" "$empty/cat"
    fi
    env -u BASH_ENV PATH="$empty" "$realbash" "$RECOVER" "$JOURNAL" >/dev/null 2>&1 || rc=$?
    assert_exit "3" "$rc" "jq absent exits 3 (cannot parse)"
}

run_test test_recovers_all_findings "recovers wrapped + bare findings"
run_test test_skips_nonfinding_and_truncated "skips non-finding + truncated records"
run_test test_rejects_fingerprint_near_misses "rejects wrong-typed + incomplete near-misses"
run_test test_empty_journal_yields_empty_array "empty journal -> empty array, exit 0"
run_test test_usage_error_no_args "no args -> exit 1"
run_test test_missing_journal "missing journal -> exit 2"
run_test test_missing_journal_message_to_stderr "missing journal message on stderr"
run_test test_jq_absent_fails_loud "jq absent -> exit 3"

generate_report
