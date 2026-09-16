#!/usr/bin/env bash
# pre-push pure-delete guard (#1054).
#
# `git push origin --delete <branch>` transfers no objects and changes no file,
# but lefthook's `glob:` is computed from `PushFiles()` -- `git diff --name-only
# HEAD @{push}` -- which compares HEAD to its upstream and NEVER looks at the ref
# being pushed. So on a delete the file list is non-empty anyway, the glob
# matches, and `quality-gates` ran the whole ~700s suite to delete a ref.
#
# bin/push-is-pure-delete.sh reads git's ref lines and answers "is every pushed
# ref a deletion". This gate pins both directions, because only one of them is
# the bug and the other is the safety property:
#
#   - a pure delete is DETECTED      (the saving)
#   - anything else is NOT           (the gate still runs -- the safety half)
#
# THE FAIL-CLOSED DIRECTION IS THE ONE THAT MATTERS. A guard that wrongly says
# "pure delete" silently skips the suite on a real push, which is the
# silence-reads-as-a-pass shape this repo keeps filing issues about (#538/#571).
# So every not-a-delete case below is a REQUIRED non-zero, and empty/garbage
# stdin must fail closed too -- refusing to decide means "run the gate", never
# "skip it".
#
# The ref-line format is git's: `<local-ref> <local-sha> <remote-ref>
# <remote-sha>`, and a deletion is the literal `(delete)` plus an all-zero local
# sha. Measured against real git output (2.x) rather than assumed:
#
#   $ git push origin --delete tmpbranch
#   (delete) 0000000000000000000000000000000000000000 refs/heads/tmpbranch 73cc2da...
#
# Pure bash. No network, no git repo needed -- the script's whole input is stdin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO_ROOT/bin/push-is-pure-delete.sh"
LEFTHOOK="$REPO_ROOT/lefthook.yml"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "pre-push pure-delete guard (#1054)"

ZERO40="0000000000000000000000000000000000000000"
ZERO64="0000000000000000000000000000000000000000000000000000000000000000"

# guard_exit <stdin-text> — the guard's exit code, without tripping set -e.
guard_exit() {
    local rc=0
    printf '%s' "$1" | bash "$GUARD" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# --- The saving: a pure delete is detected ----------------------------------

test_single_delete_detected() {
    assert_equals "0" \
        "$(guard_exit "(delete) $ZERO40 refs/heads/feature/issue-786 73cc2da
")" \
        "a single branch deletion is recognized"
}

test_multiple_deletes_detected() {
    assert_equals "0" \
        "$(guard_exit "(delete) $ZERO40 refs/heads/a 73cc2da
(delete) $ZERO40 refs/heads/b 84dd3eb
")" \
        "several deletions in one push are still a pure delete"
}

test_sha256_zero_oid_detected() {
    # A sha256 repo writes a 64-char zero oid. Hardcoding 40 zeros would make
    # the guard silently stop firing there -- no error, just the old ~700s.
    assert_equals "0" \
        "$(guard_exit "(delete) $ZERO64 refs/heads/a 73cc2da
")" \
        "a sha256 (64-char) zero oid is recognized"
}

# --- The safety half: everything else must NOT be treated as a delete -------

test_normal_push_not_a_delete() {
    assert_equals "1" \
        "$(guard_exit "refs/heads/main abc123 refs/heads/main def456
")" \
        "an ordinary push is not a delete (the gate must still run)"
}

test_new_branch_push_not_a_delete() {
    # A brand-new branch has an all-zero REMOTE sha -- the mirror image of a
    # delete. Keying on the wrong field would skip the suite on every first
    # push of a branch, which is exactly when it is most wanted.
    assert_equals "1" \
        "$(guard_exit "refs/heads/newbr abc123 refs/heads/newbr $ZERO40
")" \
        "a first push of a new branch is not a delete"
}

test_mixed_delete_and_push_not_pure() {
    # `git push origin --delete old newbranch` deletes one ref and pushes
    # another in ONE invocation. The pushed content must still be gated.
    assert_equals "1" \
        "$(guard_exit "(delete) $ZERO40 refs/heads/old 73cc2da
refs/heads/new abc123 refs/heads/new def456
")" \
        "a delete alongside a real push is NOT a pure delete"
}

test_zero_sha_without_delete_marker_rejected() {
    # The mirror of the case below, and the one that mutation testing forced:
    # dropping the `(delete)` marker check entirely left every other assertion
    # green, because on REAL git output a zero local sha and the marker always
    # travel together. Only a line carrying one without the other tells the two
    # checks apart -- so both halves need their own negative fixture, or half
    # the predicate is untested.
    assert_equals "1" \
        "$(guard_exit "refs/heads/x $ZERO40 refs/heads/x abc123
")" \
        "a zero local sha WITHOUT the (delete) marker is malformed, not a delete"
}

test_delete_marker_with_nonzero_sha_rejected() {
    assert_equals "1" \
        "$(guard_exit "(delete) abc123 refs/heads/a 73cc2da
")" \
        "a (delete) marker with a non-zero sha is malformed, not a delete"
}

# --- Fails closed -----------------------------------------------------------

test_empty_stdin_fails_closed() {
    # Also the forgot-use_stdin case: stdin is empty rather than wrong, so the
    # cost of the mistake is a needless suite run, never a skipped one.
    assert_equals "1" "$(guard_exit "")" \
        "empty stdin fails closed (run the gate)"
}

test_garbage_stdin_fails_closed() {
    assert_equals "1" "$(guard_exit "not a ref line at all
")" \
        "unparseable stdin fails closed (run the gate)"
}

# --- The wiring, without which the guard is inert ---------------------------

test_lefthook_passes_stdin() {
    # git passes the refs on stdin and NOWHERE else -- not argv, not env. Drop
    # `use_stdin` and the guard reads empty, fails closed, and the suite runs
    # again: the bug returns silently, with every test above still green.
    assert_true "command grep -q 'use_stdin: true' '$LEFTHOOK'" \
        "quality-gates passes stdin through to the guard"
}

test_lefthook_invokes_the_guard() {
    assert_true "command grep -q 'push-is-pure-delete.sh' '$LEFTHOOK'" \
        "quality-gates actually calls the guard"
}

test_guard_is_executable() {
    assert_true "[ -x '$GUARD' ]" "the guard is executable"
}

run_test test_single_delete_detected "a single branch deletion is detected"
run_test test_multiple_deletes_detected "several deletions are a pure delete"
run_test test_sha256_zero_oid_detected "a sha256 zero oid is detected"
run_test test_normal_push_not_a_delete "an ordinary push is not a delete"
run_test test_new_branch_push_not_a_delete "a new-branch push is not a delete"
run_test test_mixed_delete_and_push_not_pure "delete + push together is not pure"
run_test test_zero_sha_without_delete_marker_rejected "a zero sha without (delete) is rejected"
run_test test_delete_marker_with_nonzero_sha_rejected "(delete) with a non-zero sha is rejected"
run_test test_empty_stdin_fails_closed "empty stdin fails closed"
run_test test_garbage_stdin_fails_closed "garbage stdin fails closed"
run_test test_lefthook_passes_stdin "lefthook passes stdin to the guard"
run_test test_lefthook_invokes_the_guard "lefthook invokes the guard"
run_test test_guard_is_executable "the guard is executable"

generate_report
