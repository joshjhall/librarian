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

test_no_names_fetches_every_manifest_entry() {
    # THE DEFAULT INVOCATION — `fetch-corpora.sh` with no arguments — was
    # untested: every other case names a corpus explicitly. That is the path an
    # operator actually runs, and it has its own logic (manifest_names piped
    # through tr, then word-split), so it can break independently of the
    # named-corpus path.
    local mf="$SANDBOX/m-all" dir="$SANDBOX/c-all"
    command printf '# fixture\nalpha\tfile://%s\t%s\tMIT\ttag:none\tfixture\nbeta\tfile://%s\t%s\tMIT\ttag:none\tfixture\n' \
        "$UPSTREAM" "$FIRST_SHA" "$UPSTREAM" "$FIRST_SHA" >"$mf"

    run_fetch "$mf" "$dir"
    assert_exit 0 "$RUN_RC" "A bare invocation must fetch every manifest entry"
    assert_contains "$RUN_OUT" "alpha" "The first entry must be fetched"
    assert_contains "$RUN_OUT" "beta" "The SECOND entry must be fetched too — not just the first"

    local a b
    a="$(git_q -C "$dir/alpha" rev-parse HEAD 2>/dev/null)"
    b="$(git_q -C "$dir/beta" rev-parse HEAD 2>/dev/null)"
    assert_equals "$FIRST_SHA" "$a" "alpha must land on its pin"
    assert_equals "$FIRST_SHA" "$b" "beta must land on its pin"
}

test_help_and_unknown_option_branches() {
    # Small surface, but both are user-facing and neither was exercised. An
    # unknown option in particular must FAIL rather than be silently ignored —
    # a typo'd flag that quietly runs the default is how an operator ends up
    # believing they ran something they did not.
    local mf="$SANDBOX/m1" dir="$SANDBOX/c-help"

    run_fetch "$mf" "$dir" --help
    assert_exit 0 "$RUN_RC" "--help must succeed"
    assert_contains "$RUN_OUT" "Usage:" "--help must print usage"

    run_fetch "$mf" "$dir" --bogus
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "An unknown option must fail, never be ignored"
    assert_contains "$RUN_OUT" "unknown option" "The failure must name the bad option"
}

test_manifest_url_policy_is_enforced() {
    # The manifest header states "https only (no credentials, no ssh)". This
    # asserts the code enforces it rather than merely documenting it — a stated
    # rule with nothing behind it reads as a constraint while permitting the
    # opposite.
    #
    # The credential case is the one with teeth: fetch_one echoes the url on the
    # fetch line and on both error paths, so a credential in the manifest lands
    # in every log. The rejection must therefore happen BEFORE any echo, which
    # the last assertion checks.
    local dir="$SANDBOX/c-url"

    local ssh_mf="$SANDBOX/m-ssh"
    command printf '# fixture\nalpha\tssh://git@example.invalid/a.git\t%s\tMIT\ttag:none\tfixture\n' \
        "$FIRST_SHA" >"$ssh_mf"
    run_fetch "$ssh_mf" "$dir" alpha
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "An ssh remote must be refused"
    assert_contains "$RUN_OUT" "must be https" "The refusal must state the policy"

    local cred_mf="$SANDBOX/m-cred"
    command printf '# fixture\nalpha\thttps://u:sekrit@example.invalid/a.git\t%s\tMIT\ttag:none\tfixture\n' \
        "$FIRST_SHA" >"$cred_mf"
    run_fetch "$cred_mf" "$dir" alpha
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "A URL with embedded credentials must be refused"
    assert_not_contains "$RUN_OUT" "sekrit" \
        "The credential must never be echoed — the refusal must precede any logging of the URL"

    # THE CONTROL, actually exercised. An earlier version of this block wrote a
    # fixture file and asserted only that the file existed — which proves a
    # printf succeeded and nothing about valid_corpus_url. A rejection-only test
    # set passes just as well against a checker that refuses everything, so the
    # accepting direction has to be run, not described.
    #
    # `@` is tested in the PATH rather than the authority, because that is the
    # boundary: the check must reject credentials before the host and accept a
    # `@` after it (a scoped path segment is ordinary).
    local probe="$SANDBOX/urlprobe.sh"
    command printf '#!/usr/bin/env bash\n. "%s"\nfor u in "$@"; do if valid_corpus_url "$u"; then echo "OK $u"; else echo "NO $u"; fi; done\n' \
        "$FETCHER" >"$probe"

    local verdicts
    verdicts="$(command env CORPORA_MANIFEST="$SANDBOX/m1" bash "$probe" \
        'https://example.invalid/a/@scope/b.git' \
        'https://example.invalid/a.git' \
        "file://$UPSTREAM" \
        'https://u:sekrit@example.invalid/a.git' \
        'ssh://git@example.invalid/a.git' 2>&1)"

    assert_contains "$verdicts" "OK https://example.invalid/a/@scope/b.git" \
        "A '@' in the PATH is legitimate and must be ACCEPTED"
    assert_contains "$verdicts" "OK https://example.invalid/a.git" \
        "An ordinary https URL must be accepted"
    assert_contains "$verdicts" "OK file://" \
        "file:// must be accepted — the offline suite depends on it (AC8)"
    assert_contains "$verdicts" "NO https://u:sekrit@example.invalid/a.git" \
        "Credentials in the authority must be rejected"
    assert_contains "$verdicts" "NO ssh://git@example.invalid/a.git" \
        "An ssh remote must be rejected"
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

