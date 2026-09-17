#!/usr/bin/env bash
# Behavior of bin/fetch-corpora.sh (#1075) — against a LOCAL repo, no network.
#
# WHY THIS IS A SEPARATE GATE FROM lint-measurement-citations.sh. That one checks
# a PROPERTY of the committed files (every published measurement cites a manifest
# SHA); this one checks that the fetch script actually does what the property
# assumes. The split mirrors lint-apt-hardening.sh / validate-apt-install.sh and
# exists for the same reason: a single gate that both constructed the behavior
# and asserted the property would pass on a tree where the script had been
# emptied.
#
# WHY IT DOES NOT TOUCH THE NETWORK. #1075 AC8 — `just test` and the pre-push
# hook must never fetch. The suite already runs ~6 min sharded; adding network
# I/O to it is its own regression, and a gate that fails on a flaky DNS lookup
# gets disabled, after which it catches nothing. So every case below builds a
# real git repository in a sandbox and points the script at it with a
# file:// URL. The fetch path, the SHA verification, the idempotence check and
# the unreachable-pin branch are all exercised for real — just against a remote
# that cannot go down.
#
# THE CASE THAT MATTERS MOST is test_wrong_sha_is_rejected. #1075 AC4 says
# "verify the checkout, never trust the fetch", because a fetch that silently
# landed on a branch tip looks EXACTLY like success: same exit 0, same
# directory, same files. The only way to know the verification is real is to
# construct that situation and assert the script refuses it — which needs a
# manifest pinning a SHA the fetch will not land on, and is why these fixtures
# build their own manifests rather than reusing the committed one.
#
# Pure bash + coreutils + git. bash-3.2 clean, BSD clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

FETCHER="$REPO_ROOT/bin/fetch-corpora.sh"

# git is not optional for this suite — it IS the subject. Absent, exit the
# reserved sentinel 77 so run-all.sh renders `[SKIP] ... did not run` rather
# than a green [ok] (#538/#571).
#
# Note this 77 is about a missing RUNTIME, not about missing corpora. The gate
# must never skip because no corpus is materialized: it needs none, and keying
# it on one would make it inert — see lint-measurement-citations.sh's header.
if ! command -v git >/dev/null 2>&1; then
    command printf 'validate-fetch-corpora: git not found — not enforcing.\n' >&2
    exit 77
fi

test_suite "fetch-corpora behavior (#1075)"

