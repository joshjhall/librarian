# shellcheck shell=bash
# Fragment sourcing + wiring guard for the split test suites (issue #564).
#
# When a 5,787-line suite is broken into per-area fragments, the new failure mode
# is a SILENT DROP: a fragment nobody sources contributes zero tests, and the
# suite still reports green with a smaller total that nobody notices. That is
# strictly worse than the monolith it replaced, where a case could only vanish by
# being deleted in a visible diff.
#
# So each entry point declares an EXPLICIT ordered fragment list rather than
# globbing. Two reasons the list cannot simply be `for f in dir/*.sh`:
#
#   1. run_test dispatch order is NOT fragment order, and in this corpus it is
#      not even definition order (verified: they differ in five places). The
#      entry point owns the order.
#   2. An explicit list is a reviewable artifact — adding a file is not enough,
#      you must say where it runs.
#
# source_fragments() then closes the drop hole in BOTH directions by comparing
# the declared list against what is actually on disk: a fragment nobody listed
# fails the suite, and so does a listed fragment that was deleted or renamed.
# Same fail-loud posture as lint-shell-portability.sh's test_corpus_non_empty —
# a gate that silently inspects less than it should is worse than no gate.
#
# Usage, from an entry point that has already sourced tests/lib/harness.sh:
#
#     FRAGMENTS="10-launch.sh 20-worktree-new.sh"
#     source_fragments "$SCRIPT_DIR/golem-scripts" $FRAGMENTS
#
# It sources each fragment in the given order, then registers a run_test-driven
# guard. Sourcing is fail-loud: a missing or unreadable fragment aborts
# immediately rather than letting the suite run with a hole in it.
#
# Pure bash-3.2 + coreutils. `command`-prefixed tool calls per #443.

# source_fragments <dir> <file>...
# Source each named fragment from <dir>, in order, then assert the named set
# equals the *.sh files present in <dir>.
source_fragments() {
    local dir="$1"
    shift
    local f

    if [ ! -d "$dir" ]; then
        command printf 'FATAL: fragment directory not found: %s\n' "$dir" >&2
        exit 1
    fi
    if [ "$#" -eq 0 ]; then
        command printf 'FATAL: no fragments declared for %s\n' "$dir" >&2
        exit 1
    fi

    for f in "$@"; do
        if [ ! -f "$dir/$f" ]; then
            command printf 'FATAL: declared fragment is missing: %s\n' "$dir/$f" >&2
            exit 1
        fi
        # shellcheck source=/dev/null  # path is composed at runtime from the caller's list
        source "$dir/$f"
        # Record which fragment defines each test function, so a failure can name
        # the FILE to open (AC#3 of #564). The suite's run_test descriptions say
        # what broke but not where it lives, and with ~30 fragments "which file
        # is test_status_checkpoint_lane_boundary_padding in?" is a real lookup.
        # Newline-delimited `name<TAB>file` pairs; see fragment_of().
        _FRAG_OWNERS="${_FRAG_OWNERS:-}$(
            command grep -oE '^test_[a-z_0-9]+\(\)' "$dir/$f" 2>/dev/null |
                command sed "s/()\$/	$f/"
        )
"
    done

    # Stash the comparison inputs for the guard test below. Newline-delimited and
    # sorted so the comparison is order-insensitive (the DECLARED order is the
    # dispatch order and is deliberately not alphabetical).
    _FRAG_DIR="$dir"
    _FRAG_DECLARED="$(
        for f in "$@"; do command printf '%s\n' "$f"; done | command sort
    )"
    _FRAG_ON_DISK="$(
        command find "$dir" -maxdepth 1 -type f -name '*.sh' 2>/dev/null |
            command sed 's|.*/||' | command sort
    )"

    run_test test_fragments_all_wired \
        "fragment wiring: every ${dir##*/}/*.sh is sourced, and every sourced file exists (#564)"
}

# fragment_of <test-function-name>
# Print the fragment file that defines <test-function-name>, or empty if unknown.
# Used by run_fragment_test below and available to a suite that wants to annotate
# its own output.
fragment_of() {
    command printf '%s' "${_FRAG_OWNERS:-}" |
        command grep -F "$1	" |
        command head -n1 |
        command cut -f2
}

# run_fragment_test <test-function> <description>
# A run_test wrapper that appends the defining fragment to the description, so a
# failure line reads `… [40-worktree-rm.sh] ... FAIL` and names the file to open.
# Falls back to plain run_test when the owner is unknown (a test defined by the
# entry point itself, e.g. the git-availability prerequisite).
run_fragment_test() {
    local fn="$1" desc="${2:-$1}" owner
    owner="$(fragment_of "$fn")"
    if [ -n "$owner" ]; then
        run_test "$fn" "$desc  [$owner]"
    else
        run_test "$fn" "$desc"
    fi
}

# Guard body. Compares the two sorted lists captured above and reports the exact
# offenders in each direction, so the failure names the file rather than only the
# counts.
test_fragments_all_wired() {
    local unwired wired_but_absent

    # On disk but not declared — the silent-drop case.
    unwired="$(
        command comm -13 <(command printf '%s\n' "$_FRAG_DECLARED") \
            <(command printf '%s\n' "$_FRAG_ON_DISK")
    )"
    # Declared but not on disk — a rename/delete the list did not follow. The
    # source loop above already aborts on this, so reaching here means the file
    # vanished mid-run; assert it anyway so the invariant is stated, not implied.
    wired_but_absent="$(
        command comm -23 <(command printf '%s\n' "$_FRAG_DECLARED") \
            <(command printf '%s\n' "$_FRAG_ON_DISK")
    )"

    assert_equals "" "$unwired" \
        "Every *.sh in ${_FRAG_DIR##*/}/ must be in the entry point's fragment list (unwired fragments contribute ZERO tests silently)"
    assert_equals "" "$wired_but_absent" \
        "Every fragment in the entry point's list must exist in ${_FRAG_DIR##*/}/"
    # Non-vacuity: a bug that blanked BOTH lists would satisfy the two assertions
    # above while checking nothing. Pin that the corpus is real.
    assert_not_empty "$_FRAG_ON_DISK" \
        "The fragment directory ${_FRAG_DIR##*/}/ must contain at least one *.sh (guard is not a no-op)"
}