test_explicit_unwritable_corpora_dir_fails_loudly() {
    # NAMED FOR WHAT IT ASSERTS. An earlier name promised the /tmp fallback and
    # asserted the opposite behavior — the explicit-dir error path. A test name
    # that implies coverage the body does not provide is worse than an absent
    # test: a reader scanning the list concludes the fallback is covered and
    # stops looking.
    #
    # THE DEFAULT-PATH FALLBACK (CORPORA_DIR unset, /cache/corpora unwritable =>
    # /tmp/corpora) IS NOT ASSERTED HERE, and cannot be portably: /cache/corpora
    # is hardcoded for the default case, so a sandbox cannot make it unwritable
    # without root. It is covered instead by
    # test_default_fallback_reaches_tmp_when_primary_is_hostile below, which
    # reaches the same branch through the trust check rather than through
    # permissions.
    #
    # /proc is unwritable on every Linux host and absent on macOS, so the case
    # skips rather than asserting something false there.
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

test_symlinked_corpora_dir_is_refused() {
    # CWE-377, found in review. The corpora dir is a FIXED, predictable path —
    # useful on a bare host, pre-plantable on a shared one. An attacker who
    # creates it first as a symlink to a tree they control passes both `mkdir -p`
    # and a write probe, and the script would then run `git init`/`fetch`/
    # `checkout` inside it. git runs `.git/hooks/*` automatically on checkout, so
    # an ordinary temp-dir weakness becomes local code execution as the invoking
    # user.
    #
    # A symlink is refused outright rather than having its target inspected: the
    # target can be swapped between the check and the write.
    local target="$SANDBOX/evil-target" link="$SANDBOX/evil-link"
    command mkdir -p "$target"
    command ln -s "$target" "$link"

    local log="$SANDBOX/sym.log"
    command env CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR="$link" \
        bash "$FETCHER" --dir >"$log" 2>&1
    local rc=$?
    local out
    out="$(command cat "$log" 2>/dev/null)"

    assert_true "[ \"$rc\" -ne 0 ]" "A symlinked corpora dir must be refused, never written through"
    assert_contains "$out" "refusing to use" "The refusal must say what it refused"
    assert_not_contains "$out" "$target" "The refusal must not imply the target was used"
}

test_foreign_owned_corpora_dir_is_refused() {
    # The sibling of the symlink case: a real directory owned by someone else.
    # `mkdir -p` succeeds (it already exists) and it may well be writable, so
    # neither of those checks can catch it — ownership is the question.
    #
    # /tmp is the portable stand-in for "exists, not ours": root-owned on every
    # target platform. Skipped when the suite happens to run AS root, where the
    # premise does not hold.
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — no directory is foreign-owned"
        return 0
    fi
    local log="$SANDBOX/foreign.log"
    command env CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR=/tmp \
        bash "$FETCHER" --dir >"$log" 2>&1
    local out
    out="$(command cat "$log" 2>/dev/null)"
    assert_contains "$out" "refusing to use /tmp" \
        "A corpora dir owned by another uid must be refused"
}

test_symlinked_per_corpus_dir_is_refused() {
    # The trust check ONE LEVEL DOWN. resolve_corpora_dir vets the corpora root,
    # but $root/$name is the tree git actually inits, fetches and checks out in —
    # and checkout runs .git/hooks/*. Vetting only the parent is enough when the
    # parent is 0700 and ours, and NOT enough on a shared /cache volume whose
    # mode this script does not control. A trustworthy root with a hostile child
    # is the case that distinguishes the two.
    local root="$SANDBOX/c-child" target="$SANDBOX/child-target"
    command mkdir -p "$root" "$target"
    command ln -s "$target" "$root/alpha"

    run_fetch "$SANDBOX/m1" "$root" alpha
    assert_true "[ \"$RUN_RC\" -ne 0 ]" \
        "A symlinked per-corpus directory must be refused even under a trusted root"
    assert_contains "$RUN_OUT" "refusing to use" "The refusal must be explicit"
}

test_symlinked_per_corpus_dir_refused_even_when_at_the_pin() {
    # THE BYPASS THE FIRST VERSION OF THIS GUARD MISSED, and the reason its
    # placement is load-bearing rather than stylistic.
    #
    # corpora_present asks only "is there a .git here whose HEAD equals the pin".
    # The manifest's URL+SHA pairs are PUBLIC, so an attacker can clone the real
    # commit into a tree they own and symlink $root/$name at it. The SHA then
    # matches, the idempotence fast path returns 0, and a trust check placed
    # after it never runs — measured, before the fix: `ok (already at pin)`,
    # exit 0, no refusal.
    #
    # This is the distinguishing case: test_symlinked_per_corpus_dir_is_refused
    # above plants an EMPTY symlinked directory, which fails corpora_present and
    # therefore reaches the check by the slow path regardless of ordering. Only a
    # symlink that is genuinely AT THE PIN separates "checked before the fast
    # path" from "checked after it".
    local root="$SANDBOX/c-pinned-sym" real="$SANDBOX/pinned-real"

    # Build a legitimate checkout at the pin, exactly as an attacker could.
    command mkdir -p "$root"
    run_fetch "$SANDBOX/m1" "$SANDBOX/stage-pinned" alpha
    assert_exit 0 "$RUN_RC" "setup: a real pinned checkout must exist to symlink at"
    command mv "$SANDBOX/stage-pinned/alpha" "$real"
    command ln -s "$real" "$root/alpha"

    # Sanity: the planted tree really is at the pin, so this test cannot pass
    # merely because the SHA failed to match.
    local planted
    planted="$(git_q -C "$root/alpha" rev-parse HEAD 2>/dev/null)"
    assert_equals "$FIRST_SHA" "$planted" \
        "setup: the symlinked tree must BE at the pin, or the bypass is not reproduced"

    run_fetch "$SANDBOX/m1" "$root" alpha
    assert_true "[ \"$RUN_RC\" -ne 0 ]" \
        "A symlinked corpus dir must be refused even when its HEAD matches the pin"
    assert_contains "$RUN_OUT" "refusing to use" "The refusal must be explicit"
    assert_not_contains "$RUN_OUT" "already at pin" \
        "The idempotence fast path must NOT run before the trust check"
}

test_ensure_trusted_dir_runs_both_checks() {
    # THE STRUCTURAL PROPERTY, asserted on the helper directly.
    #
    # The trust invariant was fixed four times at four sites across three review
    # cycles, and each correct fix left a sibling exposed. ensure_trusted_dir is
    # the response: creation and BOTH checks in one place, so a caller cannot
    # obtain an unvetted directory and a NEW call site inherits the checks rather
    # than having to remember them.
    #
    # That claim is only worth making if the helper really runs both. Asserted
    # here against the helper itself, not through a caller, so a future
    # refactor that drops one check fails here rather than at whichever call
    # site happens to have a fixture.
    local probe="$SANDBOX/helper-probe.sh"
    command printf '#!/usr/bin/env bash\n. "%s"\nif ensure_trusted_dir "$1"; then echo OK; else echo NO; fi\n' \
        "$FETCHER" >"$probe"

    # 1. A fresh path: created and accepted.
    local fresh="$SANDBOX/helper-fresh"
    local out
    out="$(command env CORPORA_MANIFEST="$SANDBOX/m1" bash "$probe" "$fresh" 2>&1)"
    assert_contains "$out" "OK" "A fresh path must be created and accepted"
    assert_true "[ -d \"$fresh\" ]" "and must actually exist afterwards"

    # 2. A pre-existing symlink: refused by the PRE-creation check.
    local target="$SANDBOX/helper-target" link="$SANDBOX/helper-link"
    command mkdir -p "$target"
    command ln -s "$target" "$link"
    out="$(command env CORPORA_MANIFEST="$SANDBOX/m1" bash "$probe" "$link" 2>&1)"
    assert_contains "$out" "refusing to use" "A pre-existing symlink must be refused"
    assert_not_contains "$out" "OK" "and must not be accepted"

    # 3. A fresh path under a stat stub reporting a foreign uid: the PRE-check
    #    cannot fire (nothing exists yet), so only the POST-creation check can
    #    produce the refusal. This is what distinguishes "both checks" from
    #    "the first check".
    local stub="$SANDBOX/stubbin-helper"
    command mkdir -p "$stub"
    command printf '#!/usr/bin/env bash\necho 999999\n' >"$stub/stat"
    command chmod +x "$stub/stat"
    local fresh2="$SANDBOX/helper-fresh-2"
    out="$(command env -uBASH_ENV PATH="$stub:$PATH" CORPORA_MANIFEST="$SANDBOX/m1" \
        bash --noprofile --norc "$probe" "$fresh2" 2>&1)"
    assert_contains "$out" "after creation" \
        "A path that fails the trust check only AFTER creation must be refused by the post-check"
}

test_group_or_world_writable_dir_is_refused() {
    # THE THIRD AXIS. Ownership and symlink-ness are not sufficient: a directory
    # we own, that is not a symlink, can still be group- or world-writable — a
    # /cache volume made under a permissive umask, or a per-corpus subdirectory
    # inheriting one. A co-tenant with write access can plant `.git/hooks/*`
    # during the fetch window, and `git checkout` runs hooks automatically. That
    # is the same local code execution the other two checks exist to prevent,
    # reached by the axis they do not examine.
    #
    # Measured before the fix: a 0777 corpora dir was accepted, exit 0.
    local ww="$SANDBOX/world-writable"
    command mkdir -p "$ww"
    command chmod 777 "$ww"
    run_fetch "$SANDBOX/m1" "$ww" --dir
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "A world-writable corpora dir must be refused"
    assert_contains "$RUN_OUT" "writable" "The refusal must name the mode as the reason"

    local gw="$SANDBOX/group-writable"
    command mkdir -p "$gw"
    command chmod 775 "$gw"
    run_fetch "$SANDBOX/m1" "$gw" --dir
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "A group-writable corpora dir must be refused too"

    # THE CONTROL, and it is load-bearing: a mode check that refused everything
    # would satisfy both assertions above while breaking the tool outright.
    local ok="$SANDBOX/mode-ok"
    command mkdir -p "$ok"
    command chmod 755 "$ok"
    run_fetch "$SANDBOX/m1" "$ok" --dir
    assert_exit 0 "$RUN_RC" "An 0755 directory must still be accepted"
    assert_contains "$RUN_OUT" "$ok" "and must be reported as the resolved dir"
}

test_list_refuses_a_malformed_manifest_row() {
    # A truncated row (missing the SHA column) used to print
    # `nosha  absent  ` with a blank SHA and exit 0 — so a broken manifest was
    # indistinguishable from a healthy one with nothing materialized. The fetch
    # path already rejects such a row via is_full_sha; the read-only view of the
    # same manifest must not be the softer of the two.
    #
    # Found by sweeping for siblings of the empty-root defect: places where a
    # missing value is formatted rather than checked.
    local mf="$SANDBOX/m-trunc" dir="$SANDBOX/c-trunc"
    command printf '# fixture\nnosha\tfile://%s\n' "$UPSTREAM" >"$mf"

    run_fetch "$mf" "$dir" --list
    assert_true "[ \"$RUN_RC\" -ne 0 ]" "A malformed manifest row must fail --list, not list quietly"
    assert_contains "$RUN_OUT" "MALFORMED" "The bad row must be named as malformed"

    # The control: a well-formed manifest must still list cleanly, or this check
    # would simply break --list.
    run_fetch "$SANDBOX/m1" "$dir" --list
    assert_exit 0 "$RUN_RC" "A well-formed manifest must still list successfully"
    assert_contains "$RUN_OUT" "alpha" "and must still name its corpora"
}

test_unresolvable_root_never_becomes_the_filesystem_root() {
    # `root="$(resolve_corpora_dir)"` runs its body in a SUBSHELL, so a `die`
    # inside ends that subshell and the assignment quietly receives an empty
    # string — `set -e` does not fire, because the assignment succeeded. main()
    # then built paths like "/axe-core" and reported `materializing into `
    # (blank), i.e. it was operating at the filesystem root.
    #
    # Observed directly while probing the sourced entry points, not by a test
    # failing: every existing assertion passed with this present, because they
    # all supply a usable directory.
    local log="$SANDBOX/emptyroot.log"
    command env CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR=/proc/nope/emptyroot \
        bash "$FETCHER" alpha >"$log" 2>&1
    local rc=$?
    local out
    out="$(command cat "$log" 2>/dev/null)"

    assert_true "[ \"$rc\" -ne 0 ]" "An unresolvable corpora dir must fail"
    assert_contains "$out" "could not resolve" "and must say so explicitly"
    # The decisive consequences: no blank destination, and no path built at /.
    assert_not_contains "$out" "materializing into " \
        "It must never announce materializing into an EMPTY directory"
    assert_not_contains "$out" "/alpha" \
        "and must never build a corpus path at the filesystem root"
}

test_refusals_do_not_fall_through_when_sourced() {
    # THE SUBSHELL ENTRY POINTS ARE THE MECHANISM. `die` always exits; what makes
    # that safe for a sourcing consumer is that `corpora_present` and
    # `fetch_corpora` run their bodies in a subshell, so the exit ends the
    # subshell and arrives as an ordinary non-zero status.
    #
    # This replaced a per-call-site `return 1` after each `die`, which was the
    # first attempt and which an exhaustive sweep showed had been applied to
    # three of eleven sites. Executed mode cannot catch the fallthrough (the exit
    # masks it), so the property has to be asserted through a SOURCED call — that
    # the consumer survives AND gets a failing status AND no work ran past the
    # refusal.
    local root="$SANDBOX/c-fallthrough" target="$SANDBOX/fallthrough-target"
    command mkdir -p "$root" "$target"
    command ln -s "$target" "$root/alpha"

    # Calls the documented SOURCED entry point, `fetch_corpora`, not the internal
    # fetch_one. The entry points are the subshell boundary that makes `die`'s
    # unconditional exit safe for a consumer; an internal helper exits, by
    # design, and a consumer is not meant to call it directly.
    local probe="$SANDBOX/fallthrough-probe.sh"
    command printf '#!/usr/bin/env bash\n. "%s"\nif fetch_corpora alpha; then echo RETURNED_OK; else echo RETURNED_FAIL; fi\necho CONSUMER_ALIVE\n' \
        "$FETCHER" >"$probe"

    local out
    out="$(command env CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR="$root" bash "$probe" 2>&1)"
    assert_contains "$out" "CONSUMER_ALIVE" \
        "A refusal must not kill the consumer's shell — that is what the subshell buys"
    assert_contains "$out" "refusing to use" "The refusal must be printed"
    assert_contains "$out" "RETURNED_FAIL" \
        "and the function must RETURN non-zero — not print a refusal and continue"
    assert_not_contains "$out" "RETURNED_OK" "A refused directory must never yield success"
    # The decisive consequence: no fetch may have been attempted past the refusal.
    assert_not_contains "$out" "fetch    " "No fetch may run after a refusal"
}

test_root_is_rechecked_after_creation() {
    # THE SIBLING CALL SITE. fetch_one re-checks dir_is_trustworthy immediately
    # after `mkdir -p`; resolve_corpora_dir first shipped without that re-check,
    # which is the harden-one-knob-leave-the-sibling-exposed shape.
    #
    # The window matters because the PRE-check fires only when the path already
    # exists. On a first-ever run it does not, so control falls straight to
    # `mkdir -p` — which succeeds SILENTLY through a symlink planted in the race,
    # and the probe write succeeds through it too. The downstream per-corpus
    # checks cannot save it: a freshly created $root/$name inside a compromised
    # root is owned by us and passes, while the attacker owns the parent.
    #
    # Racing the real window is not reproducible in a test, so the assertion is
    # that the post-creation check EXISTS AND FIRES: a stat stub reporting a
    # foreign uid makes every dir_is_trustworthy call fail, including the one
    # after mkdir. A non-existent CORPORA_DIR skips the pre-check entirely, so
    # only the post-check can produce the refusal.
    local stub="$SANDBOX/stubbin-root"
    command mkdir -p "$stub"
    command printf '#!/usr/bin/env bash\necho 999999\n' >"$stub/stat"
    command chmod +x "$stub/stat"

    local fresh="$SANDBOX/never-existed-root"
    assert_true "[ ! -e \"$fresh\" ]" \
        "setup: the path must NOT exist, or the pre-check fires and this proves nothing"

    local log="$SANDBOX/root-recheck.log"
    command env -uBASH_ENV PATH="$stub:$PATH" \
        CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR="$fresh" \
        bash --noprofile --norc "$FETCHER" --dir >"$log" 2>&1
    local rc=$?
    local out
    out="$(command cat "$log" 2>/dev/null)"

    assert_true "[ \"$rc\" -ne 0 ]" \
        "A root that fails the trust check AFTER creation must be refused"
    assert_contains "$out" "after creation" \
        "The refusal must come from the POST-creation re-check, not the pre-check"
}

test_corpora_present_rejects_an_untrustworthy_tree() {
    # THE PREDICATE ITSELF must refuse a tree it cannot vouch for — not only the
    # fetch path. Found by walking fetch_one's control flow after cycle 2, which
    # showed `--list` (and therefore any consuming gate) calling corpora_present
    # with no trust check at all.
    #
    # Measured before the fix: `--list` reported a symlinked tree at the public
    # pin as `present`. A consuming gate keying its 77 sentinel on this predicate
    # would then measure against an attacker's tree while believing it held the
    # pin — the wrong-answer-reads-as-evidence failure this slice exists to
    # prevent, arriving through the predicate rather than the fetch.
    local root="$SANDBOX/c-pred" real="$SANDBOX/pred-real"
    command mkdir -p "$root"
    run_fetch "$SANDBOX/m1" "$SANDBOX/stage-pred" alpha
    assert_exit 0 "$RUN_RC" "setup: need a real pinned checkout"
    command mv "$SANDBOX/stage-pred/alpha" "$real"
    command ln -s "$real" "$root/alpha"

    # --list is the read-only consumer of the predicate.
    run_fetch "$SANDBOX/m1" "$root" --list
    assert_exit 0 "$RUN_RC" "--list must still succeed"
    assert_contains "$RUN_OUT" "absent" \
        "A symlinked tree at the pin must read ABSENT, never present"
    assert_not_contains "$RUN_OUT" "present" \
        "corpora_present must not vouch for a tree it cannot trust"

    # And directly, which is how a consuming gate calls it.
    local probe="$SANDBOX/pred-probe.sh"
    command printf '#!/usr/bin/env bash\n. "%s"\nif corpora_present alpha "%s"; then echo PRESENT; else echo ABSENT; fi\necho SURVIVED\n' \
        "$FETCHER" "$root" >"$probe"
    local out
    out="$(command env CORPORA_MANIFEST="$SANDBOX/m1" bash "$probe" 2>&1)"
    assert_contains "$out" "ABSENT" "The predicate must answer false for an untrusted tree"
    assert_contains "$out" "SURVIVED" "and must answer, not abort — it is a predicate"
}

test_foreign_owned_per_corpus_dir_is_refused() {
    # dir_is_trustworthy has TWO branches — symlink and ownership — and the
    # per-corpus call site previously exercised only the symlink one. Since the
    # function is shared, a regression confined to the ownership branch would
    # pass every other fixture at this call site. The root-level guard has both
    # arms covered; this brings the child level to parity.
    #
    # The stat stub is the portable way to force the ownership branch without
    # needing a second uid. BASH_ENV must be scrubbed or the stub is discarded —
    # see test_trust_check_refuses_when_stat_is_unusable.
    local stub="$SANDBOX/stubbin-owner"
    command mkdir -p "$stub"
    # Report a uid that is definitely not ours, exercising the ownership branch
    # rather than the indeterminate one.
    command printf '#!/usr/bin/env bash\necho 999999\n' >"$stub/stat"
    command chmod +x "$stub/stat"

    local root="$SANDBOX/c-foreign-child"
    command mkdir -p "$root/alpha"

    local log="$SANDBOX/foreign-child.log"
    command env -uBASH_ENV PATH="$stub:$PATH" \
        CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR="$root" \
        bash --noprofile --norc "$FETCHER" alpha >"$log" 2>&1
    local rc=$?
    local out
    out="$(command cat "$log" 2>/dev/null)"

    assert_true "[ \"$rc\" -ne 0 ]" \
        "A per-corpus dir owned by another uid must be refused"
    assert_contains "$out" "refusing to use" "The refusal must be explicit"
}

test_trust_check_refuses_when_stat_is_unusable() {
    # A GUARD THAT COULD NOT RUN HAS LEARNED NOTHING. If neither stat spelling
    # yields a uid — a stripped container, a busybox stat, a PATH without it —
    # the ownership question is INDETERMINATE, and the only safe answer is to
    # refuse. Failing open here would silently restore the exact CWE-377 hole the
    # check exists to close, on precisely the unusual hosts least likely to be
    # noticed.
    #
    # Constructed by shadowing `stat` with a stub that always fails, which is
    # also why dir_is_trustworthy validates stat's OUTPUT rather than trusting
    # its exit code: GNU and BSD disagree about what `-f` means, so a
    # wrong-platform invocation can print something that is not a uid.
    local stub="$SANDBOX/stubbin"
    command mkdir -p "$stub"
    command printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/stat"
    command chmod +x "$stub/stat"

    local dir="$SANDBOX/c-nostat"
    command mkdir -p "$dir"

    # BASH_ENV MUST BE NEUTRALIZED OR THIS FIXTURE TESTS NOTHING. This
    # environment sets BASH_ENV=/etc/bash_env, which bash sources on every
    # non-interactive start — and it REBUILDS PATH. So a stub directory prepended
    # here is silently discarded before the script runs, `stat` resolves to the
    # real binary, and the case passes while exercising the ordinary path. That
    # was the first version of this test, and it reported green against a guard
    # that fails open.
    #
    # `-uBASH_ENV` attached, never `env --unset=BASH_ENV`: BSD env has no long
    # options and reads the latter as `-u` with the operand `nset=BASH_ENV`
    # (CLAUDE.md § Runtime policy).
    local log="$SANDBOX/nostat.log"
    command env -uBASH_ENV PATH="$stub:$PATH" \
        CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR="$dir" \
        bash --noprofile --norc "$FETCHER" --dir >"$log" 2>&1
    local rc=$?
    local out
    out="$(command cat "$log" 2>/dev/null)"

    assert_true "[ \"$rc\" -ne 0 ]" \
        "With stat unusable the trust check must REFUSE, never fail open"
    assert_contains "$out" "refusing to use" "The refusal must be explicit"
}

test_owned_corpora_dir_is_accepted() {
    # THE CONTROL for the two refusals above. Without it, a trust check that
    # rejected everything would satisfy both and break the tool entirely.
    local dir="$SANDBOX/mine"
    command mkdir -p "$dir"
    run_fetch "$SANDBOX/m1" "$dir" --dir
    assert_exit 0 "$RUN_RC" "A directory we own must be accepted"
    assert_contains "$RUN_OUT" "$dir" "--dir must report the accepted path"
}

test_sourcing_survives_a_missing_manifest() {
    # THE CONSUMER CONTRACT, found in review. A consuming gate
    # (#1069/#1071/#1072/#1074) sources this file for `corpora_present` alone. In
    # a sourced context `exit` terminates the CALLER'S shell — so a load-time
    # `die` on a missing manifest would kill the gate outright, and it would
    # never reach the 77 sentinel it exists to report. The gate would die with no
    # verdict where it should have printed `[SKIP] … did not run`.
    #
    # Both directions matter and are asserted: sourcing survives, executing still
    # fails loud (test_missing_manifest_fails_loudly above).
    local probe="$SANDBOX/source-nomf.sh"
    command printf '#!/usr/bin/env bash\nset -euo pipefail\n. "%s"\nif corpora_present alpha; then echo P; else echo A; fi\necho SURVIVED\n' \
        "$FETCHER" >"$probe"

    local out
    out="$(command env CORPORA_MANIFEST="$SANDBOX/does-not-exist" bash "$probe" 2>&1)"
    assert_contains "$out" "SURVIVED" \
        "Sourcing with a missing manifest must NOT kill the consumer's shell"
    assert_contains "$out" "A" "corpora_present must answer false, not abort"
}

test_corpora_present_survives_an_unusable_dir() {
    # The same contract on the other failure path: the predicate called WITHOUT
    # an explicit dir resolves the default internally, and that resolution can
    # fail. It must degrade to false rather than take the consumer down with it.
    local probe="$SANDBOX/source-baddir.sh"
    command printf '#!/usr/bin/env bash\nset -euo pipefail\n. "%s"\nif corpora_present alpha; then echo P; else echo A; fi\necho SURVIVED\n' \
        "$FETCHER" >"$probe"

    local out
    out="$(command env CORPORA_MANIFEST="$SANDBOX/m1" CORPORA_DIR=/proc/nope/z bash "$probe" 2>&1)"
    assert_contains "$out" "SURVIVED" \
        "An unusable corpora dir must not kill a sourcing consumer"
    assert_contains "$out" "A" "corpora_present must answer false there too"
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
run_test test_no_names_fetches_every_manifest_entry
run_test test_help_and_unknown_option_branches
run_test test_manifest_url_policy_is_enforced
run_test test_corpus_name_is_validated_at_the_boundary
run_test test_empty_manifest_fails_loudly
run_test test_missing_manifest_fails_loudly
run_test test_unknown_corpus_name_is_an_error
run_test test_explicit_unwritable_corpora_dir_fails_loudly
run_test test_symlinked_corpora_dir_is_refused
run_test test_foreign_owned_corpora_dir_is_refused
run_test test_symlinked_per_corpus_dir_is_refused
run_test test_symlinked_per_corpus_dir_refused_even_when_at_the_pin
run_test test_ensure_trusted_dir_runs_both_checks
run_test test_group_or_world_writable_dir_is_refused
run_test test_list_refuses_a_malformed_manifest_row
run_test test_unresolvable_root_never_becomes_the_filesystem_root
run_test test_refusals_do_not_fall_through_when_sourced
run_test test_root_is_rechecked_after_creation
run_test test_corpora_present_rejects_an_untrustworthy_tree
run_test test_foreign_owned_per_corpus_dir_is_refused
run_test test_trust_check_refuses_when_stat_is_unusable
run_test test_owned_corpora_dir_is_accepted
run_test test_sourcing_survives_a_missing_manifest
run_test test_corpora_present_survives_an_unusable_dir
run_test test_list_reports_presence_by_sha
run_test test_corpora_present_is_sha_keyed
run_test test_sourcing_does_not_fetch

generate_report