SANDBOX="$(command mktemp -d)" || {
    command printf 'validate-fetch-corpora: mktemp failed — not enforcing.\n' >&2
    exit 77
}
cleanup() { [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && command rm -rf "$SANDBOX"; }
trap cleanup EXIT

# --- the local "upstream" ---------------------------------------------------
# A real repository with two commits, so a pin can name a NON-TIP commit — which
# is the interesting case. Pinning the tip would let a script that ignored the
# SHA entirely still pass every assertion here.
UPSTREAM="$SANDBOX/upstream"
command mkdir -p "$UPSTREAM"

# Scrub ambient git config so a developer's global hooks/templates/signing
# cannot change what these fixtures build. `-u<VAR>` attached, never
# `env --unset=VAR`: BSD env has no long options and reads it as `-u` with the
# operand `nset=VAR`, dying with `env: unsetenv nset=VAR: Invalid argument`
# (CLAUDE.md § Runtime policy).
git_q() {
    command env -uGIT_DIR -uGIT_WORK_TREE -uGIT_INDEX_FILE \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
        git "$@"
}

build_upstream() {
    git_q -C "$UPSTREAM" init -q 2>/dev/null || return 1
    command printf 'first\n' >"$UPSTREAM/a.txt"
    git_q -C "$UPSTREAM" add a.txt >/dev/null 2>&1 || return 1
    git_q -C "$UPSTREAM" commit -q -m first >/dev/null 2>&1 || return 1
    FIRST_SHA="$(git_q -C "$UPSTREAM" rev-parse HEAD 2>/dev/null)" || return 1

    command printf 'second\n' >"$UPSTREAM/b.txt"
    git_q -C "$UPSTREAM" add b.txt >/dev/null 2>&1 || return 1
    git_q -C "$UPSTREAM" commit -q -m second >/dev/null 2>&1 || return 1
    TIP_SHA="$(git_q -C "$UPSTREAM" rev-parse HEAD 2>/dev/null)" || return 1

    # Serving an arbitrary (non-tip) SHA over file:// needs this, exactly as a
    # self-hosted mirror would. Setting it here is what makes the local fixture
    # a faithful stand-in for GitHub rather than a weaker one.
    git_q -C "$UPSTREAM" config uploadpack.allowAnySHA1InWant true >/dev/null 2>&1 || return 1
    git_q -C "$UPSTREAM" config uploadpack.allowReachableSHA1InWant true >/dev/null 2>&1 || return 1
    return 0
}

FIRST_SHA=""
TIP_SHA=""
build_upstream || {
    command printf 'validate-fetch-corpora: could not build the local fixture repo — not enforcing.\n' >&2
    exit 77
}

# write_manifest <path> <name> <sha> — a one-entry manifest pointing at the
# local upstream.
write_manifest() {
    command printf '# fixture\n%s\tfile://%s\t%s\tMIT\ttag:none\tfixture\n' \
        "$2" "$UPSTREAM" "$3" >"$1"
}

# run_fetch <manifest> <dir> [args...] — run the script, capture output+status.
# Output goes to a FILE and is read back, so the caller never holds a pipe the
# subject's descendants could keep open.
RUN_OUT=""
RUN_RC=0
run_fetch() {
    local mf="$1" dir="$2"
    shift 2
    local log="$SANDBOX/run.log"
    command env CORPORA_MANIFEST="$mf" CORPORA_DIR="$dir" \
        bash "$FETCHER" "$@" >"$log" 2>&1
    RUN_RC=$?
    RUN_OUT="$(command cat "$log" 2>/dev/null)"
}

# --- cases ------------------------------------------------------------------

test_fixture_is_non_vacuous() {
    # The guard that keeps every case below meaningful. If the fixture repo did
    # not build, or the two commits were the same object, the "non-tip pin"
    # cases would silently degrade into tip cases and pass for the wrong reason.
    assert_not_empty "$FIRST_SHA" "Fixture must have a first commit"
    assert_not_empty "$TIP_SHA" "Fixture must have a tip commit"
    assert_true "[ \"$FIRST_SHA\" != \"$TIP_SHA\" ]" \
        "The pinned commit must NOT be the tip, or the SHA check is untested"
}

test_fetches_and_verifies_pinned_sha() {
    local mf="$SANDBOX/m1" dir="$SANDBOX/c1"
    write_manifest "$mf" alpha "$FIRST_SHA"
    run_fetch "$mf" "$dir" alpha
    assert_exit 0 "$RUN_RC" "A reachable pin must fetch successfully"
    assert_contains "$RUN_OUT" "verified" "Success must report the verification, not just the fetch"

    local head
    head="$(git_q -C "$dir/alpha" rev-parse HEAD 2>/dev/null)"
    assert_equals "$FIRST_SHA" "$head" \
        "HEAD must be EXACTLY the manifest SHA — a non-tip commit, not the branch tip"
}

test_wrong_sha_is_rejected() {
    # AC4, the load-bearing case. A manifest pinning a well-formed SHA that this
    # repo does not contain must NOT leave a materialized tree behind: a
    # directory that exists but sits at the wrong commit is precisely the state
    # a later measurement would read as the pin.
    local mf="$SANDBOX/m2" dir="$SANDBOX/c2"
    write_manifest "$mf" alpha "0123456789012345678901234567890123456789"
    run_fetch "$mf" "$dir" alpha
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "An unreachable pin must fail, never exit 0"
    assert_contains "$RUN_OUT" "PIN UNREACHABLE" \
        "The error must name the unreachable pin, not report a generic clone failure"
    assert_contains "$RUN_OUT" "0123456789012345678901234567890123456789" \
        "The error must say WHICH SHA died"
    assert_contains "$RUN_OUT" "do NOT re-pin to a branch tip" \
        "The error must steer away from the fix that silently discards the pin"
}

test_short_sha_in_manifest_is_rejected() {
    local mf="$SANDBOX/m3" dir="$SANDBOX/c3"
    write_manifest "$mf" alpha "${FIRST_SHA:0:7}"
    run_fetch "$mf" "$dir" alpha
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "An abbreviated SHA must be refused, not resolved"
    assert_contains "$RUN_OUT" "not a full 40-char" \
        "The refusal must say why an abbreviation is not acceptable"
}

test_is_idempotent() {
    local mf="$SANDBOX/m4" dir="$SANDBOX/c4"
    write_manifest "$mf" alpha "$FIRST_SHA"
    run_fetch "$mf" "$dir" alpha
    assert_exit 0 "$RUN_RC" "First run must succeed"

    run_fetch "$mf" "$dir" alpha
    assert_exit 0 "$RUN_RC" "Re-running with everything present must succeed"
    assert_contains "$RUN_OUT" "already at pin" \
        "A second run must be a no-op, and must say so"
    assert_not_contains "$RUN_OUT" "fetch    file://" \
        "A second run must not re-fetch"
}

test_repairs_a_tree_left_at_the_wrong_commit() {
    # Idempotence must be decided by the SHA, not by directory existence. A tree
    # left at the wrong commit by an interrupted fetch must be REPAIRED, not
    # reported as present — otherwise a measurement runs against an unpinned
    # tree while everything claims the pin.
    local mf="$SANDBOX/m5" dir="$SANDBOX/c5"
    write_manifest "$mf" alpha "$FIRST_SHA"
    run_fetch "$mf" "$dir" alpha
    assert_exit 0 "$RUN_RC" "Setup fetch must succeed"

    git_q -C "$dir/alpha" fetch -q --depth 1 origin "$TIP_SHA" >/dev/null 2>&1
    git_q -C "$dir/alpha" checkout -q FETCH_HEAD >/dev/null 2>&1
    local moved
    moved="$(git_q -C "$dir/alpha" rev-parse HEAD 2>/dev/null)"
    assert_equals "$TIP_SHA" "$moved" "Setup: the tree must really be at the wrong commit"

    run_fetch "$mf" "$dir" alpha
    assert_exit 0 "$RUN_RC" "A wrongly-positioned tree must be repaired, not failed"
    local head
    head="$(git_q -C "$dir/alpha" rev-parse HEAD 2>/dev/null)"
    assert_equals "$FIRST_SHA" "$head" "The repair must restore the pinned SHA"
}

test_corpus_name_is_validated_at_the_boundary() {
    # A corpus name becomes a PATH COMPONENT ("$root/$name"), so `..` would
    # escape the corpora dir, and a name carrying shell metacharacters would
    # depend on every downstream expansion staying quoted to stay inert. Both
    # hold today; neither should be what stands between a CLI argument and the
    # filesystem. Rejecting the shape at the boundary is the property — asserted
    # here so a later refactor cannot quietly drop it.
    local mf="$SANDBOX/m-name" dir="$SANDBOX/c-name"
    write_manifest "$mf" alpha "$FIRST_SHA"

    run_fetch "$mf" "$dir" '../escape'
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "A path-traversing name must be refused"
    assert_contains "$RUN_OUT" "invalid corpus name" "The refusal must name the problem"

    run_fetch "$mf" "$dir" 'foo;bar'
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "A name with shell metacharacters must be refused"
    assert_contains "$RUN_OUT" "invalid corpus name" "The refusal must name the problem"

    # The control: a legitimate name must still be accepted, or this check would
    # pass by rejecting everything.
    run_fetch "$mf" "$dir" alpha
    assert_exit 0 "$RUN_RC" "A valid name must still be accepted"
}

test_empty_manifest_fails_loudly() {
    # A manifest of nothing but comments must not "succeed at fetching nothing".
    # Exit 0 over an empty corpus is the vacuous-scan shape (#934): every
    # downstream check then reports clean, having looked at nothing.
    local mf="$SANDBOX/m-empty" dir="$SANDBOX/c-empty"
    command printf '# comments only\n\n' >"$mf"
    run_fetch "$mf" "$dir"
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "An entryless manifest must fail, never exit 0"
    assert_contains "$RUN_OUT" "no entries" "The failure must say the manifest is empty"
}

test_missing_manifest_fails_loudly() {
    local dir="$SANDBOX/c-nomf"
    run_fetch "$SANDBOX/does-not-exist" "$dir" --list
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "A missing manifest must fail loudly"
    assert_contains "$RUN_OUT" "manifest not found" "The failure must name the missing path"
}

test_unknown_corpus_name_is_an_error() {
    local mf="$SANDBOX/m6" dir="$SANDBOX/c6"
    write_manifest "$mf" alpha "$FIRST_SHA"
    run_fetch "$mf" "$dir" nosuchcorpus
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "An unknown corpus name must fail"
    assert_contains "$RUN_OUT" "unknown corpus" "The error must name the problem"
}

test_tmp_fallback_when_cache_unwritable() {
    # AC2's bare-host path. With CORPORA_DIR unset and /cache/corpora
    # unwritable, the script must land on /tmp/corpora rather than failing —
    # that is what makes it work on a Mac with no container.
    #
    # The default is probed by pointing HOME-independent state at an unwritable
    # primary. /proc is unwritable on every Linux host and absent on macOS, so
    # the case skips rather than asserting something false there.
    if [ ! -d /proc ]; then
        skip_test "no /proc — cannot construct an unwritable primary path portably"
        return 0
    fi
    local log="$SANDBOX/fallback.log"
    command env CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR=/proc/nope/corpora \
        bash "$FETCHER" --dir >"$log" 2>&1
    local rc=$?
    local out
    out="$(command cat "$log" 2>/dev/null)"
    # An EXPLICIT CORPORA_DIR that is unwritable is an operator error, not an
    # invitation to write somewhere else — a caller that set the variable is
    # saying where its measurements live, and silently relocating would strand
    # them. The /tmp fallback applies to the DEFAULT only.
    assert_true "[ \"$rc\" -ne 0 ]" "An explicit unwritable CORPORA_DIR must fail loudly"
    assert_contains "$out" "not writable" "The failure must say the path is not writable"
}

test_list_reports_presence_by_sha() {
    local mf="$SANDBOX/m7" dir="$SANDBOX/c7"
    write_manifest "$mf" alpha "$FIRST_SHA"

    run_fetch "$mf" "$dir" --list
    assert_exit 0 "$RUN_RC" "--list must succeed with nothing materialized"
    assert_contains "$RUN_OUT" "absent" "An unmaterialized corpus must read as absent"

    run_fetch "$mf" "$dir" alpha
    run_fetch "$mf" "$dir" --list
    assert_contains "$RUN_OUT" "present" "A materialized corpus at its pin must read as present"
}

test_corpora_present_is_sha_keyed() {
    # The predicate the CONSUMING slices (#1069/#1071/#1072/#1074) will key
    # their 77 sentinel on. It must answer "present AT THE PIN", not "directory
    # exists" — a consumer that skipped on the weaker question would measure a
    # wrong tree while believing it had the pin.
    local mf="$SANDBOX/m8" dir="$SANDBOX/c8"
    write_manifest "$mf" alpha "$FIRST_SHA"

    local probe="$SANDBOX/probe.sh"
    command printf '#!/usr/bin/env bash\n. "%s"\nif corpora_present alpha "%s"; then echo PRESENT; else echo ABSENT; fi\n' \
        "$FETCHER" "$dir" >"$probe"

    local out
    out="$(command env CORPORA_MANIFEST="$mf" bash "$probe" 2>&1)"
    assert_contains "$out" "ABSENT" "corpora_present must be false before materialization"

    run_fetch "$mf" "$dir" alpha
    out="$(command env CORPORA_MANIFEST="$mf" bash "$probe" 2>&1)"
    assert_contains "$out" "PRESENT" "corpora_present must be true at the pin"

    git_q -C "$dir/alpha" fetch -q --depth 1 origin "$TIP_SHA" >/dev/null 2>&1
    git_q -C "$dir/alpha" checkout -q FETCH_HEAD >/dev/null 2>&1
    out="$(command env CORPORA_MANIFEST="$mf" bash "$probe" 2>&1)"
    assert_contains "$out" "ABSENT" \
        "corpora_present must be FALSE for a tree sitting at the wrong commit"
}

test_sourcing_does_not_fetch() {
    # The script is sourced by consumers that want only the predicate. Sourcing
    # must define functions and stop — a source that ran main() would turn a
    # cheap presence check into a network fetch inside a test run (AC8).
    local mf="$SANDBOX/m9" dir="$SANDBOX/c9"
    write_manifest "$mf" alpha "$FIRST_SHA"

    local probe="$SANDBOX/source-probe.sh"
    command printf '#!/usr/bin/env bash\n. "%s"\necho SOURCED_OK\n' "$FETCHER" >"$probe"

    local out
    out="$(command env CORPORA_MANIFEST="$mf" CORPORA_DIR="$dir" bash "$probe" 2>&1)"
    assert_contains "$out" "SOURCED_OK" "Sourcing must succeed"
    assert_not_contains "$out" "materializing into" "Sourcing must NOT run a fetch"
    assert_true "[ ! -d \"$dir/alpha\" ]" "Sourcing must materialize nothing"
}

run_test test_fixture_is_non_vacuous
run_test test_fetches_and_verifies_pinned_sha
run_test test_wrong_sha_is_rejected
run_test test_short_sha_in_manifest_is_rejected
run_test test_is_idempotent
run_test test_repairs_a_tree_left_at_the_wrong_commit
run_test test_corpus_name_is_validated_at_the_boundary
run_test test_empty_manifest_fails_loudly
run_test test_missing_manifest_fails_loudly
run_test test_unknown_corpus_name_is_an_error
run_test test_tmp_fallback_when_cache_unwritable
run_test test_list_reports_presence_by_sha
run_test test_corpora_present_is_sha_keyed
run_test test_sourcing_does_not_fetch

generate_report
